import os
import SwiftUI
import CoreData
import AVFoundation
// MARK: - Video page transcript

enum TranscriptFollowMode: Equatable {
    case playbackAdvance
    case resume
}

enum TranscriptFollowPolicy {
    static let bottomMargin: CGFloat = 96
    static let topMargin: CGFloat = 40
    static let suppressionInterval: TimeInterval = 4
    static let suppressionDuration: Duration = .seconds(4)

    static func suppressionDeadline(after inputDate: Date) -> Date {
        inputDate.addingTimeInterval(suppressionInterval)
    }

    static func shouldScroll(
        paragraphFrame: CGRect,
        viewport: CGRect,
        isPlaying: Bool,
        isSuppressed: Bool,
        mode: TranscriptFollowMode
    ) -> Bool {
        guard isPlaying,
              !isSuppressed,
              isValid(paragraphFrame),
              isValid(viewport) else {
            return false
        }

        let isBelowSafeArea = paragraphFrame.maxY > viewport.maxY - bottomMargin
        let isAboveSafeArea = paragraphFrame.minY < viewport.minY + topMargin
        return isBelowSafeArea || (mode == .resume && isAboveSafeArea)
    }

    static func shouldScrollToIDFallback(
        hasActiveParagraph: Bool,
        hasMeasurement: Bool,
        isPlaying: Bool,
        isSuppressed: Bool
    ) -> Bool {
        hasActiveParagraph
            && !hasMeasurement
            && isPlaying
            && !isSuppressed
    }

    static func shouldResetLifecycle(activeParagraphID: String?) -> Bool {
        activeParagraphID == nil
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.size.width > 0
            && frame.size.height > 0
    }
}

struct InlineVideoGeometry: Equatable {
    let videoID: UUID
    let frame: CGRect
    let rootFrame: CGRect
}

struct InlineVideoGeometryPreferenceKey: PreferenceKey {
    static let defaultValue: InlineVideoGeometry? = nil

    static func reduce(
        value: inout InlineVideoGeometry?,
        nextValue: () -> InlineVideoGeometry?
    ) {
        if let nextValue = nextValue() {
            value = nextValue
        }
    }
}

struct ActiveTranscriptGeometry: Equatable {
    let videoID: UUID
    let paragraphID: String
    let frame: CGRect
}

struct ActiveTranscriptGeometryPreferenceKey: PreferenceKey {
    static let defaultValue: ActiveTranscriptGeometry? = nil

    static func reduce(
        value: inout ActiveTranscriptGeometry?,
        nextValue: () -> ActiveTranscriptGeometry?
    ) {
        if let nextValue = nextValue() {
            value = nextValue
        }
    }
}

struct MergedTranscriptView: View {
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager

    @ObservedObject var video: Video
    let playerViewModel: VideoPlayerViewModel
    let searchModel: VideoPageSearchModel
    let preferredTranslationLocaleIdentifier: String?
    let onRequestScrollToParagraph: (String) -> Void
    let onActiveParagraphChange: (String?) -> Void

    @State private var timedParagraphs: [TimedParagraph] = []
    @State private var plainParagraphs: [PlainParagraph] = []
    @State private var activeParagraphID: String?
    @State private var loadError: String?
    @State private var sourceLabel = "Transcript"
    @State private var currentMatchID: String?
    @State private var matchingIDs: [String] = []
    @State private var matchingIDSet: Set<String> = []
    @State private var isLoading = true

    /// Everything that should trigger a reload of the transcript content.
    private struct LoadKey: Equatable {
        let videoID: UUID?
        let transcriptDate: Date?
        let translationDate: Date?
        let translatedLanguage: String?
        let preferredLocale: String?
    }

