import os
//
//  FolderNavigationStore.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI
import CoreData
import Combine
import Observation


@MainActor
@Observable
class FolderNavigationStore {
    // MARK: - Core State
    var navigationPath = NavigationPath()
    var currentFolderID: UUID? {
        didSet {
            guard oldValue != currentFolderID else { return }
            // Defer to the next main-actor turn to avoid publishing during view updates.
            Task { @MainActor [weak self] in
                self?.refreshContent()
            }
        }
    }
    var selectedSidebarItem: LibrarySidebarDestination? {
        didSet {
            guard selectionKey(oldValue) != selectionKey(selectedSidebarItem) else { return }
            if suppressNextSidebarSelectionChange {
                suppressNextSidebarSelectionChange = false
                return
            }
            // Defer cross-property mutations to avoid publishing while SwiftUI is reconciling selection state.
            Task { @MainActor [weak self] in
                self?.handleSidebarSelectionChange()
            }
        }
    }
    var selectedProject: Folder?
    /// The most recently selected project, kept across grid view recreation so
    /// the projects grid can re-select it when the user navigates back.
    var lastSelectedProjectID: UUID?
    var selectedTopLevelFolder: Folder?
    var selectedVideo: Video?
    var selectedProjectVideoIDs = Set<UUID>()
    var projectSearchQuery = ""
    var pendingSearchSeekRequest: SearchSeekRequest?
    private(set) var projectSelectionAnchorID: UUID?
    
    // Reactive data sources for the UI
    var hierarchicalContent: [HierarchicalContentItem] = []
    var flatContent: [ContentType] = []

    /// Bumped on every content refresh. Views that derive data through store
    /// methods (e.g. `projects()`, `projectSections(for:)`, `videoNeighbors(for:)`)
    /// read this to register an observation dependency — `@Observable` only
    /// invalidates views for tracked property reads, so method-driven results
    /// would otherwise go stale after renames, imports, and deletions.
    var contentRevision = 0

    var currentDestination: LibrarySidebarDestination? {
        selectedSidebarItem
    }

    var isSearchMode: Bool {
        if case .search = currentDestination {
            return true
        }
        return false
    }

    var currentSmartCollection: SmartCollectionKind? {
        if case .smartCollection(let kind) = currentDestination {
            return kind
        }
        return nil
    }

    var currentDetailSurface: LibraryDetailSurface {
        if case .search = currentDestination {
            return .searchResults
        }

        if case .projects = currentDestination {
            if selectedVideo != nil {
                return .videoDetail
            }

            if selectedProject != nil {
                return .projectDetail
            }

            return .projectsGrid
        }

        if let kind = currentSmartCollection {
            return .smartCollectionTable(kind)
        }

        if selectedVideo != nil {
            return .videoDetail
        }

        if selectedProject != nil {
            return .projectDetail
        }

        return .empty
    }

