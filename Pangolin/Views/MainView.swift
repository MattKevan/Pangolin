import os
// Views/MainView.swift

import SwiftUI
import CoreData

struct MainView: View {
    #if os(iOS)
    private enum PhoneTab: Hashable {
        case projects
        case allVideos
        case favourites
        case search
    }

    fileprivate enum PhoneVideoRoute: Hashable {
        case video(UUID)

        var videoID: UUID {
            switch self {
            case .video(let videoID):
                videoID
            }
        }
    }
    #endif

    @Environment(LibraryManager.self) var libraryManager: LibraryManager
    @EnvironmentObject var videoFileManager: VideoFileManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var folderStore: FolderNavigationStore
    @StateObject private var searchManager = SearchManager()
    @State private var playerViewModel = VideoPlayerViewModel()
    @StateObject private var floatingVideoState = FloatingVideoState()
    @StateObject private var videoPresentationFrameController = VideoPresentationFrameController()
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
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
    #if os(iOS)
    @State private var phoneSelectedTab: PhoneTab = .projects
    @State private var phoneProjectsPath: [PhoneProjectsRoute] = []
    @State private var isUnwindingPhoneProjectVideo = false
    @State private var isSwitchingPhoneTabs = false
    #endif
    
    init(
        libraryManager: LibraryManager,
        isStartingUp: Bool = false,
        startupError: LibraryError? = nil,
        startupLoadingProgress: Double = 0,
        retryAction: @escaping () -> Void = {},
        resetAction: @escaping () -> Void = {}
    ) {
        self._folderStore = State(initialValue: FolderNavigationStore(libraryManager: libraryManager))
        self.isStartingUp = isStartingUp
        self.startupError = startupError
        self.startupLoadingProgress = startupLoadingProgress
        self.retryAction = retryAction
        self.resetAction = resetAction
    }
    
