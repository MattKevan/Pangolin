import SwiftUI

enum VideoDetailLayout {
    static let contentMaxWidth: CGFloat = 760
    static let horizontalPadding: CGFloat = 16
    static let compactActionSize: CGFloat = 34
    static let minimumActionHitSize: CGFloat = 44
}

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

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.size.width > 0
            && frame.size.height > 0
    }
}

private struct InlineVideoGeometry: Equatable {
    let videoID: UUID
    let frame: CGRect
}

private struct InlineVideoGeometryPreferenceKey: PreferenceKey {
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

private struct ActiveTranscriptGeometry: Equatable {
    let videoID: UUID
    let paragraphID: String
    let frame: CGRect
}

private struct ActiveTranscriptGeometryPreferenceKey: PreferenceKey {
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

struct DetailView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    let video: Video?

    @ObservedObject private var playerViewModel: VideoPlayerViewModel
    @ObservedObject private var floatingVideoState: FloatingVideoState
    @StateObject private var searchModel = VideoPageSearchModel()
    @State private var selectedInspectorTab: InspectorTab = .transcript
    @State private var isControlsInspectorPresented = false
    @State private var isSearchVisibleOnPhone = false
    @State private var pageScrollPosition: String?
    @State private var detailViewportSize = CGSize.zero
    @State private var activeTranscriptParagraphID: String?
    @State private var activeTranscriptMeasurement: ActiveTranscriptGeometry?
    @State private var isTranscriptFollowSuppressed = false
    @State private var isUserScrollingTranscript = false
    @State private var transcriptFollowSuppressionDeadline: Date?
    @State private var transcriptFollowResumeTask: Task<Void, Never>?

