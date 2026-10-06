import os
import SwiftUI

enum VideoDetailLayout {
    static let contentMaxWidth: CGFloat = 760
    static let horizontalPadding: CGFloat = 16
    static let compactActionSize: CGFloat = 34
    static let minimumActionHitSize: CGFloat = 44
}


struct DetailView: View {
    @Environment(FolderNavigationStore.self) private var store
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
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
                        .environment(libraryManager)
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
                    .environment(libraryManager)
                    .environmentObject(transcriptionService)
            }
        }
        #endif
    }

    @ViewBuilder
    private func page(for selectedVideo: Video) -> some View {
        let topAnchorID = detailTopAnchorID(for: selectedVideo)

        GeometryReader { viewportGeometry in
            let presentationViewportFrame = viewportGeometry.frame(
                in: .named(VideoFloatingCoordinateSpace.root)
            )

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
                    updatePresentationViewport(
                        presentationViewportFrame,
                        selectedVideoID: selectedVideo.id
                    )
                    pageScrollPosition = topAnchorID
                }
                .onChange(of: viewportGeometry.size) { _, newSize in
                    detailViewportSize = newSize
                }
                .onChange(of: presentationViewportFrame) { _, newFrame in
                    updatePresentationViewport(
                        newFrame,
                        selectedVideoID: selectedVideo.id
                    )
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
                                ),
                                rootFrame: geometry.frame(
                                    in: .named(VideoFloatingCoordinateSpace.root)
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
                        selectedVideoID: selectedVideo.id,
                        scrollProxy: scrollProxy
                    )
                }
            )
            .environment(libraryManager)
        case .summary:
            SummaryView(video: selectedVideo)
                .environment(libraryManager)
                .environmentObject(transcriptionService)
        }
    }

    static let detailViewportCoordinateSpace = "videoDetailViewport"

    private func updateActiveTranscriptParagraph(
        _ paragraphID: String?,
        selectedVideoID: UUID?,
        scrollProxy: ScrollViewProxy
    ) {
        guard selectedInspectorTab == .transcript,
              let selectedVideoID,
              effectiveSelectedVideo?.id == selectedVideoID else {
            return
        }
        guard activeTranscriptParagraphID != paragraphID else { return }

        if TranscriptFollowPolicy.shouldResetLifecycle(
            activeParagraphID: paragraphID
        ) {
            resetTranscriptFollowState()
            return
        }

        activeTranscriptParagraphID = paragraphID
        activeTranscriptMeasurement = nil
        attemptTranscriptFollow(
            mode: .playbackAdvance,
            selectedVideoID: selectedVideoID,
            scrollProxy: scrollProxy
        )
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
        let hasCurrentMeasurement = activeTranscriptMeasurement?.videoID == selectedVideoID
            && activeTranscriptMeasurement?.paragraphID == paragraphID
        if hasCurrentMeasurement, let measurement = activeTranscriptMeasurement {
            guard TranscriptFollowPolicy.shouldScroll(
                paragraphFrame: measurement.frame,
                viewport: viewport,
                isPlaying: playerViewModel.isPlaying,
                isSuppressed: isTranscriptFollowSuppressed,
                mode: mode
            ) else {
                return
            }
        } else {
            guard TranscriptFollowPolicy.shouldScrollToIDFallback(
                hasActiveParagraph: true,
                hasMeasurement: false,
                isPlaying: playerViewModel.isPlaying,
                isSuppressed: isTranscriptFollowSuppressed
            ) else { return }
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
              isValidMeasurement(measurement.rootFrame),
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return }

        floatingVideoState.updateInlineWidth(measurement.frame.width)
        floatingVideoState.updateInlineFrame(measurement.rootFrame)
        floatingVideoState.updateVisibilityMeasurement(
            VideoFloatingLayout.visibleFraction(
                of: measurement.frame,
                in: CGRect(origin: .zero, size: viewportSize)
            )
        )
    }

    private func updatePresentationViewport(
        _ frame: CGRect,
        selectedVideoID: UUID?
    ) {
        guard let selectedVideoID,
              floatingVideoState.videoID == selectedVideoID else { return }
        floatingVideoState.updatePresentationViewportFrame(frame)
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
        let _ = store.contentRevision
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
        VideoPageSearchField(searchModel: searchModel)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .pangolinGlassRoundedRect(cornerRadius: 16, interactive: true)
            .frame(minWidth: 260, idealWidth: 320)
    }

    private var inlineSearchField: some View {
        VideoPageSearchField(searchModel: searchModel) {
            isSearchVisibleOnPhone = false
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
            Logger.app.error("FAVORITE: Failed to save favorite status from detail toolbar: \(error)")
            video.isFavorite.toggle()
        }
    }
}

/// Shared search field for the video page. The macOS toolbar placement and the
/// iOS inline placement differ only in surrounding chrome (padding, glass,
/// frame), which the call sites apply.
