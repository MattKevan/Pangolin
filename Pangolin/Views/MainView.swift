import os
// Views/MainView.swift

import SwiftUI
import CoreData

struct MainView: View {
    @Environment(LibraryManager.self) var libraryManager: LibraryManager
    @Environment(LibraryActions.self) private var libraryActions: LibraryActions
    @Environment(VideoFileManager.self) var videoFileManager: VideoFileManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let folderStore: FolderNavigationStore
    @State private var searchManager = SearchManager()
    @State private var playerViewModel = VideoPlayerViewModel()
    @State private var floatingVideoState = FloatingVideoState()
    @State private var videoPresentationFrameController = VideoPresentationFrameController()
    private let processingQueueManager = ProcessingQueueManager.shared
    
    let isStartingUp: Bool
    let startupError: LibraryError?
    let startupLoadingProgress: Double
    let retryAction: () -> Void
    let resetAction: () -> Void
    
    @State private var showingImportPicker = false
    @State private var showingURLImportSheet = false
    @State private var standardColumnVisibility: NavigationSplitViewVisibility = .all
    
    // Popover state for task indicator
    @State private var showTaskPopover = false
    @State private var isSearchFieldPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    
    init(
        libraryManager: LibraryManager,
        folderStore: FolderNavigationStore,
        isStartingUp: Bool = false,
        startupError: LibraryError? = nil,
        startupLoadingProgress: Double = 0,
        retryAction: @escaping () -> Void = {},
        resetAction: @escaping () -> Void = {}
    ) {
        self.folderStore = folderStore
        self.isStartingUp = isStartingUp
        self.startupError = startupError
        self.startupLoadingProgress = startupLoadingProgress
        self.retryAction = retryAction
        self.resetAction = resetAction
    }
    
    var body: some View {
        rootView
            .confirmsOptimizeAll(libraryActions)
            .onAppear {
                synchronizeVideoSelection()
            }
            .onChange(of: folderStore.selectedVideo?.id) { _, _ in
                synchronizeVideoSelection()
            }
            .onChange(of: folderStore.currentDetailSurface) { _, _ in
                synchronizeVideoSelection()
            }
    }

    private func synchronizeVideoSelection() {
        let selectedVideo = folderStore.selectedVideo
        let isVideoDetailActive = folderStore.currentDetailSurface == .videoDetail
        let activeVideo = isVideoDetailActive ? selectedVideo : nil
        if floatingVideoState.videoID != activeVideo?.id || !isVideoDetailActive {
            videoPresentationFrameController.reset()
        }
        floatingVideoState.reset(for: activeVideo?.id)

        switch VideoPlaybackSelection.action(
            selectedID: selectedVideo?.id,
            isVideoDetailActive: isVideoDetailActive,
            loadedID: playerViewModel.currentVideo?.id
        ) {
        case .load:
            if let activeVideo {
                playerViewModel.loadVideo(activeVideo)
            }
        case .clear:
            playerViewModel.clearLoadedVideo()
        case .none:
            break
        }
    }

    private var transcriptionService: SpeechTranscriptionService {
        processingQueueManager.transcriptionService
    }

    private var rootView: some View {
        RootContainerView(
            content: rootShellView,
            folderStore: folderStore,
            searchManager: searchManager,
            libraryManager: libraryManager,
            showingImportPicker: $showingImportPicker,
            showingURLImportSheet: $showingURLImportSheet,
            handleAutoTranscribe: handleAutoTranscribe,
            handleVideoImport: handleVideoImport,
            handleURLImport: handleURLImport
        )
    }