    private var loadKey: LoadKey {
        LoadKey(
            videoID: video.id,
            transcriptDate: video.transcriptDateGenerated,
            translationDate: video.translationDateGenerated,
            translatedLanguage: video.translatedLanguage,
            preferredLocale: preferredTranslationLocaleIdentifier
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let loadError {
                ContentUnavailableView(
                    "Transcript unavailable",
                    systemImage: "exclamationmark.bubble",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else if timedParagraphs.isEmpty && plainParagraphs.isEmpty {
                if isLoading {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 240)
                } else {
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "doc.text",
                    description: Text("Transcript has not been generated for this video.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                }
            } else {
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 10) {
                    if !timedParagraphs.isEmpty {
                        ForEach(timedParagraphs) { paragraph in
                            Text(paragraph.text)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 2)
                                .background(backgroundColor(for: paragraph.id, active: activeParagraphID == paragraph.id))
                                .background {
                                    if activeParagraphID == paragraph.id,
                                       let videoID = video.id {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: ActiveTranscriptGeometryPreferenceKey.self,
                                                value: ActiveTranscriptGeometry(
                                                    videoID: videoID,
                                                    paragraphID: paragraph.id,
                                                    frame: geometry.frame(
                                                        in: .named(DetailView.detailViewportCoordinateSpace)
                                                    )
                                                )
                                            )
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playerViewModel.seek(to: paragraph.startSeconds, in: video)
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Jumps to this point in the video")
                                .id(paragraph.id)
                        }
                    } else {
                        ForEach(plainParagraphs) { paragraph in
                            Text(paragraph.text)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 2)
                                .background(backgroundColor(for: paragraph.id, active: false))
                                .id(paragraph.id)
                        }
                    }
                }
                .font(.system(size: 17))
                .lineSpacing(12)
                .multilineTextAlignment(.leading)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: VideoDetailLayout.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, VideoDetailLayout.horizontalPadding)
        .task(id: loadKey) {
            await loadContent()
        }
        .task {
            // Observed here, not read in body, so playback ticks don't re-render the whole transcript.
            let times = Observations { playerViewModel.currentTime }
            for await time in times {
                updateActiveParagraph(for: time)
            }
        }
        .onChange(of: video.id) { _, _ in
            setActiveParagraphID(nil)
            timedParagraphs = []
            plainParagraphs = []
            isLoading = true
        }
        .onChange(of: searchModel.query) { _, _ in
            refreshSearchState(scrollToMatch: true)
        }
        .onChange(of: searchModel.navigationRequestID) { _, _ in
            moveAcrossSearchResults()
        }
    }

    private func backgroundColor(for paragraphID: String, active: Bool) -> Color {
        if paragraphID == currentMatchID {
            return Color.yellow.opacity(0.35)
        }
        if matchingIDSet.contains(paragraphID) {
            return Color.yellow.opacity(0.18)
        }
        if active {
            return Color.accentColor.opacity(0.18)
        }
        return .clear
    }

    /// Paragraphs matching the search query, in reading order.
    private func computeMatchingParagraphIDs() -> [String] {
        let query = searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        if !timedParagraphs.isEmpty {
            return timedParagraphs.filter { $0.text.localizedStandardContains(query) }.map(\.id)
        }
        return plainParagraphs.filter { $0.text.localizedStandardContains(query) }.map(\.id)
    }

    private func moveAcrossSearchResults() {
        let matches = matchingIDs
        guard !matches.isEmpty else {
            currentMatchID = nil
            searchModel.setSearchState(totalMatches: 0, currentMatchIndex: nil)
            return
        }

        let currentIndex = currentMatchID.flatMap { matches.firstIndex(of: $0) }
        let nextIndex: Int
        switch searchModel.direction {
        case .next:
            nextIndex = ((currentIndex ?? -1) + 1 + matches.count) % matches.count
        case .previous:
            nextIndex = ((currentIndex ?? 0) - 1 + matches.count) % matches.count
        }

        currentMatchID = matches[nextIndex]
        searchModel.setSearchState(totalMatches: matches.count, currentMatchIndex: nextIndex)
        onRequestScrollToParagraph(matches[nextIndex])
    }

    private func refreshSearchState(scrollToMatch: Bool) {
        let matches = computeMatchingParagraphIDs()
        matchingIDs = matches
        matchingIDSet = Set(matches)
        guard !matches.isEmpty else {
            currentMatchID = nil
            searchModel.setSearchState(totalMatches: 0, currentMatchIndex: nil)
            return
        }

        let nextMatchID: String
        if let currentMatchID, matches.contains(currentMatchID) {
            nextMatchID = currentMatchID
        } else {
            nextMatchID = matches[0]
        }

        currentMatchID = nextMatchID
        let currentIndex = matches.firstIndex(of: nextMatchID) ?? 0
        searchModel.setSearchState(totalMatches: matches.count, currentMatchIndex: currentIndex)

        if scrollToMatch,
           !searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onRequestScrollToParagraph(nextMatchID)
        }
    }

    private func loadContent() async {
        isLoading = true
        let sources = transcriptSources()
        let artifacts = libraryManager.textArtifacts
        let content = await Task.detached(priority: .userInitiated) {
            TranscriptContentLoader.load(sources, artifacts: artifacts)
        }.value
        guard !Task.isCancelled else { return }

        sourceLabel = content.label
        loadError = content.failure
        switch content.paragraphs {
        case .timed(let paragraphs):
            timedParagraphs = paragraphs
            plainParagraphs = []
        case .plain(let paragraphs):
            timedParagraphs = []
            plainParagraphs = paragraphs
        case .none:
            timedParagraphs = []
            plainParagraphs = []
        }
        isLoading = false

        updateActiveParagraph(for: playerViewModel.currentTime)
        refreshSearchState(scrollToMatch: false)
    }

    /// Captures what is needed to load the transcript while still on the main actor.
    private func transcriptSources() -> TranscriptSources {
        let artifacts = libraryManager.textArtifacts
        var sources = TranscriptSources()

        if shouldPreferTranslation, let translatedLanguage = video.translatedLanguage {
            sources.timedTranslationURL = artifacts.existingTimedTranslationURL(for: video, languageCode: translatedLanguage)
            sources.plainTranslation = nonEmpty(video.translatedText)
        }
        sources.timedTranscriptURL = artifacts.existingTimedTranscriptURL(for: video)
        sources.plainTranscript = nonEmpty(video.transcriptText)
        return sources
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private var shouldPreferTranslation: Bool {
        guard let translatedText = video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translatedText.isEmpty,
              let translatedLanguage = video.translatedLanguage,
              let preferredTranslationLocaleIdentifier else {
            return false
        }

        return normalizedLanguageCode(for: translatedLanguage) == normalizedLanguageCode(for: preferredTranslationLocaleIdentifier)
    }

    private func normalizedLanguageCode(for identifier: String) -> String? {
        let locale = Locale(identifier: identifier)
        if let code = locale.language.languageCode?.identifier {
            return code.lowercased()
        }

        return identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { String($0).lowercased() }
    }

    private func updateActiveParagraph(for time: TimeInterval) {
        guard !timedParagraphs.isEmpty else {
            setActiveParagraphID(nil)
            return
        }

        setActiveParagraphID(timedParagraphs.last(where: { paragraph in
            paragraph.startSeconds <= time
        })?.id)
    }

    private func setActiveParagraphID(_ paragraphID: String?) {
        guard activeParagraphID != paragraphID else { return }
        activeParagraphID = paragraphID
        onActiveParagraphChange(paragraphID)
    }
}
