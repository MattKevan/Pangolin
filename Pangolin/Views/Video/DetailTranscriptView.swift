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
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject var searchModel: VideoPageSearchModel
    let preferredTranslationLocaleIdentifier: String?
    let onRequestScrollToParagraph: (String) -> Void
    let onActiveParagraphChange: (String?) -> Void

    @State private var timedParagraphs: [TimedParagraph] = []
    @State private var plainParagraphs: [PlainParagraph] = []
    @State private var activeParagraphID: String?
    @State private var loadError: String?
    @State private var sourceLabel = "Transcript"
    @State private var currentMatchID: String?

    private struct TimedParagraph: Identifiable {
        let id: String
        let entryIDs: [String]
        let startSeconds: TimeInterval
        let text: String
    }

    private struct PlainParagraph: Identifiable {
        let id: String
        let text: String
    }

    private enum ResolvedSource {
        case timedTranscript(TimedTranscript.ChunkIndex)
        case timedTranslation(TimedTranslation.ChunkIndex)
        case plainTranscript(String)
        case plainTranslation(String)
        case empty
    }

    private static let paragraphSoftWordTarget = 36
    private static let paragraphHardWordLimit = 56
    private static let paragraphMaxChunks = 6
    private static let paragraphMaxSentences = 2
    private static let sentenceTerminators: Set<Character> = [".", "?", "!", ";", ":"]

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
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "doc.text",
                    description: Text("Transcript has not been generated for this video.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
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
        .onAppear {
            loadContent()
            updateActiveParagraph(for: playerViewModel.currentTime)
            refreshSearchState(scrollToMatch: false)
        }
        .onChange(of: video.id) { _, _ in
            setActiveParagraphID(nil)
            loadContent()
            refreshSearchState(scrollToMatch: false)
        }
        .onChange(of: video.transcriptDateGenerated) { _, _ in
            loadContent()
            refreshSearchState(scrollToMatch: false)
        }
        .onChange(of: video.translationDateGenerated) { _, _ in
            loadContent()
            refreshSearchState(scrollToMatch: false)
        }
        .onChange(of: video.translatedLanguage) { _, _ in
            loadContent()
            refreshSearchState(scrollToMatch: false)
        }
        .onChange(of: preferredTranslationLocaleIdentifier) { _, _ in
            loadContent()
            refreshSearchState(scrollToMatch: false)
        }
        .onChange(of: playerViewModel.currentTime) { _, newTime in
            updateActiveParagraph(for: newTime)
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
        if matchingParagraphIDs.contains(paragraphID) {
            return Color.yellow.opacity(0.18)
        }
        if active {
            return Color.accentColor.opacity(0.18)
        }
        return .clear
    }

    private var matchingParagraphIDs: [String] {
        let query = searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let normalizedQuery = query.localizedLowercase

        if !timedParagraphs.isEmpty {
            return timedParagraphs
                .filter { $0.text.localizedLowercase.contains(normalizedQuery) }
                .map(\.id)
        }

        return plainParagraphs
            .filter { $0.text.localizedLowercase.contains(normalizedQuery) }
            .map(\.id)
    }

    private func moveAcrossSearchResults() {
        let matches = matchingParagraphIDs
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
        let matches = matchingParagraphIDs
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

    private func loadContent() {
        let source = resolvedSource()
        switch source {
        case .timedTranscript(let index):
            sourceLabel = "Transcript"
            timedParagraphs = makeTimedParagraphs(
                entries: index.allEntries.map {
                    (id: $0.id.uuidString, text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds)
                }
            )
            plainParagraphs = []
            loadError = nil
        case .timedTranslation(let index):
            sourceLabel = "Translation"
            timedParagraphs = makeTimedParagraphs(
                entries: index.allEntries.map {
                    (id: $0.id, text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds)
                }
            )
            plainParagraphs = []
            loadError = nil
        case .plainTranscript(let text):
            sourceLabel = "Transcript"
            timedParagraphs = []
            plainParagraphs = makePlainParagraphs(from: text)
            loadError = nil
        case .plainTranslation(let text):
            sourceLabel = "Translation"
            timedParagraphs = []
            plainParagraphs = makePlainParagraphs(from: text)
            loadError = nil
        case .empty:
            sourceLabel = "Transcript"
            timedParagraphs = []
            plainParagraphs = []
            loadError = nil
        }

        updateActiveParagraph(for: playerViewModel.currentTime)
    }

    private func resolvedSource() -> ResolvedSource {
        if shouldPreferTranslation,
           let translatedLanguage = video.translatedLanguage,
           let timedURL = libraryManager.textArtifacts.existingTimedTranslationURL(for: video, languageCode: translatedLanguage),
           FileManager.default.fileExists(atPath: timedURL.path),
           let translation = try? libraryManager.textArtifacts.readTimedTranslation(from: timedURL) {
            return .timedTranslation(translation.makeChunkIndex())
        }

        if shouldPreferTranslation,
           let translatedText = video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translatedText.isEmpty {
            return .plainTranslation(translatedText)
        }

        if let timedURL = libraryManager.textArtifacts.existingTimedTranscriptURL(for: video),
           let transcript = try? libraryManager.textArtifacts.readTimedTranscriptIfAvailable(from: timedURL) {
            return .timedTranscript(transcript.makeChunkIndex())
        }

        if let transcriptText = video.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcriptText.isEmpty {
            return .plainTranscript(transcriptText)
        }

        return .empty
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

    private func makePlainParagraphs(from text: String) -> [PlainParagraph] {
        text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, text in
                PlainParagraph(id: "plain-\(index)", text: text)
            }
    }

    private func makeTimedParagraphs(
        entries: [(id: String, text: String, startSeconds: TimeInterval, endSeconds: TimeInterval)]
    ) -> [TimedParagraph] {
        var paragraphs: [TimedParagraph] = []
        var currentEntries: [(id: String, text: String, startSeconds: TimeInterval, endSeconds: TimeInterval)] = []
        var currentWordCount = 0
        var currentSentenceCount = 0

        func flush() {
            guard let first = currentEntries.first else { return }
            let paragraphText = currentEntries
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraphText.isEmpty else {
                currentEntries.removeAll(keepingCapacity: true)
                currentWordCount = 0
                currentSentenceCount = 0
                return
            }

            paragraphs.append(
                TimedParagraph(
                    id: first.id,
                    entryIDs: currentEntries.map(\.id),
                    startSeconds: first.startSeconds,
                    text: paragraphText
                )
            )
            currentEntries.removeAll(keepingCapacity: true)
            currentWordCount = 0
            currentSentenceCount = 0
        }

        for entry in entries {
            currentEntries.append(entry)
            currentWordCount += entry.text.split(whereSeparator: \.isWhitespace).count

            if let last = entry.text.last,
               Self.sentenceTerminators.contains(last) {
                currentSentenceCount += 1
            }

            let reachedSoftTarget = currentWordCount >= Self.paragraphSoftWordTarget
            let reachedHardLimit = currentWordCount >= Self.paragraphHardWordLimit
            let reachedChunkLimit = currentEntries.count >= Self.paragraphMaxChunks
            let reachedSentenceLimit = currentSentenceCount >= Self.paragraphMaxSentences

            if reachedHardLimit
                || reachedChunkLimit
                || (reachedSoftTarget && reachedSentenceLimit) {
                flush()
            }
        }

        flush()
        return paragraphs
    }
}