    @ViewBuilder
    private var rootShellView: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                phoneRootView
            } else {
                rootNavigationSplitView
            }
            #else
            rootNavigationSplitView
            #endif
        }
        .coordinateSpace(name: VideoFloatingCoordinateSpace.root)
        .overlay {
            VideoPresentationHost(
                selectedVideo: folderStore.selectedVideo,
                isVideoDetailActive: folderStore.currentDetailSurface == .videoDetail,
                playerViewModel: playerViewModel,
                floatingState: floatingVideoState,
                frameController: videoPresentationFrameController
            )
        }
    }

    @ViewBuilder
    private var rootNavigationSplitView: some View {
        if workspaceToolbarOwnership == .appOwned {
            baseNavigationSplitView
                .toolbar(removing: .sidebarToggle)
        } else {
            baseNavigationSplitView
        }
    }

    private var isWorkspaceVideoDetail: Bool {
        folderStore.showsVideoBackButton
    }

    private var workspaceToolbarOwnership: WorkspaceToolbarOwnership {
        VideoToolbarPolicy.ownership(
            shell: .workspace,
            isVideoDetail: isWorkspaceVideoDetail,
            supportsAppOwnedSidebarButton: supportsAppOwnedWorkspaceSidebarButton
        )
    }

    private var supportsAppOwnedWorkspaceSidebarButton: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass != .compact
        #endif
    }

    private var baseNavigationSplitView: some View {
        NavigationSplitView(columnVisibility: splitViewColumnVisibility) {
            sidebarColumn
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var splitViewColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                folderStore.showsVideoBackButton ? .detailOnly : standardColumnVisibility
            },
            set: { newValue in
                guard !folderStore.showsVideoBackButton else { return }
                standardColumnVisibility = newValue
            }
        )
    }

    private var sidebarColumn: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
            .environment(folderStore)
            .environment(libraryManager)
            .environment(searchManager)
            .applyManagedObjectContext(libraryManager.viewContext)
    }

    private var detailColumn: some View {
        configuredDetailColumn
            .toolbar {
                workspaceToolbarContent
            }
    }

    @ToolbarContentBuilder
    private var workspaceToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if VideoToolbarPolicy.showsSidebarButton(
                shell: .workspace,
                isVideoDetail: isWorkspaceVideoDetail,
                supportsAppOwnedSidebarButton: supportsAppOwnedWorkspaceSidebarButton
            ) {
                Button {
                    standardColumnVisibility = WorkspaceSidebarVisibilityPolicy.toggled(
                        from: standardColumnVisibility
                    )
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(standardColumnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .accessibilityLabel(standardColumnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
            }

            if VideoToolbarPolicy.showsVideoBackButton(
                shell: .workspace,
                isVideoDetail: isWorkspaceVideoDetail,
                supportsAppOwnedSidebarButton: supportsAppOwnedWorkspaceSidebarButton
            ) {
                Button {
                    folderStore.navigateBackFromDetail()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .accessibilityLabel("Back")
            } else if !isStartingUp && !folderStore.isSearchMode {
                if folderStore.showsProjectBackButton {
                    Button {
                        folderStore.navigateBackFromDetail()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                    .accessibilityLabel("Back")
                }

                Button {
                    showingImportPicker = true
                } label: {
                    Image(systemName: "video.badge.plus")
                }
                .help("Import videos")
                .disabled(libraryManager.currentLibrary == nil)

                #if os(macOS)
                Button {
                    showingURLImportSheet = true
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .help("Import from URL")
                .disabled(libraryManager.currentLibrary == nil)
                #endif
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !isStartingUp {
                activityWidget
            }
        }
    }

    /// The background-activity button, shown only while work is running or has failed.
    @ViewBuilder
    private var activityWidget: some View {
        if let presentation = activityPresentation {
            ActivityToolbarButton(
                presentation: presentation,
                accessibilityValue: "\(backgroundActivityCount) active tasks or transfers, \(processingQueueManager.failedTasks) failed tasks, \(videoFileManager.failedTransferCount) transfer issues",
                isPresented: $showTaskPopover
            ) {
                ProcessingPopoverView(processingManager: processingQueueManager)
            }
        }
    }

    private var activityPresentation: ActivityIndicatorPolicy.Presentation? {
        ActivityIndicatorPolicy.presentation(
            activeCount: backgroundActivityCount,
            failedTaskCount: processingQueueManager.failedTasks,
            transferIssueCount: videoFileManager.failedTransferCount,
            progress: activityProgress
        )
    }

    private var backgroundActivityCount: Int {
        processingQueueManager.visibleActiveTaskCount + videoFileManager.activeTransferCount
    }

    private var activityProgress: Double? {
        let taskCount = processingQueueManager.activeTaskCount
        let transferCount = videoFileManager.activeTransferCount
        let transferProgress = videoFileManager.activeTransferProgress

        switch (taskCount, transferCount, transferProgress) {
        case (let tasks, let transfers, let transferProgress?) where tasks > 0 && transfers > 0:
            return (
                processingQueueManager.overallProgress * Double(tasks)
                + transferProgress * Double(transfers)
            ) / Double(tasks + transfers)
        case (let tasks, _, _) where tasks > 0:
            return processingQueueManager.overallProgress
        case (_, let transfers, let transferProgress?) where transfers > 0:
            return transferProgress
        default:
            return nil
        }
    }

    @ViewBuilder
    private var configuredDetailColumn: some View {
        if isStartingUp {
            StartupInlineView(
                error: startupError,
                loadingProgress: startupLoadingProgress,
                retryAction: retryAction,
                resetAction: resetAction
            )
            .navigationSplitViewColumnWidth(min: 420, ideal: 760)
        } else {
            let baseDetailColumn = DetailColumnView(
                playerViewModel: playerViewModel,
                floatingVideoState: floatingVideoState
            )
                .environment(folderStore)
                .environment(searchManager)
                .environment(libraryManager)
                .environment(transcriptionService)
                .navigationSplitViewColumnWidth(min: 420, ideal: 760)
            .onChange(of: folderStore.isSearchMode) { _, isSearchMode in
                isSearchFieldPresented = isSearchMode
                if isSearchMode {
                    Task { @MainActor in
                        isSearchFieldFocused = true
                    }
                } else {
                    isSearchFieldFocused = false
                }
            }
            .onChange(of: searchManager.searchText) { _, _ in
                guard folderStore.isSearchMode else { return }
                // Keep the search field active while results/search state updates
                // re-render the detail column as the user types.
                Task { @MainActor in
                    isSearchFieldFocused = true
                }
            }

            if folderStore.isSearchMode {
                baseDetailColumn
                    .searchable(
                        text: $searchManager.searchText,
                        isPresented: $isSearchFieldPresented,
                        placement: .toolbarPrincipal,
                        prompt: "Search videos, transcripts, and summaries"
                    )
                    .searchFocused($isSearchFieldFocused)
                    .onSubmit(of: .search) {
                        guard folderStore.isSearchMode else { return }
                        let trimmedQuery = searchManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedQuery.isEmpty else { return }
                        searchManager.performManualSearch()
                    }
            } else {
                baseDetailColumn
            }
        }
    }

    #if os(iOS)
    private var phoneRootView: some View {
        PhoneRootView(
            searchManager: searchManager,
            transcriptionService: transcriptionService,
            playerViewModel: playerViewModel,
            floatingVideoState: floatingVideoState
        ) {
            if !isStartingUp {
                activityWidget
            }
        }
        .environment(folderStore)
        .environment(libraryManager)
        .environment(libraryActions)
        .environment(searchManager)
    }
    #endif
    
    
    private func hasTranscript(_ video: Video) -> Bool {
        if let t = video.transcriptText {
            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
    
    // MARK: - Helpers
    
    private func handleVideoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let library = libraryManager.currentLibrary,
                  let context = libraryManager.viewContext else { return }
            #if os(macOS)
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
            }
            #endif
            Task {
                #if os(macOS)
                defer {
                    for url in urls {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                #endif
                await processingQueueManager.enqueueImport(urls: urls, library: library, context: context)
            }
        case .failure(let error):
            Logger.app.info("Error importing files: \(error)")
        }
    }

    private func handleAutoTranscribe() {
        guard let video = folderStore.selectedVideo else { return }
        guard !hasTranscript(video) else { return }
        guard libraryManager.currentLibrary != nil else { return }
        processingQueueManager.enqueueTranscription(for: [video])
    }

    private func handleURLImport(_ url: URL) async throws {
        guard let library = libraryManager.currentLibrary, let context = libraryManager.viewContext else {
            throw FileSystemError.invalidLibraryPath
        }
        try await processingQueueManager.enqueueRemoteImport(url: url, library: library, context: context)
    }
}

private struct RootContainerView<Content: View>: View {
    let content: Content
    let folderStore: FolderNavigationStore
    let searchManager: SearchManager
    let libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleAutoTranscribe: () -> Void
    let handleVideoImport: (Result<[URL], Error>) -> Void
    let handleURLImport: (URL) async throws -> Void
    
    var body: some View {
        content
            .modifier(RootImportModifier(
                showingImportPicker: $showingImportPicker,
                showingURLImportSheet: $showingURLImportSheet,
                handleVideoImport: handleVideoImport,
                handleURLImport: handleURLImport
            ))
            .modifier(RootEventsModifier(
                folderStore: folderStore,
                searchManager: searchManager,
                libraryManager: libraryManager,
                showingImportPicker: $showingImportPicker,
                showingURLImportSheet: $showingURLImportSheet,
                handleAutoTranscribe: handleAutoTranscribe
            ))
            .modifier(RootAlertModifier(libraryManager: libraryManager))
    }
}

private struct RootImportModifier: ViewModifier {
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleVideoImport: (Result<[URL], Error>) -> Void
    let handleURLImport: (URL) async throws -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.movie, .video, .folder],
                allowsMultipleSelection: true
            ) { result in
                handleVideoImport(result)
            }
            #if os(macOS)
            .sheet(isPresented: $showingURLImportSheet) {
                ImportFromURLSheet(onImport: handleURLImport)
            }
            #endif
    }
}

private struct RootEventsModifier: ViewModifier {
    let folderStore: FolderNavigationStore
    let searchManager: SearchManager
    let libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleAutoTranscribe: () -> Void

    func body(content: Content) -> some View {
        let configuredContent = content
            .navigationTitle(folderStore.isSearchMode || folderStore.showsVideoBackButton ? "" : (libraryManager.currentLibrary?.name ?? "Pangolin"))
            .onAppear {
                StoragePolicyManager.shared.setProtectedSelectedVideoID(folderStore.selectedVideo?.id)
                handleAutoTranscribe()
            }
            .onChange(of: folderStore.selectedVideo?.id) { _, newVideoID in
                StoragePolicyManager.shared.setProtectedSelectedVideoID(newVideoID)
                handleAutoTranscribe()
            }
            .onChange(of: folderStore.selectedSidebarItem) { _, newSelection in
                if case .search = newSelection {
                    searchManager.activateSearch()
                } else {
                    searchManager.deactivateSearch()
                }
            }
        configuredContent
            .onReceive(NotificationCenter.default.publisher(for: .triggerCreateFolder)) { _ in
                createTopLevelProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerSearch)) { _ in
                // Activate search mode when Cmd+F is pressed
                folderStore.selectedSidebarItem = .search
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerImportVideos)) { _ in
                showingImportPicker = true
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .triggerImportFromURL)) { _ in
                showingURLImportSheet = true
            }
            #endif
    }

    private func createTopLevelProject() {
        Task { @MainActor in
            guard libraryManager.currentLibrary != nil,
                  let createdProjectID = await folderStore.createFolder(name: "Untitled Project", in: nil),
                  let project = folderStore.projects().first(where: { $0.id == createdProjectID }) else {
                return
            }
            folderStore.openProject(project)
        }
    }
}

