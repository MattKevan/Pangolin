//
//  PhoneRootView.swift
//  Pangolin
//

#if os(iOS)
import SwiftUI

/// The iPhone's navigation: one stack, rooted at whichever Library destination is chosen, with
/// projects and videos pushed on top. Mac and iPad use a split view instead.
struct PhoneRootView<Widget: View>: View {
    @Environment(FolderNavigationStore.self) private var folderStore
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
    @Environment(LibraryActions.self) private var libraryActions: LibraryActions

    let searchManager: SearchManager
    let transcriptionService: SpeechTranscriptionService
    let playerViewModel: VideoPlayerViewModel
    let floatingVideoState: FloatingVideoState
    @ViewBuilder let activityWidget: () -> Widget

    @State private var destination: PhoneLibraryDestination = .projects
    @State private var path: [PhoneProjectsRoute] = []
    @State private var isLibraryExpanded = false
    @State private var isUnwindingVideo = false
    @State private var isSwitchingDestination = false
    @FocusState private var isSearchFocused: Bool

    private var isSearching: Bool {
        PhoneLibraryPolicy.isSearching(isFieldFocused: isSearchFocused, query: searchManager.searchText)
    }

    var body: some View {
        @Bindable var searchManager = searchManager

        NavigationStack(path: $path) {
            rootContent
                .toolbar { rootToolbar }
                .navigationDestination(for: PhoneProjectsRoute.self) { route in
                    routeContent(route)
                }
        }
        .safeAreaInset(edge: .bottom) {
            if PhoneLibraryPolicy.showsLibraryBar(path: path) {
                PhoneLibraryToolbar(
                    destination: $destination,
                    isExpanded: $isLibraryExpanded,
                    searchText: $searchManager.searchText,
                    isSearchFocused: $isSearchFocused,
                    actions: libraryActions
                )
                .transition(.opacity)
            }
        }
        .onAppear { syncStore() }
        .onChange(of: destination) { _, _ in switchDestination() }
        .onChange(of: isSearching) { _, _ in switchDestination() }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { isLibraryExpanded = false }
        }
        .onChange(of: folderStore.selectedVideo?.id) { _, newValue in
            guard !isUnwindingVideo, !isSwitchingDestination else { return }
            if let videoID = newValue {
                synchronizeVideoRoute(to: videoID)
            } else {
                reconcileDeselectedVideo()
            }
        }
        .onChange(of: path) { oldValue, newValue in
            handlePathChange(from: oldValue, to: newValue)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var rootContent: some View {
        if isSearching {
            SearchResultsView()
                .environment(searchManager)
                .environment(folderStore)
                .environment(libraryManager)
                .navigationTitle("Search")
        } else if destination == .projects {
            ProjectsListView(onOpen: openProject)
                .environment(folderStore)
                .environment(libraryManager)
        } else {
            FolderContentView()
                .environment(folderStore)
                .environment(libraryManager)
                .navigationTitle(destination.title)
        }
    }

    @ToolbarContentBuilder
    private var rootToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            activityWidget()

            if destination == .projects, !isSearching {
                Button("New project", systemImage: "plus") {
                    NotificationCenter.default.post(name: .triggerCreateFolder, object: nil)
                }
                .disabled(libraryManager.currentLibrary == nil)
            }
        }
    }

    @ViewBuilder
    private func routeContent(_ route: PhoneProjectsRoute) -> some View {
        switch route {
        case .project(let projectID):
            if let project = folderStore.project(with: projectID) {
                ProjectDetailView(project: project, showsPhoneToolbar: true)
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
                .environment(transcriptionService)
            } else {
                ContentUnavailableView(
                    "Video unavailable",
                    systemImage: "video",
                    description: Text("The selected video could not be loaded.")
                )
            }
        }
    }

    // MARK: - Navigation

    private func openProject(_ project: Folder) {
        folderStore.openProject(project)
        guard let projectID = project.id else { return }
        if path.last != .project(projectID) {
            path.append(.project(projectID))
        }
    }

    private func syncStore() {
        if isSearching {
            folderStore.activateSearch()
        } else if destination == .projects {
            folderStore.selectProjects()
        } else {
            folderStore.selectedSidebarItem = destination.storeDestination
        }
    }

    /// Changing destination, or starting to search, abandons whatever was open instead of
    /// navigating Back into it.
    private func switchDestination() {
        isSwitchingDestination = true
        isUnwindingVideo = true
        folderStore.abandonVideoDetail()
        path.removeAll()
        syncStore()
        Task { @MainActor in
            await Task.yield()
            isUnwindingVideo = false
            isSwitchingDestination = false
        }
    }

    private func synchronizeVideoRoute(to videoID: UUID) {
        switch PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: path.compactMap(\.videoID),
            selectedVideoID: videoID
        ) {
        case .none:
            return
        case .append:
            path.append(.video(videoID))
        case .replace:
            path = PhoneProjectsPathPolicy.removingVideoRoutes(from: path) + [.video(videoID)]
        }
    }

    private func handlePathChange(from oldValue: [PhoneProjectsRoute], to newValue: [PhoneProjectsRoute]) {
        guard !isUnwindingVideo else { return }
        let shouldNavigateBack = PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: oldValue.compactMap(\.videoID),
            newVideoRouteIDs: newValue.compactMap(\.videoID),
            selectedVideoID: folderStore.selectedVideo?.id,
            isVideoDetailActive: true
        )
        guard shouldNavigateBack else { return }

        isUnwindingVideo = true
        folderStore.navigateBackFromDetail()
        Task { @MainActor in
            await Task.yield()
            isUnwindingVideo = false
        }
    }

    private func reconcileDeselectedVideo() {
        let action = PhoneVideoRouteSelectionReconciliationPolicy.action(
            existingVideoRouteIDs: path.compactMap(\.videoID),
            selectedVideoID: folderStore.selectedVideo?.id,
            isSwitchingTabs: isSwitchingDestination
        )
        guard action == .removeVideoRoutes else { return }

        isUnwindingVideo = true
        folderStore.restoreVideoNavigationOriginAfterSelectionCleared()
        path = PhoneProjectsPathPolicy.removingVideoRoutes(from: path)
        Task { @MainActor in
            await Task.yield()
            isUnwindingVideo = false
        }
    }
}
#endif