    init(
        video: Video?,
        playerViewModel: VideoPlayerViewModel,
        floatingVideoState: FloatingVideoState
    ) {
        self.video = video
        self._playerViewModel = ObservedObject(wrappedValue: playerViewModel)
        self._floatingVideoState = ObservedObject(wrappedValue: floatingVideoState)
    }

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
            if let selected = effectiveSelectedVideo {
                applyPendingSearchSeekIfNeeded(for: selected)
            }
        }
        .onChange(of: store.selectedVideo?.id) { _, _ in
            if let selected = effectiveSelectedVideo {
                applyPendingSearchSeekIfNeeded(for: selected)
            }
        }
        .onChange(of: selectedInspectorTab) { _, newValue in
            resetTranscriptFollowState()
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
        let topAnchorID = detailTopAnchorID(for: selectedVideo)

        GeometryReader { viewportGeometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header(for: selectedVideo)
                            .id(topAnchorID)

                        Divider()

                        if isSearchVisibleOnPhone && selectedInspectorTab == .transcript {
                            inlineSearchField
                                .frame(maxWidth: VideoDetailLayout.contentMaxWidth)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, VideoDetailLayout.horizontalPadding)
                                .padding(.vertical, 12)
                            Divider()
                        }

                        VideoPageTabPicker(selectedTab: $selectedInspectorTab)
                            .frame(maxWidth: VideoDetailLayout.contentMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, VideoDetailLayout.horizontalPadding)
                            .padding(.top, 12)

                        currentContent(for: selectedVideo, scrollProxy: proxy)
                            .frame(maxWidth: .infinity, alignment: .top)

                        navigationBar(for: selectedVideo)
                    }
                    .frame(maxWidth: .infinity)
                    .scrollTargetLayout()
                }
                .coordinateSpace(name: Self.detailViewportCoordinateSpace)
                .scrollPosition(id: $pageScrollPosition)
                .onPreferenceChange(InlineVideoGeometryPreferenceKey.self) { measurement in
                    updateInlineVideoVisibility(
                        measurement,
                        viewportSize: viewportGeometry.size,
                        selectedVideoID: selectedVideo.id
                    )
                }
                .onPreferenceChange(ActiveTranscriptGeometryPreferenceKey.self) { measurement in
                    updateActiveTranscriptMeasurement(
                        measurement,
                        selectedVideoID: selectedVideo.id,
                        scrollProxy: proxy
                    )
                }
                .onScrollPhaseChange { _, newPhase in
                    handleScrollPhase(
                        newPhase,
                        selectedVideoID: selectedVideo.id,
                        scrollProxy: proxy
                    )
                }
                .onAppear {
                    detailViewportSize = viewportGeometry.size
                    pageScrollPosition = topAnchorID
                }
                .onChange(of: viewportGeometry.size) { _, newSize in
                    detailViewportSize = newSize
                }
                .onChange(of: selectedVideo.id) { _, _ in
                    resetTranscriptFollowState()
                    pageScrollPosition = topAnchorID
                    proxy.scrollTo(topAnchorID, anchor: .top)
                }
                .onChange(of: playerViewModel.isPlaying) { _, isPlaying in
                    guard isPlaying else { return }
                    attemptTranscriptFollow(
                        mode: .resume,
                        selectedVideoID: selectedVideo.id,
                        scrollProxy: proxy
                    )
                }
                .onDisappear {
                    resetTranscriptFollowState()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appContentBackground)
    }

    @ViewBuilder
    private func header(for selectedVideo: Video) -> some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))

                if !floatingVideoState.isFloating {
                    VideoPlayerWithPosterView(video: selectedVideo, viewModel: playerViewModel)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: VideoDetailLayout.contentMaxWidth)
            .aspectRatio(playerViewModel.videoAspectRatio, contentMode: .fit)
            .background {
                if let videoID = selectedVideo.id {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: InlineVideoGeometryPreferenceKey.self,
                            value: InlineVideoGeometry(
                                videoID: videoID,
                                frame: geometry.frame(
                                    in: .named(Self.detailViewportCoordinateSpace)
                                )
                            )
                        )
                    }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Text(selectedVideo.title ?? "Untitled")
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                headerActionButtons(for: selectedVideo)
            }
        }
        .frame(maxWidth: VideoDetailLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, VideoDetailLayout.horizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(Color.appVideoHeaderBackground)
    }

    @ViewBuilder
    private func currentContent(
        for selectedVideo: Video,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        switch selectedInspectorTab {
        case .transcript:
            MergedTranscriptView(
                video: selectedVideo,
                playerViewModel: playerViewModel,
                searchModel: searchModel,
                preferredTranslationLocaleIdentifier: preferredTranslationLocaleIdentifier,
                onRequestScrollToParagraph: { paragraphID in
                    suppressTranscriptFollowForIntentionalNavigation(
                        selectedVideoID: selectedVideo.id,
                        scrollProxy: scrollProxy
                    )
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scrollProxy.scrollTo(paragraphID, anchor: .center)
                    }
                },
                onActiveParagraphChange: { paragraphID in
                    updateActiveTranscriptParagraph(
                        paragraphID,
                        selectedVideoID: selectedVideo.id
                    )
                }
            )
            .environmentObject(libraryManager)
        case .summary:
            SummaryView(video: selectedVideo)
                .environmentObject(libraryManager)
                .environmentObject(transcriptionService)
        }
    }

    static let detailViewportCoordinateSpace = "videoDetailViewport"

    private func updateActiveTranscriptParagraph(
        _ paragraphID: String?,
        selectedVideoID: UUID?
    ) {
        guard selectedInspectorTab == .transcript,
              let selectedVideoID,
              effectiveSelectedVideo?.id == selectedVideoID else {
            return
        }
        guard activeTranscriptParagraphID != paragraphID else { return }

        activeTranscriptParagraphID = paragraphID
        activeTranscriptMeasurement = nil
    }

    private func updateActiveTranscriptMeasurement(
        _ measurement: ActiveTranscriptGeometry?,
        selectedVideoID: UUID?,
        scrollProxy: ScrollViewProxy
    ) {
        guard selectedInspectorTab == .transcript,
              let selectedVideoID,
              effectiveSelectedVideo?.id == selectedVideoID else {
            return
        }

        guard let measurement else {
            activeTranscriptMeasurement = nil
            return
        }
        guard measurement.videoID == selectedVideoID,
              measurement.paragraphID == activeTranscriptParagraphID else {
            return
        }

        activeTranscriptMeasurement = measurement
        attemptTranscriptFollow(
            mode: .playbackAdvance,
            selectedVideoID: selectedVideoID,
            scrollProxy: scrollProxy
        )
    }

    private func handleScrollPhase(
        _ phase: ScrollPhase,
        selectedVideoID: UUID?,
        scrollProxy: ScrollViewProxy
    ) {
        guard selectedInspectorTab == .transcript,
              let selectedVideoID,
              effectiveSelectedVideo?.id == selectedVideoID else {
            return
        }

        switch phase {
        case .tracking, .interacting, .decelerating:
            transcriptFollowResumeTask?.cancel()
            transcriptFollowResumeTask = nil
            transcriptFollowSuppressionDeadline = nil
            isUserScrollingTranscript = true
            isTranscriptFollowSuppressed = true
        case .idle:
            guard isUserScrollingTranscript else { return }
            isUserScrollingTranscript = false
            scheduleTranscriptFollowResume(
                selectedVideoID: selectedVideoID,
                scrollProxy: scrollProxy
            )
        case .animating:
            break
        @unknown default:
            break
        }
    }

    private func suppressTranscriptFollowForIntentionalNavigation(
        selectedVideoID: UUID?,
        scrollProxy: ScrollViewProxy
    ) {
        guard selectedInspectorTab == .transcript,
              let selectedVideoID,
              effectiveSelectedVideo?.id == selectedVideoID else {
            return
        }

        isUserScrollingTranscript = false
        isTranscriptFollowSuppressed = true
        scheduleTranscriptFollowResume(
            selectedVideoID: selectedVideoID,
            scrollProxy: scrollProxy
        )
    }

    private func scheduleTranscriptFollowResume(
        selectedVideoID: UUID,
        scrollProxy: ScrollViewProxy
    ) {
        transcriptFollowResumeTask?.cancel()
        isTranscriptFollowSuppressed = true

        let deadline = TranscriptFollowPolicy.suppressionDeadline(after: Date())
        transcriptFollowSuppressionDeadline = deadline
        transcriptFollowResumeTask = Task { @MainActor in
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  transcriptFollowSuppressionDeadline == deadline,
                  selectedInspectorTab == .transcript,
                  effectiveSelectedVideo?.id == selectedVideoID else {
                return
            }

            transcriptFollowResumeTask = nil
            transcriptFollowSuppressionDeadline = nil
            isTranscriptFollowSuppressed = false
            attemptTranscriptFollow(
                mode: .resume,
                selectedVideoID: selectedVideoID,
                scrollProxy: scrollProxy
            )
        }
    }

    private func attemptTranscriptFollow(
        mode: TranscriptFollowMode,
        selectedVideoID: UUID?,
        scrollProxy: ScrollViewProxy
    ) {
        guard selectedInspectorTab == .transcript,
              let selectedVideoID,
              effectiveSelectedVideo?.id == selectedVideoID,
              let paragraphID = activeTranscriptParagraphID,
              playerViewModel.isPlaying,
              !isTranscriptFollowSuppressed else {
            return
        }

        let viewport = CGRect(origin: .zero, size: detailViewportSize)
        if let measurement = activeTranscriptMeasurement,
           measurement.videoID == selectedVideoID,
           measurement.paragraphID == paragraphID {
            guard TranscriptFollowPolicy.shouldScroll(
                paragraphFrame: measurement.frame,
                viewport: viewport,
                isPlaying: playerViewModel.isPlaying,
                isSuppressed: isTranscriptFollowSuppressed,
                mode: mode
            ) else {
                return
            }
        } else if mode != .resume {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            scrollProxy.scrollTo(paragraphID, anchor: .center)
        }
    }

    private func resetTranscriptFollowState() {
        transcriptFollowResumeTask?.cancel()
        transcriptFollowResumeTask = nil
        transcriptFollowSuppressionDeadline = nil
        isTranscriptFollowSuppressed = false
        isUserScrollingTranscript = false
        activeTranscriptParagraphID = nil
        activeTranscriptMeasurement = nil
    }

    private func updateInlineVideoVisibility(
        _ measurement: InlineVideoGeometry?,
        viewportSize: CGSize,
        selectedVideoID: UUID?
    ) {
        guard let selectedVideoID,
              floatingVideoState.videoID == selectedVideoID else { return }

        guard let measurement else {
            floatingVideoState.updateVisibilityMeasurement(nil)
            return
        }

        guard measurement.videoID == selectedVideoID,
              isValidMeasurement(measurement.frame),
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return }

        floatingVideoState.updateInlineWidth(measurement.frame.width)
        floatingVideoState.updateVisibilityMeasurement(
            VideoFloatingLayout.visibleFraction(
                of: measurement.frame,
                in: CGRect(origin: .zero, size: viewportSize)
            )
        )
    }

    private func isValidMeasurement(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
            && frame.size.width > 0
            && frame.size.height > 0
    }

    private func detailTopAnchorID(for video: Video) -> String {
        let videoIdentifier = video.id?.uuidString
            ?? video.objectID.uriRepresentation().absoluteString
        return "video-detail-top-\(videoIdentifier)"
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
            .frame(maxWidth: VideoDetailLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, VideoDetailLayout.horizontalPadding)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func headerActionButtons(for selectedVideo: Video) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    headerActionButton(
                        systemImage: selectedVideo.isFavorite ? "heart.fill" : "heart",
                        accessibilityLabel: selectedVideo.isFavorite ? "Remove favorite" : "Add favorite"
                    ) {
                        toggleFavorite(video: selectedVideo)
                    }

                    headerActionButton(
                        systemImage: actionButtonSymbolName,
                        accessibilityLabel: "More actions"
                    ) {
                        handlePrimaryAction()
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                headerActionButton(
                    systemImage: selectedVideo.isFavorite ? "heart.fill" : "heart",
                    accessibilityLabel: selectedVideo.isFavorite ? "Remove favorite" : "Add favorite"
                ) {
                    toggleFavorite(video: selectedVideo)
                }

                headerActionButton(
                    systemImage: actionButtonSymbolName,
                    accessibilityLabel: "More actions"
                ) {
                    handlePrimaryAction()
                }
            }
        }
    }

    private func headerActionButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: VideoDetailLayout.compactActionSize, height: VideoDetailLayout.compactActionSize)
                .pangolinGlassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .frame(width: VideoDetailLayout.minimumActionHitSize, height: VideoDetailLayout.minimumActionHitSize)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
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
        .pangolinGlassRoundedRect(cornerRadius: 16, interactive: true)
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
        .pangolinGlassRoundedRect(cornerRadius: 16, interactive: true)
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
        .padding(6)
        .frame(maxWidth: 340, alignment: .leading)
        .pangolinGlassRoundedRect(cornerRadius: 22, interactive: true)
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
                navigationButton(title: previousTitle, systemImage: "chevron.left", trailingIcon: false, action: onPrevious)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }

            Spacer()

            if let nextTitle {
                navigationButton(title: nextTitle, systemImage: "chevron.right", trailingIcon: true, action: onNext)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
        }
    }

    private func navigationButton(
        title: String,
        systemImage: String,
        trailingIcon: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if !trailingIcon {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.headline.weight(.semibold))

                if trailingIcon {
                    Image(systemName: systemImage)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minWidth: 148)
        }
        .pangolinGlassButton()
        .buttonBorderShape(.capsule)
    }
}

struct MergedTranscriptView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

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