    // MARK: - UI State
    var currentSortOption: SortOption = .foldersFirst {
        didSet {
            guard oldValue != currentSortOption else { return }
            // Defer to the next main-actor turn to avoid "Publishing changes from within view updates".
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flatContent = self.applySorting(self.flatContent)
            }
        }
    }
    var isLoading = false
    var errorMessage: String?
    
    // MARK: - Dependencies
    let libraryManager: LibraryManager
    @ObservationIgnored private var projectSectionCache: [ProjectSectionCacheKey: [ProjectSectionSnapshot]] = [:]
    @ObservationIgnored private var projectSectionCacheRevision = -1
    @ObservationIgnored nonisolated(unsafe) private var libraryObservationTask: Task<Void, Never>?
    var contextSaveCancellable: AnyCancellable?
    private var isRevealingVideoLocation = false
    var suppressNextSidebarSelectionChange = false
    private var videoNavigationOrigin: VideoNavigationOrigin?
    private var hasCapturedVideoNavigationOrigin = false
    private let fallbackProjectSectionTitle = "Videos"
    
    init(libraryManager: LibraryManager) {
        self.libraryManager = libraryManager

        observeLibraryChanges()

        observeContextSaveNotifications()
        
        ensureInitialSelectionIfNeeded()
        refreshContent()
    }
    
    deinit {
        libraryObservationTask?.cancel()
    }

    /// Reloads content whenever the open library changes. The first value is the current library,
    /// which `init` already handles.
    private func observeLibraryChanges() {
        let libraryManager = libraryManager
        libraryObservationTask = Task { [weak self] in
            let libraryIDs = Observations { libraryManager.currentLibrary?.objectID }
            var isInitialValue = true
            for await _ in libraryIDs {
                if isInitialValue {
                    isInitialValue = false
                    continue
                }
                guard let self else { return }
                observeContextSaveNotifications()
                ensureInitialSelectionIfNeeded()
                refreshContent()
            }
        }
    }

    // MARK: - Search Support
    private func handleSidebarSelectionChange() {
        switch selectedSidebarItem {
        case .search:
            // Don't change currentFolderID when in search mode
            // Content will be managed by SearchManager
            if selectedProject != nil {
                selectedProject = nil
            }
            if selectedVideo != nil {
                selectedVideo = nil
            }
            break
        case .projects:
            applyProjectsSelection()
        case .smartCollection:
            applySmartCollectionSelection()
        case .folder(let folder):
            if folder.isProject {
                openProject(folder)
                return
            }
            // When revealing a video's location, revealVideoLocation(_:) sets
            // selectedTopLevelFolder/currentFolderID/navigationPath explicitly.
            // Avoid clobbering that state from this sidebar selection callback.
            if isRevealingVideoLocation {
                return
            }
            // Do not auto-select a video when a normal folder is selected from the sidebar.
            // This avoids unexpectedly opening a nested video's detail view.
            applyFolderSelection(folder, clearSelectedVideo: true)
        case .video(let video):
            if let folder = video.folder {
                applyFolderSelection(folder, clearSelectedVideo: false)
            }
            if selectedVideo?.id != video.id {
                selectedVideo = video
            }
        case .none:
            // Keep current state
            break
        }
    }

    private func applyProjectsSelection() {
        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }
        clearProjectDetailState(clearProject: true)
    }

    private func clearProjectDetailState(
        clearProject: Bool = false,
        clearSelectedVideo: Bool = true,
        clearFolderContext: Bool = true
    ) {
        if clearProject, selectedProject != nil {
            selectedProject = nil
        }

        if clearFolderContext {
            if currentFolderID != nil {
                currentFolderID = nil
            }

            if selectedTopLevelFolder != nil {
                selectedTopLevelFolder = nil
            }
        }

        if clearSelectedVideo, selectedVideo != nil {
            selectedVideo = nil
        }

        if !selectedProjectVideoIDs.isEmpty {
            selectedProjectVideoIDs = []
        }

        if projectSelectionAnchorID != nil {
            projectSelectionAnchorID = nil
        }

        if !projectSearchQuery.isEmpty {
            projectSearchQuery = ""
        }
    }

    private func applySmartCollectionSelection() {
        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }

        if selectedProject != nil {
            selectedProject = nil
        }

        if selectedTopLevelFolder != nil {
            selectedTopLevelFolder = nil
        }

        if currentFolderID != nil {
            currentFolderID = nil
        }

        // Smart collections are virtual destinations, so refresh content directly.
        refreshContent()
    }

    func applyFolderSelection(_ folder: Folder, clearSelectedVideo: Bool) {
        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }

        let topLevelFolder = topLevelAncestor(for: folder)
        if selectedProject?.objectID != topLevelFolder.objectID {
            selectedProject = topLevelFolder
        }
        if selectedTopLevelFolder?.id != topLevelFolder.id {
            selectedTopLevelFolder = topLevelFolder
        }

        if currentFolderID != folder.id {
            currentFolderID = folder.id
        }
        if clearSelectedVideo && selectedVideo != nil {
            selectedVideo = nil
        }
        if !selectedProjectVideoIDs.isEmpty {
            selectedProjectVideoIDs = []
        }
    }

    private func topLevelAncestor(for folder: Folder) -> Folder {
        var top = folder
        while let parent = top.parentFolder {
            top = parent
        }
        return top
    }

    func selectionKey(_ selection: SidebarSelection?) -> String {
        selection?.stableKey ?? "none"
    }
    
    func activateSearch() {
        selectedSidebarItem = .search
    }

    func selectProjects() {
        if selectionKey(selectedSidebarItem) == selectionKey(.projects) {
            applyProjectsSelection()
            return
        }

        selectedSidebarItem = .projects
    }

    func selectAllVideos() {
        selectedSidebarItem = .smartCollection(.allVideos)
    }

    // MARK: - Navigation
    func navigateToFolder(_ folderID: UUID) {
        navigationPath.append(folderID)
        currentFolderID = folderID
    }
    func navigateBack() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        
        if navigationPath.isEmpty {
            currentFolderID = selectedTopLevelFolder?.id
        } else {
            // Complex navigation could decode the path here
        }
    }
    func navigateToRoot() {
        navigationPath = NavigationPath()
        currentFolderID = selectedTopLevelFolder?.id
    }
    
    func selectVideo(_ video: Video) {
        selectedVideo = video
    }

    func videoNeighbors(for video: Video) -> VideoNeighbors {
        let candidates = videoNavigationCandidates(containing: video)
        guard let currentIndex = candidates.firstIndex(where: { $0.objectID == video.objectID }) else {
            return VideoNeighbors(previous: nil, next: nil)
        }

        let previous = currentIndex > 0 ? candidates[currentIndex - 1] : nil
        let next = currentIndex < candidates.index(before: candidates.endIndex) ? candidates[currentIndex + 1] : nil
        return VideoNeighbors(previous: previous, next: next)
    }

    func clearProjectVideoSelection() {
        guard !selectedProjectVideoIDs.isEmpty else { return }
        selectedProjectVideoIDs = []
        projectSelectionAnchorID = nil
    }

    func selectProjectVideo(
        _ video: Video,
        in orderedVideos: [Video],
        extendingSelection: Bool,
        rangeSelecting: Bool
    ) {
        guard let videoID = video.id else { return }

        if rangeSelecting,
           let anchorID = projectSelectionAnchorID ?? selectedProjectVideoIDs.first,
           let anchorIndex = orderedVideos.firstIndex(where: { $0.id == anchorID }),
           let selectedIndex = orderedVideos.firstIndex(where: { $0.id == videoID }) {
            let lowerBound = min(anchorIndex, selectedIndex)
            let upperBound = max(anchorIndex, selectedIndex)
            selectedProjectVideoIDs = Set(orderedVideos[lowerBound...upperBound].compactMap(\.id))
            return
        }

        if extendingSelection {
            if selectedProjectVideoIDs.contains(videoID) {
                selectedProjectVideoIDs.remove(videoID)
            } else {
                selectedProjectVideoIDs.insert(videoID)
            }
            projectSelectionAnchorID = videoID
            return
        }

        selectedProjectVideoIDs = [videoID]
        projectSelectionAnchorID = videoID
    }

    func project(with id: UUID) -> Folder? {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return nil }
        let request = Folder.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(
            format: "library == %@ AND id == %@ AND isTopLevel == YES AND isSmartFolder == NO",
            library,
            id as CVarArg
        )
        return try? context.fetch(request).first
    }

    func video(with id: UUID) -> Video? {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return nil }
        let request = Video.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, id as CVarArg)
        return try? context.fetch(request).first
    }

    private struct ProjectSectionCacheKey: Hashable {
        let projectID: NSManagedObjectID
        let query: String?
    }

    /// Sections for a project, memoised until the library content next changes. Views call this
    /// from body, and walking and sorting a project's videos is too much to repeat per render.
    func projectSections(for project: Folder, matching query: String? = nil) -> [ProjectSectionSnapshot] {
        let trimmedQuery = (query ?? projectSearchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.isEmpty ? nil : trimmedQuery.localizedLowercase

        let revision = contentRevision
        if projectSectionCacheRevision != revision {
            projectSectionCache.removeAll()
            projectSectionCacheRevision = revision
        }

        let key = ProjectSectionCacheKey(projectID: project.objectID, query: normalizedQuery)
        if let cached = projectSectionCache[key] {
            return cached
        }

        let sections = buildProjectSections(for: project, normalizedQuery: normalizedQuery)
        projectSectionCache[key] = sections
        return sections
    }

    private func buildProjectSections(for project: Folder, normalizedQuery: String?) -> [ProjectSectionSnapshot] {
        var sections: [ProjectSectionSnapshot] = []

        for section in project.sectionsArray {
            let videos = descendantVideos(in: section)
                .filter { matchesProjectQuery($0, query: normalizedQuery) }

            guard !videos.isEmpty else { continue }

            sections.append(
                ProjectSectionSnapshot(
                    id: section.id?.uuidString ?? section.objectID.uriRepresentation().absoluteString,
                    title: resolvedFolderName(section, fallback: "Untitled Section"),
                    videos: videos,
                    sourceFolder: section
                )
            )
        }

        let directVideos = project.videosArray.filter { matchesProjectQuery($0, query: normalizedQuery) }
        if !directVideos.isEmpty {
            sections.append(
                ProjectSectionSnapshot(
                    id: "project-root-\(project.id?.uuidString ?? project.objectID.uriRepresentation().absoluteString)",
                    title: fallbackProjectSectionTitle,
                    videos: directVideos,
                    sourceFolder: nil
                )
            )
        }

        return sections
    }

    func projectVideos(in project: Folder, matching query: String? = nil) -> [Video] {
        projectSections(for: project, matching: query).flatMap(\.videos)
    }

    func totalDuration(for project: Folder, matching query: String? = nil) -> TimeInterval {
        projectVideos(in: project, matching: query).reduce(0) { $0 + $1.duration }
    }

    func continueWatchingVideo(in project: Folder) -> Video? {
        let videos = projectVideos(in: project)
        let inProgress = videos.filter { $0.watchStatus == .inProgress }

        if let mostRecentInProgress = inProgress.sorted(by: continueWatchingSortOrder).first {
            return mostRecentInProgress
        }

        return videos.first
    }

    func openProjectVideo(_ video: Video, in project: Folder? = nil) {
        if let project {
            captureVideoNavigationOrigin(.project(project))
        } else if let folder = video.folder {
            let topLevelFolder = topLevelAncestor(for: folder)
            if topLevelFolder.isProject {
                captureVideoNavigationOrigin(.project(topLevelFolder))
            }
        }

        // Publish the video route before opening its project. This prevents the
        // detail column from briefly reconciling back to the project surface.
        selectedVideo = video

        if let project {
            openProject(project, preservingVideoDetail: true)
        } else if let folder = video.folder {
            let topLevelFolder = topLevelAncestor(for: folder)
            if topLevelFolder.isProject {
                openProject(topLevelFolder, preservingVideoDetail: true)
            }
        }

        if let videoID = video.id {
            selectedProjectVideoIDs = [videoID]
            projectSelectionAnchorID = videoID
        } else {
            selectedProjectVideoIDs = []
            projectSelectionAnchorID = nil
        }
    }

    func downloadAllVideos(in project: Folder) {
        let videos = projectVideos(in: project)
        guard !videos.isEmpty else { return }
        ProcessingQueueManager.shared.enqueueEnsureLocalAvailability(for: videos)
    }

    func openFromSearchCitation(_ video: Video, seekTo seconds: TimeInterval?, source: SearchMatchSource?) {
        captureVideoNavigationOrigin(.sidebar(.search))
        if video.folder != nil {
            revealVideoLocation(video)
        } else {
            openVideoDetailWithoutLocation(video)
        }

        if let videoID = video.id {
            pendingSearchSeekRequest = SearchSeekRequest(videoID: videoID, seconds: seconds, source: source)
        }
    }

    func consumePendingSearchSeekRequest(for videoID: UUID) -> SearchSeekRequest? {
        guard let pendingSearchSeekRequest,
              pendingSearchSeekRequest.videoID == videoID else {
            return nil
        }
        self.pendingSearchSeekRequest = nil
        return pendingSearchSeekRequest
    }

    func openVideoDetailWithoutLocation(_ video: Video) {
        captureVideoNavigationOrigin()
        selectedVideo = video

        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }

        if let topLevelFolder = video.folder.map(topLevelAncestor(for:)) {
            selectedProject = topLevelFolder
            selectedTopLevelFolder = topLevelFolder
        } else {
            if selectedProject != nil {
                selectedProject = nil
            }
            if selectedTopLevelFolder != nil {
                selectedTopLevelFolder = nil
            }
        }

        if currentFolderID != nil {
            currentFolderID = nil
        }

        if let videoID = video.id {
            selectedProjectVideoIDs = [videoID]
            projectSelectionAnchorID = videoID
        } else {
            selectedProjectVideoIDs = []
            projectSelectionAnchorID = nil
        }

        if selectedSidebarItem != nil {
            selectedSidebarItem = nil
        }
    }

    func openProject(_ project: Folder, preservingVideoDetail: Bool = false) {
        guard project.isProject else { return }

        let isReopeningSelectedProject = selectedProject?.objectID == project.objectID
        let selectedVideoBelongsToProject = selectedVideo
            .flatMap(\.folder)
            .map { topLevelAncestor(for: $0).objectID == project.objectID }
            ?? false
        let shouldPreserveVideoDetail = preservingVideoDetail
            || (isReopeningSelectedProject && selectedVideoBelongsToProject)

        if selectionKey(selectedSidebarItem) != selectionKey(.projects) {
            suppressNextSidebarSelectionChange = true
            selectedSidebarItem = .projects
        }

        if selectedProject?.objectID != project.objectID {
            selectedProject = project
        }
        lastSelectedProjectID = project.id

        if selectedTopLevelFolder?.objectID != project.objectID {
            selectedTopLevelFolder = project
        }

        if currentFolderID != project.id {
            currentFolderID = project.id
        }

        clearProjectDetailState(
            clearSelectedVideo: !shouldPreserveVideoDetail,
            clearFolderContext: false
        )

        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }
    }

    func selectVideo(by id: UUID) {
        guard let context = libraryManager.viewContext else { return }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let matchedVideo = try? context.fetch(request).first {
            selectedVideo = matchedVideo
        }
    }

    // Reveal a video's location in the folder hierarchy and select it.
    func revealVideoLocation(_ video: Video) {
        captureVideoNavigationOrigin()
        isRevealingVideoLocation = true
        defer { isRevealingVideoLocation = false }

        selectedVideo = video
        guard let folder = video.folder else {
            // No folder path to reveal; clear virtual routes so detail can open.
            if !navigationPath.isEmpty {
                navigationPath = NavigationPath()
            }
            if selectedTopLevelFolder != nil {
                selectedTopLevelFolder = nil
            }
            if currentFolderID != nil {
                currentFolderID = nil
            }
            if selectedSidebarItem != nil {
                selectedSidebarItem = nil
            }
            return
        }

        let top = topLevelAncestor(for: folder)

        // We set folder/navigation state directly below; suppress the deferred sidebar callback
        // so selectedVideo is not cleared as part of normal folder selection behavior.
        let targetSidebarSelection: SidebarSelection = .video(video)
        if selectionKey(selectedSidebarItem) != selectionKey(targetSidebarSelection) {
            suppressNextSidebarSelectionChange = true
        }
        selectedSidebarItem = targetSidebarSelection
        selectedProject = top
        selectedTopLevelFolder = top
        currentFolderID = folder.id
        if let videoID = video.id {
            selectedProjectVideoIDs = [videoID]
            projectSelectionAnchorID = videoID
        } else {
            selectedProjectVideoIDs = []
            projectSelectionAnchorID = nil
        }

        // Outline mode represents hierarchy in-column, so we don't use stack-like back path here.
        navigationPath = NavigationPath()
    }

    private func descendantVideos(in folder: Folder) -> [Video] {
        var videos = folder.videosArray
        for child in folder.childFoldersArray {
            videos.append(contentsOf: descendantVideos(in: child))
        }
        return videos.sorted(by: projectDisplaySortOrder)
    }

    private func videoNavigationCandidates(containing video: Video) -> [Video] {
        let folderCandidates = flatContent.compactMap {
            if case .video(let candidate) = $0 { return candidate }
            return nil
        }

        if folderCandidates.contains(where: { $0.objectID == video.objectID }) {
            return folderCandidates
        }

        if let selectedProject {
            let projectCandidates = projectVideos(in: selectedProject)
            if projectCandidates.contains(where: { $0.objectID == video.objectID }) {
                return projectCandidates
            }
        }

        return []
    }

    private func continueWatchingSortOrder(_ lhs: Video, _ rhs: Video) -> Bool {
        let lhsLastPlayed = lhs.lastPlayed ?? .distantPast
        let rhsLastPlayed = rhs.lastPlayed ?? .distantPast
        if lhsLastPlayed != rhsLastPlayed {
            return lhsLastPlayed > rhsLastPlayed
        }

        return projectDisplaySortOrder(lhs, rhs)
    }

    private func projectDisplaySortOrder(_ lhs: Video, _ rhs: Video) -> Bool {
        let lhsFileName = projectSortFileName(for: lhs)
        let rhsFileName = projectSortFileName(for: rhs)
        let naturalComparison = lhsFileName.localizedStandardCompare(rhsFileName)
        if naturalComparison != .orderedSame {
            return naturalComparison == .orderedAscending
        }

        return resolvedVideoTitle(lhs).localizedCaseInsensitiveCompare(resolvedVideoTitle(rhs)) == .orderedAscending
    }

    private func projectSortFileName(for video: Video) -> String {
        let trimmedFileName = video.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFileName.isEmpty {
            return trimmedFileName
        }

        return resolvedVideoTitle(video)
    }

    var showsProjectBackButton: Bool {
        currentDetailSurface == .projectDetail && currentDestination == .projects && selectedProject != nil
    }

    var showsVideoBackButton: Bool {
        currentDetailSurface == .videoDetail
    }

    func abandonVideoDetail() {
        videoNavigationOrigin = nil
        hasCapturedVideoNavigationOrigin = false
        clearVideoDetailRouteState()
        if selectedVideo != nil {
            selectedVideo = nil
        }
    }

    func restoreVideoNavigationOriginAfterSelectionCleared() {
        guard selectedVideo == nil,
              hasCapturedVideoNavigationOrigin else { return }

        let origin = videoNavigationOrigin
        videoNavigationOrigin = nil
        hasCapturedVideoNavigationOrigin = false
        clearVideoDetailRouteState()
        restoreVideoNavigationOrigin(origin)
    }

    private func clearVideoDetailRouteState() {
        if pendingSearchSeekRequest != nil {
            pendingSearchSeekRequest = nil
        }
        if !selectedProjectVideoIDs.isEmpty {
            selectedProjectVideoIDs = []
        }
        if projectSelectionAnchorID != nil {
            projectSelectionAnchorID = nil
        }
    }

    func navigateBackFromDetail() {
        if selectedVideo != nil {
            let origin = videoNavigationOrigin
            videoNavigationOrigin = nil
            hasCapturedVideoNavigationOrigin = false
            selectedVideo = nil
            clearVideoDetailRouteState()
            restoreVideoNavigationOrigin(origin)
            return
        }

        guard currentDestination == .projects, selectedProject != nil else { return }

        if selectionKey(selectedSidebarItem) != selectionKey(.projects) {
            suppressNextSidebarSelectionChange = true
            selectedSidebarItem = .projects
        }

        clearProjectDetailState(clearProject: true)
    }

    private func captureVideoNavigationOrigin(_ preferredOrigin: VideoNavigationOrigin? = nil) {
        guard selectedVideo == nil else { return }
        hasCapturedVideoNavigationOrigin = true

        if let preferredOrigin {
            videoNavigationOrigin = preferredOrigin
            return
        }

        switch currentDestination {
        case .projects:
            if let selectedProject {
                videoNavigationOrigin = .project(selectedProject)
            } else {
                videoNavigationOrigin = .sidebar(.projects)
            }
        case .search:
            videoNavigationOrigin = .sidebar(.search)
        case .smartCollection(let kind):
            videoNavigationOrigin = .sidebar(.smartCollection(kind))
        case .folder(let folder):
            videoNavigationOrigin = .sidebar(.folder(folder))
        case .video, .none:
            videoNavigationOrigin = nil
        }
    }

    private func restoreVideoNavigationOrigin(_ origin: VideoNavigationOrigin?) {
        switch origin {
        case .project(let project):
            openProject(project)
        case .sidebar(let destination):
            restoreSidebarDestination(destination)
        case .none:
            restoreSidebarDestination(.projects)
        }
    }

    private func restoreSidebarDestination(_ destination: LibrarySidebarDestination) {
        if selectionKey(selectedSidebarItem) != selectionKey(destination) {
            suppressNextSidebarSelectionChange = true
            selectedSidebarItem = destination
        }

        switch destination {
        case .search:
            clearProjectDetailState(clearProject: true)
        case .projects:
            applyProjectsSelection()
        case .smartCollection:
            applySmartCollectionSelection()
        case .folder(let folder):
            applyFolderSelection(folder, clearSelectedVideo: true)
        case .video:
            restoreSidebarDestination(.projects)
        }
    }

    private func matchesProjectQuery(_ video: Video, query: String?) -> Bool {
        guard let query, !query.isEmpty else { return true }
        let title = resolvedVideoTitle(video).localizedLowercase
        if title.contains(query) {
            return true
        }
        let fileName = (video.fileName ?? "").localizedLowercase
        return fileName.contains(query)
    }

    private func resolvedVideoTitle(_ video: Video) -> String {
        let trimmedTitle = video.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let trimmedFileName = video.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedFileName.isEmpty ? "Untitled Video" : trimmedFileName
    }

    private func resolvedFolderName(_ folder: Folder, fallback: String) -> String {
        let trimmedName = folder.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? fallback : trimmedName
    }

}
