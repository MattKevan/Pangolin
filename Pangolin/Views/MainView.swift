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

    private enum PhoneProjectsRoute: Hashable {
        case project(UUID)
        case video(UUID)
    }
    #endif

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var videoFileManager: VideoFileManager
    @StateObject private var folderStore: FolderNavigationStore
    @StateObject private var searchManager = SearchManager()
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
    let isStartingUp: Bool
    let startupError: LibraryError?
    let startupLoadingProgress: Double
    let retryAction: () -> Void
    let resetAction: () -> Void
    
    @State private var showingImportPicker = false
    @State private var showingURLImportSheet = false
    
    // Popover state for task indicator
    @State private var showTaskPopover = false
    @State private var isSearchFieldPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    #if os(iOS)
    @State private var phoneSelectedTab: PhoneTab = .projects
    @State private var phoneProjectsPath: [PhoneProjectsRoute] = []
    #endif
    
    init(
        libraryManager: LibraryManager,
        isStartingUp: Bool = false,
        startupError: LibraryError? = nil,
        startupLoadingProgress: Double = 0,
        retryAction: @escaping () -> Void = {},
        resetAction: @escaping () -> Void = {}
    ) {
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
        self.isStartingUp = isStartingUp
        self.startupError = startupError
        self.startupLoadingProgress = startupLoadingProgress
        self.retryAction = retryAction
        self.resetAction = resetAction
    }
    
    var body: some View { rootView }

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

    private var rootNavigationSplitView: some View {
        NavigationSplitView {
            sidebarColumn
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarColumn: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
            .environmentObject(folderStore)
            .environmentObject(libraryManager)
            .environmentObject(searchManager)
            .applyManagedObjectContext(libraryManager.viewContext)
    }

    private var detailColumn: some View {
        configuredDetailColumn
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
            let baseDetailColumn = DetailColumnView()
                .environmentObject(folderStore)
                .environmentObject(searchManager)
                .environmentObject(libraryManager)
                .environmentObject(transcriptionService)
                .navigationSplitViewColumnWidth(min: 420, ideal: 760)
                .toolbar {
                if !folderStore.isSearchMode {
                    // Normal Mode: Standard toolbar items
                    ToolbarItemGroup(placement: .navigation) {
                        if folderStore.showsProjectBackButton || folderStore.showsVideoBackButton {
                            Button {
                                folderStore.navigateBackFromDetail()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .help("Back")
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

                    // Trailing actions
                    ToolbarItemGroup(placement: .primaryAction) {
                        // Task Queue Progress Indicator
                        if processingQueueManager.visibleActiveTaskCount > 0 || processingQueueManager.failedTasks > 0 || videoFileManager.failedTransferCount > 0 {
                            Button {
                                showTaskPopover.toggle()
                            } label: {
                                let hasActiveTasks = processingQueueManager.visibleActiveTaskCount > 0
                                let failedProcessingCount = processingQueueManager.failedTasks
                                let transferIssueCount = videoFileManager.failedTransferCount
                                let nonActiveIssueCount = transferIssueCount + failedProcessingCount
                                let badgeCount = nonActiveIssueCount > 0 ? nonActiveIssueCount : max(0, processingQueueManager.visibleActiveTaskCount - 1)

                                ZStack(alignment: .topTrailing) {
                                    if hasActiveTasks {
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
                                .accessibilityValue("\(processingQueueManager.visibleActiveTaskCount) active tasks, \(processingQueueManager.failedTasks) failed tasks, \(videoFileManager.failedTransferCount) transfer issues")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                                ProcessingPopoverView(processingManager: processingQueueManager)
                            }
                        }
                    }
                }
            }
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
                    .environmentObject(folderStore)
                    .navigationDestination(for: PhoneProjectsRoute.self) { route in
                        switch route {
                        case .project(let projectID):
                            if let project = folderStore.project(with: projectID) {
                                ProjectDetailView(
                                    project: project,
                                    showsPhoneToolbar: true,
                                    opensVideoOnSingleTap: true
                                )
                                .environmentObject(folderStore)
                            } else {
                                ContentUnavailableView(
                                    "Project unavailable",
                                    systemImage: "square.grid.2x2",
                                    description: Text("The selected project could not be loaded.")
                                )
                            }
                        case .video(let videoID):
                            if let video = folderStore.video(with: videoID) {
                                DetailView(video: video)
                                    .environmentObject(folderStore)
                                    .environmentObject(libraryManager)
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
                              let videoID = newValue,
                              !phoneProjectsPath.contains(.video(videoID)),
                              folderStore.selectedProject != nil else { return }
                        phoneProjectsPath.append(.video(videoID))
                    }
                }
            }

            Tab("All videos", systemImage: "list.bullet", value: .allVideos) {
                NavigationStack {
                    PhoneCollectionTabView(
                        title: "All videos",
                        onAppear: { folderStore.selectedSidebarItem = .smartCollection(.allVideos) }
                    )
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
                }
            }

            Tab("Favourites", systemImage: "heart", value: .favourites) {
                NavigationStack {
                    PhoneCollectionTabView(
                        title: "Favourites",
                        onAppear: { folderStore.selectedSidebarItem = .smartCollection(.favorites) }
                    )
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                NavigationStack {
                    SearchResultsView()
                        .environmentObject(searchManager)
                        .environmentObject(folderStore)
                        .environmentObject(libraryManager)
                        .navigationTitle("Search")
                }
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
            syncPhoneTabSelection()
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
            print("Error importing files: \(error)")
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
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
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
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleAutoTranscribe: () -> Void

    func body(content: Content) -> some View {
        let configuredContent = content
            .navigationTitle(folderStore.isSearchMode ? "" : (folderStore.selectedVideo?.title ?? libraryManager.currentLibrary?.name ?? "Pangolin"))
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
}

private struct RootAlertModifier: ViewModifier {
    @ObservedObject var libraryManager: LibraryManager

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
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    var body: some View {
        Group {
            switch folderStore.currentDetailSurface {
            case .searchResults:
                SearchResultsView()
                    .environmentObject(searchManager)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            case .projectsGrid:
                ProjectsGridView()
                    .environmentObject(folderStore)
            case .projectDetail:
                if let selectedProject = folderStore.selectedProject {
                    ProjectDetailView(project: selectedProject)
                        .environmentObject(folderStore)
                } else {
                    ContentUnavailableView(
                        "No project selected",
                        systemImage: "square.grid.2x2",
                        description: Text("Choose a project from the grid.")
                    )
                }
            case .smartCollectionTable(_):
                FolderContentView()
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            case .videoDetail:
                if let selectedVideo = folderStore.selectedVideo {
                    DetailView(video: selectedVideo)
                        .environmentObject(folderStore)
                        .environmentObject(libraryManager)
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
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    let title: String
    let onAppear: () -> Void

    var body: some View {
        Group {
            if let selectedVideo = folderStore.selectedVideo,
               folderStore.currentDetailSurface == .videoDetail {
                DetailView(video: selectedVideo)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
            } else {
                FolderContentView()
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            }
        }
        .navigationTitle(title)
        .onAppear(perform: onAppear)
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