    var body: some View {
        rootView
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
            .environmentObject(searchManager)
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
            if !isStartingUp && (backgroundActivityCount > 0 || processingQueueManager.failedTasks > 0 || videoFileManager.failedTransferCount > 0) {
                Button {
                    showTaskPopover.toggle()
                } label: {
                    let hasActiveTasks = backgroundActivityCount > 0
                    let failedProcessingCount = processingQueueManager.failedTasks
                    let transferIssueCount = videoFileManager.failedTransferCount
                    let nonActiveIssueCount = transferIssueCount + failedProcessingCount
                    let badgeCount = nonActiveIssueCount > 0 ? nonActiveIssueCount : max(0, backgroundActivityCount - 1)

                    ZStack(alignment: .topTrailing) {
                        if let activityProgress {
                            ProgressView(value: activityProgress)
                                .progressViewStyle(.circular)
                                .frame(width: 16, height: 16)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                        } else if hasActiveTasks {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                        }

                        if badgeCount > 0 {
                            Text("\(min(badgeCount, 99))")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 12, height: 12)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 4, y: -2)
                        }
                    }
                    .frame(minWidth: 24, minHeight: 22, alignment: .center)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Background tasks")
                    .accessibilityValue("\(backgroundActivityCount) active tasks or transfers, \(processingQueueManager.failedTasks) failed tasks, \(videoFileManager.failedTransferCount) transfer issues")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                    ProcessingPopoverView(processingManager: processingQueueManager)
                }
            }
        }
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
                .environmentObject(searchManager)
                .environment(libraryManager)
                .environmentObject(transcriptionService)
                .navigationSplitViewColumnWidth(min: 420, ideal: 760)
            .onChange(of: folderStore.isSearchMode) { _, isSearchMode in
                isSearchFieldPresented = isSearchMode
                if isSearchMode {
                    DispatchQueue.main.async {
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
        TabView(selection: $phoneSelectedTab) {
            Tab("Projects", systemImage: "square.grid.2x2", value: .projects) {
                NavigationStack(path: $phoneProjectsPath) {
                    ProjectsGridView { project in
                        openPhoneProject(project)
                    }
                    .environment(folderStore)
                    .navigationDestination(for: PhoneProjectsRoute.self) { route in
                        switch route {
                        case .project(let projectID):
                            if let project = folderStore.project(with: projectID) {
                                ProjectDetailView(
                                    project: project,
                                    showsPhoneToolbar: true
                                )
                                .environment(folderStore)
                            } else {
                                ContentUnavailableView(
                                    "Project unavailable",
                                    systemImage: "square.grid.2x2",
                                    description: Text("The selected project could not be loaded.")
                                )
                            }
                        case .video(let videoID):
                            if let video = folderStore.video(with: videoID) {
                                DetailView(
                                    video: video,
                                    playerViewModel: playerViewModel,
                                    floatingVideoState: floatingVideoState
                                )
                                    .environment(folderStore)
                                    .environment(libraryManager)
                                    .environmentObject(transcriptionService)
                            } else {
                                ContentUnavailableView(
                                    "Video unavailable",
                                    systemImage: "video",
                                    description: Text("The selected video could not be loaded.")
                                )
                            }
                        }
                    }
                    .onChange(of: folderStore.selectedVideo?.id) { _, newValue in
                        guard phoneSelectedTab == .projects,
                              !isUnwindingPhoneProjectVideo,
                              !isSwitchingPhoneTabs else { return }
                        if let videoID = newValue,
                           folderStore.selectedProject != nil {
                            synchronizePhoneProjectVideoRoute(to: videoID)
                        } else if newValue == nil {
                            reconcileDeselectedPhoneProjectVideo()
                        }
                    }
                    .onChange(of: phoneProjectsPath) { oldValue, newValue in
                        handlePhoneProjectsPathChange(from: oldValue, to: newValue)
                    }
                    .onChange(of: phoneSelectedTab) { _, newValue in
                        guard newValue != .projects else { return }
                        deactivatePhoneProjectVideoRoute()
                    }
                }
            }

            Tab("All videos", systemImage: "list.bullet", value: .allVideos) {
                PhoneVideoNavigationStack(
                    isActive: phoneSelectedTab == .allVideos,
                    isSwitchingTabs: isSwitchingPhoneTabs,
                    playerViewModel: playerViewModel,
                    floatingVideoState: floatingVideoState
                ) {
                    PhoneCollectionTabView(
                        title: "All videos",
                        onAppear: { folderStore.selectedSidebarItem = .smartCollection(.allVideos) }
                    )
                }
                .environment(folderStore)
                .environment(libraryManager)
                .environmentObject(transcriptionService)
            }

            Tab("Favourites", systemImage: "heart", value: .favourites) {
                PhoneVideoNavigationStack(
                    isActive: phoneSelectedTab == .favourites,
                    isSwitchingTabs: isSwitchingPhoneTabs,
                    playerViewModel: playerViewModel,
                    floatingVideoState: floatingVideoState
                ) {
                    PhoneCollectionTabView(
                        title: "Favourites",
                        onAppear: { folderStore.selectedSidebarItem = .smartCollection(.favorites) }
                    )
                }
                .environment(folderStore)
                .environment(libraryManager)
                .environmentObject(transcriptionService)
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                PhoneVideoNavigationStack(
                    isActive: phoneSelectedTab == .search,
                    isSwitchingTabs: isSwitchingPhoneTabs,
                    playerViewModel: playerViewModel,
                    floatingVideoState: floatingVideoState
                ) {
                    SearchResultsView()
                        .environmentObject(searchManager)
                        .navigationTitle("Search")
                }
                .environment(folderStore)
                .environment(libraryManager)
                .environmentObject(transcriptionService)
                .searchable(
                    text: $searchManager.searchText,
                    placement: .automatic,
                    prompt: "Search videos, transcripts, and summaries"
                )
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onAppear {
            syncPhoneTabSelection()
        }
        .onChange(of: phoneSelectedTab) { _, _ in
            // A tab switch abandons the old detail instead of navigating Back into
            // its origin. Tab-local stacks remove their routes independently.
            isSwitchingPhoneTabs = true
            folderStore.abandonVideoDetail()
            syncPhoneTabSelection()
            Task { @MainActor in
                await Task.yield()
                isSwitchingPhoneTabs = false
            }
        }
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

    #if os(iOS)
    private func openPhoneProject(_ project: Folder) {
        folderStore.openProject(project)
        guard let projectID = project.id else { return }
        if phoneProjectsPath.last != .project(projectID) {
            phoneProjectsPath.append(.project(projectID))
        }
    }

    private func handlePhoneProjectsPathChange(
        from oldValue: [PhoneProjectsRoute],
        to newValue: [PhoneProjectsRoute]
    ) {
        guard !isUnwindingPhoneProjectVideo else { return }
        let shouldNavigateBack = PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: oldValue.compactMap(\.videoID),
            newVideoRouteIDs: newValue.compactMap(\.videoID),
            selectedVideoID: folderStore.selectedVideo?.id,
            isVideoDetailActive: phoneSelectedTab == .projects
                && folderStore.currentDetailSurface == .videoDetail
        )
        guard shouldNavigateBack else { return }

        isUnwindingPhoneProjectVideo = true
        folderStore.navigateBackFromDetail()
        Task { @MainActor in
            await Task.yield()
            isUnwindingPhoneProjectVideo = false
        }
    }

    private func synchronizePhoneProjectVideoRoute(to videoID: UUID) {
        switch PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: phoneProjectsPath.compactMap(\.videoID),
            selectedVideoID: videoID
        ) {
        case .none:
            return
        case .append:
            phoneProjectsPath.append(.video(videoID))
        case .replace:
            phoneProjectsPath = PhoneProjectsPathPolicy.removingVideoRoutes(
                from: phoneProjectsPath
            ) + [.video(videoID)]
        }
    }

    private func deactivatePhoneProjectVideoRoute() {
        switch PhoneVideoRouteDeactivationPolicy.action(
            existingVideoRouteIDs: phoneProjectsPath.compactMap(\.videoID)
        ) {
        case .none:
            return
        case .removeVideoRoutes:
            isUnwindingPhoneProjectVideo = true
            phoneProjectsPath = PhoneProjectsPathPolicy.removingVideoRoutes(
                from: phoneProjectsPath
            )
            Task { @MainActor in
                await Task.yield()
                isUnwindingPhoneProjectVideo = false
            }
        }
    }

    private func reconcileDeselectedPhoneProjectVideo() {
        let action = PhoneVideoRouteSelectionReconciliationPolicy.action(
            existingVideoRouteIDs: phoneProjectsPath.compactMap(\.videoID),
            selectedVideoID: folderStore.selectedVideo?.id,
            isSwitchingTabs: isSwitchingPhoneTabs
        )
        guard action == .removeVideoRoutes else { return }

        isUnwindingPhoneProjectVideo = true
        folderStore.restoreVideoNavigationOriginAfterSelectionCleared()
        phoneProjectsPath = PhoneProjectsPathPolicy.removingVideoRoutes(
            from: phoneProjectsPath
        )
        Task { @MainActor in
            await Task.yield()
            isUnwindingPhoneProjectVideo = false
        }
    }

    private func syncPhoneTabSelection() {
        switch phoneSelectedTab {
        case .projects:
            folderStore.selectProjects()
        case .allVideos:
            folderStore.selectAllVideos()
        case .favourites:
            folderStore.selectedSidebarItem = .smartCollection(.favorites)
        case .search:
            folderStore.activateSearch()
        }
    }
    #endif
}

private struct RootContainerView<Content: View>: View {
    let content: Content
    let folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
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
    @ObservedObject var searchManager: SearchManager
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
    @EnvironmentObject private var searchManager: SearchManager
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService
    let playerViewModel: VideoPlayerViewModel
    @ObservedObject var floatingVideoState: FloatingVideoState

    var body: some View {
        Group {
            switch folderStore.currentDetailSurface {
            case .searchResults:
                SearchResultsView()
                    .environmentObject(searchManager)
                    .environment(folderStore)
                    .environment(libraryManager)
            case .projectsGrid:
                ProjectsGridView()
                    .environment(folderStore)
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
                        .environmentObject(transcriptionService)
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

#if os(iOS)
private struct PhoneCollectionTabView: View {
    @Environment(FolderNavigationStore.self) private var folderStore
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager

    let title: String
    let onAppear: () -> Void

    var body: some View {
        FolderContentView()
            .environment(folderStore)
            .environment(libraryManager)
            .navigationTitle(title)
            .onAppear(perform: onAppear)
    }
}

private struct PhoneVideoNavigationStack<Root: View>: View {
    @Environment(FolderNavigationStore.self) private var folderStore
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    let isActive: Bool
    let isSwitchingTabs: Bool
    let playerViewModel: VideoPlayerViewModel
    @ObservedObject var floatingVideoState: FloatingVideoState
    let root: Root

    @State private var path: [MainView.PhoneVideoRoute] = []
    @State private var isUnwindingVideo = false

    init(
        isActive: Bool,
        isSwitchingTabs: Bool,
        playerViewModel: VideoPlayerViewModel,
        floatingVideoState: FloatingVideoState,
        @ViewBuilder root: () -> Root
    ) {
        self.isActive = isActive
        self.isSwitchingTabs = isSwitchingTabs
        self.playerViewModel = playerViewModel
        self.floatingVideoState = floatingVideoState
        self.root = root()
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: MainView.PhoneVideoRoute.self) { route in
                    switch route {
                    case .video(let videoID):
                        videoDestination(videoID: videoID)
                    }
                }
        }
        .onChange(of: folderStore.selectedVideo?.id) { _, newValue in
            guard isActive,
                  !isUnwindingVideo,
                  !isSwitchingTabs else { return }
            if let videoID = newValue {
                synchronizeVideoRoute(to: videoID)
            } else {
                reconcileDeselectedVideo()
            }
        }
        .onChange(of: path) { oldValue, newValue in
            handlePathChange(from: oldValue, to: newValue)
        }
        .onChange(of: isActive) { _, newValue in
            guard !newValue else { return }
            deactivateVideoRoute()
        }
    }

    @ViewBuilder
    private func videoDestination(videoID: UUID) -> some View {
        if let video = folderStore.video(with: videoID) {
            DetailView(
                video: video,
                playerViewModel: playerViewModel,
                floatingVideoState: floatingVideoState
            )
            .environment(folderStore)
            .environment(libraryManager)
            .environmentObject(transcriptionService)
        } else {
            ContentUnavailableView(
                "Video unavailable",
                systemImage: "video",
                description: Text("The selected video could not be loaded.")
            )
        }
    }

    private func synchronizeVideoRoute(to videoID: UUID) {
        switch PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: path.map(\.videoID),
            selectedVideoID: videoID
        ) {
        case .none:
            return
        case .append:
            path.append(.video(videoID))
        case .replace:
            path = [.video(videoID)]
        }
    }

    private func handlePathChange(
        from oldValue: [MainView.PhoneVideoRoute],
        to newValue: [MainView.PhoneVideoRoute]
    ) {
        guard !isUnwindingVideo else { return }
        let shouldNavigateBack = PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: oldValue.map(\.videoID),
            newVideoRouteIDs: newValue.map(\.videoID),
            selectedVideoID: folderStore.selectedVideo?.id,
            isVideoDetailActive: isActive
        )
        guard shouldNavigateBack else { return }

        isUnwindingVideo = true
        folderStore.navigateBackFromDetail()
        Task { @MainActor in
            await Task.yield()
            isUnwindingVideo = false
        }
    }

    private func deactivateVideoRoute() {
        switch PhoneVideoRouteDeactivationPolicy.action(
            existingVideoRouteIDs: path.map(\.videoID)
        ) {
        case .none:
            return
        case .removeVideoRoutes:
            isUnwindingVideo = true
            path.removeAll()
            Task { @MainActor in
                await Task.yield()
                isUnwindingVideo = false
            }
        }
    }

    private func reconcileDeselectedVideo() {
        let action = PhoneVideoRouteSelectionReconciliationPolicy.action(
            existingVideoRouteIDs: path.map(\.videoID),
            selectedVideoID: folderStore.selectedVideo?.id,
            isSwitchingTabs: isSwitchingTabs
        )
        guard action == .removeVideoRoutes else { return }

        isUnwindingVideo = true
        folderStore.restoreVideoNavigationOriginAfterSelectionCleared()
        path.removeAll()
        Task { @MainActor in
            await Task.yield()
            isUnwindingVideo = false
        }
    }
}
#endif

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
                    .foregroundColor(.red)

                Text("Couldn't Open Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(error.localizedDescription)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                if let recovery = error.recoverySuggestion {
                    Text(recovery)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)

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