private struct RootAlertModifier: ViewModifier {
    @Bindable var libraryManager: LibraryManager

    @ViewBuilder
    func body(content: Content) -> some View {
        if libraryManager.currentLibrary != nil {
            content.pangolinAlert(error: $libraryManager.error)
        } else {
            content
        }
    }
}

// MARK: - Detail Column View
private struct DetailColumnView: View {
    @Environment(FolderNavigationStore.self) private var folderStore
    @Environment(SearchManager.self) private var searchManager: SearchManager
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
    @Environment(SpeechTranscriptionService.self) private var transcriptionService: SpeechTranscriptionService
    let playerViewModel: VideoPlayerViewModel
    let floatingVideoState: FloatingVideoState

    var body: some View {
        Group {
            switch folderStore.currentDetailSurface {
            case .searchResults:
                SearchResultsView()
                    .environment(searchManager)
                    .environment(folderStore)
                    .environment(libraryManager)
            case .projectsList:
                ProjectsListView { folderStore.openProject($0) }
                    .environment(folderStore)
                    .environment(libraryManager)
            case .projectDetail:
                if let selectedProject = folderStore.selectedProject {
                    ProjectDetailView(project: selectedProject)
                        .environment(folderStore)
                } else {
                    ContentUnavailableView(
                        "No project selected",
                        systemImage: "square.grid.2x2",
                        description: Text("Choose a project from the grid.")
                    )
                }
            case .smartCollectionTable(_):
                FolderContentView()
                    .environment(folderStore)
                    .environment(libraryManager)
            case .videoDetail:
                if let selectedVideo = folderStore.selectedVideo {
                    DetailView(
                        video: selectedVideo,
                        playerViewModel: playerViewModel,
                        floatingVideoState: floatingVideoState
                    )
                        .environment(folderStore)
                        .environment(libraryManager)
                        .environment(transcriptionService)
                } else {
                    ContentUnavailableView(
                        "No video selected",
                        systemImage: "video",
                        description: Text("Select a video to view details.")
                    )
                }
            case .empty:
                ContentUnavailableView(
                    "No video selected",
                    systemImage: "video",
                    description: Text("Select a video to view details.")
                )
            }
        }
    }
}


// MARK: - View Modifier helper to conditionally inject context

private extension View {
    @ViewBuilder
    func applyManagedObjectContext(_ context: NSManagedObjectContext?) -> some View {
        if let context {
            self.environment(\.managedObjectContext, context)
        } else {
            self
        }
    }
}

// MARK: - Inline Startup View

private struct StartupInlineView: View {
    let error: LibraryError?
    let loadingProgress: Double
    let retryAction: () -> Void
    let resetAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.red)

                Text("Couldn't Open Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(error.localizedDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let recovery = error.recoverySuggestion {
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Retry", action: retryAction)
                        .buttonStyle(.borderedProminent)

                    if case .databaseCorrupted = error {
                        Button("Reset Library", action: resetAction)
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("Opening Library…")
                    .font(.headline)
                Text("Loading your cloud-backed library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if loadingProgress > 0 {
                    ProgressView(value: min(max(loadingProgress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
