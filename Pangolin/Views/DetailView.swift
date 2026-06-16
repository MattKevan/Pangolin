import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    let video: Video?

    @StateObject private var playerViewModel = VideoPlayerViewModel()
    @StateObject private var searchModel = VideoPageSearchModel()
    @State private var selectedInspectorTab: InspectorTab = .transcript
    @State private var isControlsInspectorPresented = false
    @State private var isSearchVisibleOnPhone = false

    private var effectiveSelectedVideo: Video? {
        store.selectedVideo ?? video
    }

    var body: some View {
        Group {
            if let selectedVideo = effectiveSelectedVideo {
                page(for: selectedVideo)
            } else {
                ContentUnavailableView(
                    "No video selected",
                    systemImage: "video",
                    description: Text("Select a video to view details.")
                )
            }
        }
        .onAppear {
            if let initial = video, store.selectedVideo == nil {
                store.selectVideo(initial)
            }
            if let selected = effectiveSelectedVideo,
               (playerViewModel.currentVideo?.id != selected.id || playerViewModel.player == nil) {
                playerViewModel.loadVideo(selected)
                applyPendingSearchSeekIfNeeded(for: selected)
            }
        }
        .onChange(of: store.selectedVideo?.id) { _, _ in
            if let selected = effectiveSelectedVideo {
                playerViewModel.loadVideo(selected)
                applyPendingSearchSeekIfNeeded(for: selected)
            } else {
                playerViewModel.clearLoadedVideo()
            }
        }
        .onChange(of: selectedInspectorTab) { _, newValue in
            if newValue != .transcript {
                searchModel.reset()
                isSearchVisibleOnPhone = false
            }
        }
        .toolbar {
            toolbarContent
        }
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: phoneControlsBinding) {
            if let selectedVideo = effectiveSelectedVideo {
                NavigationStack {
                    ProcessingControlsInspectorView(tab: .transcript, video: selectedVideo)
                        .environmentObject(libraryManager)
                        .environmentObject(transcriptionService)
                        .navigationTitle("Transcript settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    isControlsInspectorPresented = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
        #elseif os(macOS)
        .inspector(isPresented: controlsInspectorBinding) {
            if let selectedVideo = effectiveSelectedVideo,
               selectedInspectorTab.supportsRightControlsInspector {
                ProcessingControlsInspectorView(tab: selectedInspectorTab, video: selectedVideo)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
            }
        }
        #endif
    }

    @ViewBuilder
    private func page(for selectedVideo: Video) -> some View {
        VStack(spacing: 0) {
            header(for: selectedVideo)
            Divider()

            if isSearchVisibleOnPhone && selectedInspectorTab == .transcript {
                inlineSearchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
            }

            VideoPageTabPicker(selectedTab: $selectedInspectorTab)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            currentContent(for: selectedVideo)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .safeAreaInset(edge: .bottom) {
            navigationBar(for: selectedVideo)
        }
    }

    private var backgroundColor: Color {
        #if os(macOS)
        Color.appWindowBackground
        #else
        Color(.systemBackground)
        #endif
    }

    @ViewBuilder
    private func header(for selectedVideo: Video) -> some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))

                VideoPlayerWithPosterView(video: selectedVideo, viewModel: playerViewModel)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: 760)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)

            HStack(alignment: .center, spacing: 12) {
                Text(selectedVideo.title ?? "Untitled")
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    toggleFavorite(video: selectedVideo)
                } label: {
                    Image(systemName: selectedVideo.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)

                Button {
                    handlePrimaryAction()
                } label: {
                    Image(systemName: actionButtonSymbolName)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(backgroundColor)
    }

    @ViewBuilder
    private func currentContent(for selectedVideo: Video) -> some View {
        switch selectedInspectorTab {
        case .transcript:
            MergedTranscriptView(
                video: selectedVideo,
                playerViewModel: playerViewModel,
                searchModel: searchModel,
                preferredTranslationLocaleIdentifier: preferredTranslationLocaleIdentifier
            )
            .environmentObject(libraryManager)
        case .summary:
            SummaryView(video: selectedVideo)
                .environmentObject(libraryManager)
                .environmentObject(transcriptionService)
        }
    }

    @ViewBuilder
    private func navigationBar(for selectedVideo: Video) -> some View {
        let neighbors = store.videoNeighbors(for: selectedVideo)
        if neighbors.previous != nil || neighbors.next != nil {
            VideoPageNavigationBar(
                previousTitle: neighbors.previous == nil ? nil : "Previous",
                nextTitle: neighbors.next == nil ? nil : "Next",
                onPrevious: {
                    if let previous = neighbors.previous {
                        store.selectVideo(previous)
                    }
                },
                onNext: {
                    if let next = neighbors.next {
                        store.selectVideo(next)
                    }
                }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var preferredTranslationLocaleIdentifier: String {
        let preferences = VideoPagePreferences()
        let stored = preferences.preferredTranslationLocaleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? Locale.current.identifier : stored
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        if selectedInspectorTab == .transcript {
            ToolbarItem(placement: .principal) {
                toolbarSearchField
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if canShowControlsInspector {
                Button {
                    isControlsInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
            }
        }
        #else
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectedInspectorTab == .transcript {
                Button {
                    isSearchVisibleOnPhone.toggle()
                } label: {
                    Image(systemName: "magnifyingglass")
                }

                Button {
                    isControlsInspectorPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        #endif
    }

    private var toolbarSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search in video", text: $searchModel.query)
                .textFieldStyle(.plain)

            if !searchModel.query.isEmpty {
                Text(searchModel.matchPositionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    searchModel.moveToPreviousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)

                Button {
                    searchModel.moveToNextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)

                Button {
                    searchModel.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(minWidth: 260, idealWidth: 320)
    }

    private var inlineSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search in video", text: $searchModel.query)
                .textFieldStyle(.plain)

            if !searchModel.query.isEmpty {
                Text(searchModel.matchPositionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    searchModel.moveToPreviousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)

                Button {
                    searchModel.moveToNextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)

                Button {
                    searchModel.reset()
                    isSearchVisibleOnPhone = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var canShowControlsInspector: Bool {
        effectiveSelectedVideo != nil && selectedInspectorTab.supportsRightControlsInspector
    }

    private var actionButtonSymbolName: String {
        #if os(macOS)
        return canShowControlsInspector && isControlsInspectorPresented ? "sidebar.right" : "ellipsis"
        #else
        return "ellipsis"
        #endif
    }

    private func handlePrimaryAction() {
        #if os(macOS)
        if canShowControlsInspector {
            isControlsInspectorPresented.toggle()
        }
        #else
        if selectedInspectorTab == .transcript {
            isControlsInspectorPresented = true
        }
        #endif
    }

    #if os(macOS)
    private var controlsInspectorBinding: Binding<Bool> {
        Binding(
            get: { canShowControlsInspector && isControlsInspectorPresented },
            set: { isControlsInspectorPresented = $0 }
        )
    }
    #endif

    #if os(iOS)
    private var phoneControlsBinding: Binding<Bool> {
        Binding(
            get: { selectedInspectorTab == .transcript && isControlsInspectorPresented },
            set: { isControlsInspectorPresented = $0 }
        )
    }
    #endif

    private func applyPendingSearchSeekIfNeeded(for video: Video) {
        guard let videoID = video.id,
              let pending = store.consumePendingSearchSeekRequest(for: videoID) else {
            return
        }

        if let source = pending.source {
            switch source {
            case .transcript, .translation:
                selectedInspectorTab = .transcript
            case .summary:
                selectedInspectorTab = .summary
            case .title:
                break
            }
        }

        if let seconds = pending.seconds {
            playerViewModel.seek(to: seconds, in: video)
        }
    }

    private func toggleFavorite(video: Video) {
        guard let context = libraryManager.viewContext else { return }

        video.isFavorite.toggle()

        do {
            try context.save()
        } catch {
            print("❌ FAVORITE: Failed to save favorite status from detail toolbar: \(error)")
            video.isFavorite.toggle()
        }
    }
}

@MainActor
final class VideoPageSearchModel: ObservableObject {
    enum Direction {
        case previous
        case next
    }

    @Published var query = ""
    @Published private(set) var totalMatches = 0
    @Published private(set) var currentMatchIndex: Int?
    @Published fileprivate var navigationRequestID = 0
    fileprivate private(set) var direction: Direction = .next

    var matchPositionLabel: String {
        guard let currentMatchIndex, totalMatches > 0 else { return "0/0" }
        return "\(currentMatchIndex + 1)/\(totalMatches)"
    }

    func moveToPreviousMatch() {
        guard totalMatches > 0 else { return }
        direction = .previous
        navigationRequestID += 1
    }

    func moveToNextMatch() {
        guard totalMatches > 0 else { return }
        direction = .next
        navigationRequestID += 1
    }

    func setSearchState(totalMatches: Int, currentMatchIndex: Int?) {
        self.totalMatches = totalMatches
        self.currentMatchIndex = currentMatchIndex
    }

    func reset() {
        query = ""
        setSearchState(totalMatches: 0, currentMatchIndex: nil)
    }
}

struct VideoPageTabPicker: View {
    @Binding var selectedTab: InspectorTab

    var body: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

struct VideoPageNavigationBar: View {
    let previousTitle: String?
    let nextTitle: String?
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            if let previousTitle {
                Button(action: onPrevious) {
                    Label(previousTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }

            Spacer()

            if let nextTitle {
                Button(action: onNext) {
                    Label(nextTitle, systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
        }
    }
}

struct MergedTranscriptView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    @ObservedObject var video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject var searchModel: VideoPageSearchModel
    let preferredTranslationLocaleIdentifier: String?

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
        ScrollViewReader { proxy in
            ScrollView {
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
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .onAppear {
                loadContent()
                updateActiveParagraph(for: playerViewModel.currentTime)
                refreshSearchState(using: proxy)
            }
            .onChange(of: video.id) { _, _ in
                loadContent()
                refreshSearchState(using: proxy)
            }
            .onChange(of: video.transcriptDateGenerated) { _, _ in
                loadContent()
                refreshSearchState(using: proxy)
            }
            .onChange(of: video.translationDateGenerated) { _, _ in
                loadContent()
                refreshSearchState(using: proxy)
            }
            .onChange(of: video.translatedLanguage) { _, _ in
                loadContent()
                refreshSearchState(using: proxy)
            }
            .onChange(of: preferredTranslationLocaleIdentifier) { _, _ in
                loadContent()
                refreshSearchState(using: proxy)
            }
            .onChange(of: playerViewModel.currentTime) { _, newTime in
                updateActiveParagraph(for: newTime)
            }
            .onChange(of: searchModel.query) { _, _ in
                refreshSearchState(using: proxy)
            }
            .onChange(of: searchModel.navigationRequestID) { _, _ in
                moveAcrossSearchResults(using: proxy)
            }
            .onChange(of: activeParagraphID) { _, paragraphID in
                guard searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let paragraphID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(paragraphID, anchor: .center)
                }
            }
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

    private func moveAcrossSearchResults(using proxy: ScrollViewProxy) {
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
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(matches[nextIndex], anchor: .center)
        }
    }

    private func refreshSearchState(using proxy: ScrollViewProxy) {
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

        if !searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(nextMatchID, anchor: .center)
            }
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
           let timedURL = libraryManager.existingTimedTranslationURL(for: video, languageCode: translatedLanguage),
           FileManager.default.fileExists(atPath: timedURL.path),
           let translation = try? libraryManager.readTimedTranslation(from: timedURL) {
            return .timedTranslation(translation.makeChunkIndex())
        }

        if shouldPreferTranslation,
           let translatedText = video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translatedText.isEmpty {
            return .plainTranslation(translatedText)
        }

        if let timedURL = libraryManager.existingTimedTranscriptURL(for: video),
           let transcript = try? libraryManager.readTimedTranscriptIfAvailable(from: timedURL) {
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
            activeParagraphID = nil
            return
        }

        activeParagraphID = timedParagraphs.last(where: { paragraph in
            paragraph.startSeconds <= time
        })?.id
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
