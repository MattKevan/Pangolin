//
//  FolderNavigationStore.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI
import CoreData
import Combine

// MARK: - Sidebar Routing Types
enum LibrarySidebarDestination: Hashable, Identifiable {
    case search
    case projects
    case smartCollection(SmartCollectionKind)
    case folder(Folder)
    case video(Video)

    var id: String { stableKey }

    var stableKey: String {
        switch self {
        case .search:
            return "search"
        case .projects:
            return "projects"
        case .smartCollection(let kind):
            return "smart:\(kind.rawValue)"
        case .folder(let folder):
            if let id = folder.id?.uuidString {
                return "folder:\(id)"
            }
            return "folderObject:\(folder.objectID.uriRepresentation().absoluteString)"
        case .video(let video):
            if let id = video.id?.uuidString {
                return "video:\(id)"
            }
            return "videoObject:\(video.objectID.uriRepresentation().absoluteString)"
        }
    }

    static func == (lhs: LibrarySidebarDestination, rhs: LibrarySidebarDestination) -> Bool {
        lhs.stableKey == rhs.stableKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(stableKey)
    }
}

typealias SidebarSelection = LibrarySidebarDestination

enum LibraryDetailSurface: Equatable {
    case searchResults
    case projectsGrid
    case projectDetail
    case smartCollectionTable(SmartCollectionKind)
    case videoDetail
    case empty
}

enum FolderDeletionMode {
    case keepVideosInLibrary
    case deleteAllVideos
}

struct ProjectSectionSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let videos: [Video]
    let sourceFolder: Folder?

    static func == (lhs: ProjectSectionSnapshot, rhs: ProjectSectionSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class FolderNavigationStore: ObservableObject {
    // MARK: - Core State
    @Published var navigationPath = NavigationPath()
    @Published var currentFolderID: UUID?
    @Published var selectedSidebarItem: LibrarySidebarDestination? {
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
    @Published var selectedProject: Folder?
    @Published var selectedTopLevelFolder: Folder?
    @Published var selectedVideo: Video?
    @Published var selectedProjectVideoIDs = Set<UUID>()
    @Published var projectSearchQuery = ""
    @Published var pendingSearchSeekRequest: SearchSeekRequest?
    @Published private(set) var projectSelectionAnchorID: UUID?
    
    // Reactive data sources for the UI
    @Published var hierarchicalContent: [HierarchicalContentItem] = []
    @Published var flatContent: [ContentType] = []

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
    @Published var currentSortOption: SortOption = .foldersFirst {
        didSet {
            guard oldValue != currentSortOption else { return }
            // Defer to the next main-actor turn to avoid "Publishing changes from within view updates".
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flatContent = self.applySorting(self.flatContent)
            }
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Dependencies
    private let libraryManager: LibraryManager
    private var cancellables = Set<AnyCancellable>()
    private var contextSaveCancellable: AnyCancellable?
    private var isRevealingVideoLocation = false
    private var suppressNextSidebarSelectionChange = false
    private let fallbackProjectSectionTitle = "Videos"
    
    init(libraryManager: LibraryManager) {
        self.libraryManager = libraryManager

        libraryManager.$currentLibrary
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observeContextSaveNotifications()
                self.ensureInitialSelectionIfNeeded()
                self.refreshContent()
            }
            .store(in: &cancellables)

        observeContextSaveNotifications()
        
        // Subscribe to internal navigation changes to refresh content
        $currentFolderID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("🧠 STORE: Current folder changed, refreshing content.")
                self?.refreshContent()
            }
            .store(in: &cancellables)
        
        ensureInitialSelectionIfNeeded()
        refreshContent()
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

    private func clearProjectDetailState(clearProject: Bool = false) {
        if clearProject, selectedProject != nil {
            selectedProject = nil
        }

        if currentFolderID != nil {
            currentFolderID = nil
        }

        if selectedTopLevelFolder != nil {
            selectedTopLevelFolder = nil
        }

        if selectedVideo != nil {
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

    private func applyFolderSelection(_ folder: Folder, clearSelectedVideo: Bool) {
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

    private func selectionKey(_ selection: SidebarSelection?) -> String {
        selection?.stableKey ?? "none"
    }
    
    func activateSearch() {
        selectedSidebarItem = .search
    }

    func selectProjects() {
        selectedSidebarItem = .projects
    }

    func selectAllVideos() {
        selectedSidebarItem = .smartCollection(.allVideos)
    }
    
    // MARK: - Content Fetching
    private func refreshContent() {
        if currentDestination == nil && currentFolderID == nil {
            ensureInitialSelectionIfNeeded()
        }

        if case .search = currentDestination {
            // Search results are driven by SearchManager; keep existing folder content state intact.
            return
        }

        if case .projects = currentDestination {
            self.hierarchicalContent = []
            self.flatContent = []
            return
        }

        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            self.hierarchicalContent = []
            self.flatContent = []
            return
        }
        
        // 🔍 SELECTION PRESERVATION: Capture current selection before refresh
        let preservedSelectionID = selectedVideo?.id
        print("🔄 STORE: Refreshing content, preserving selection: \(preservedSelectionID?.uuidString ?? "none")")
        
        var newHierarchicalContent: [HierarchicalContentItem] = []
        var newFlatContent: [ContentType] = []
        var smartCollectionVideos: [Video]?
        
        do {
            if let smartCollection = currentSmartCollection {
                let videos = try LibraryContentProvider.loadSmartCollection(smartCollection, library: library, context: context)
                smartCollectionVideos = videos
                newFlatContent = videos.map { .video($0) }
                newHierarchicalContent = videos.map(HierarchicalContentItem.init(video:))
            } else if let folderID = currentFolderID {
                let snapshot = try LibraryContentProvider.loadFolderContent(folderID: folderID, library: library, context: context)
                newHierarchicalContent = snapshot.hierarchical
                newFlatContent = snapshot.flat
            }
        } catch {
            errorMessage = "Failed to load content: \(error.localizedDescription)"
        }
        
        // Populate the publishers
        self.hierarchicalContent = newHierarchicalContent
        self.flatContent = applySorting(newFlatContent)
        
        // 🔍 SELECTION PRESERVATION: Restore selection if it still exists in content
        if let smartCollectionVideos {
            if let preservedID = preservedSelectionID,
               let matchedVideo = smartCollectionVideos.first(where: { $0.id == preservedID }) {
                if let currentSelectedVideo = selectedVideo {
                    if currentSelectedVideo !== matchedVideo {
                        selectedVideo = matchedVideo
                    }
                } else {
                    selectedVideo = matchedVideo
                }
                print("✅ STORE: Preserved smart-collection selection \(preservedID.uuidString)")
            } else if selectedVideo != nil {
                print("❌ STORE: Clearing selection not present in smart collection")
                selectedVideo = nil
            }
        } else if let preservedID = preservedSelectionID {
            let stillExists = containsVideo(withID: preservedID, in: newHierarchicalContent)
            
            if stillExists {
                print("✅ STORE: Preserved selection \(preservedID.uuidString) still exists, keeping it")
                // Keep the current selectedVideo - don't change it
                return
            } else {
                print("❌ STORE: Preserved selection \(preservedID.uuidString) no longer exists")
                selectedVideo = nil
            }
        }
        
        // Only select first video if we have no current selection
        if selectedVideo == nil {
            print("🎯 STORE: No selection, leaving empty")
        } else {
            print("🎯 STORE: Keeping existing selection: \(selectedVideo?.title ?? "unknown")")
        }
    }

    private func containsVideo(withID videoID: UUID, in items: [HierarchicalContentItem]) -> Bool {
        for item in items {
            if case .video(let video) = item.contentType, video.id == videoID {
                return true
            }

            if let children = item.children,
               containsVideo(withID: videoID, in: children) {
                return true
            }
        }

        return false
    }

    private func observeContextSaveNotifications() {
        contextSaveCancellable?.cancel()

        guard let context = libraryManager.viewContext else {
            contextSaveCancellable = nil
            return
        }

        contextSaveCancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave, object: context)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                print("🧠 STORE: Context saved, refreshing content.")

                if let stack = self?.libraryManager.currentCoreDataStack {
                    stack.refreshViewContextIfNeeded()
                }

                self?.refreshContent()
            }
    }

    private func ensureInitialSelectionIfNeeded() {
        guard selectedSidebarItem == nil,
              selectedProject == nil,
              selectedTopLevelFolder == nil,
              currentFolderID == nil,
              !isSearchMode,
              libraryManager.currentLibrary != nil else {
            return
        }

        selectedSidebarItem = .projects
    }

    private func applySidebarFolderSelectionWithoutCallback(_ folder: Folder, clearSelectedVideo: Bool) {
        let targetSelection: SidebarSelection = .folder(folder)
        if selectionKey(selectedSidebarItem) != selectionKey(targetSelection) {
            suppressNextSidebarSelectionChange = true
        }
        selectedSidebarItem = targetSelection
        applyFolderSelection(folder, clearSelectedVideo: clearSelectedVideo)
    }

    private func backfillProjectMetadataIfNeeded(for projects: [Folder], in context: NSManagedObjectContext) {
        var didChange = false

        for project in projects where project.isProject {
            let trimmedTitle = project.projectTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedTitle.isEmpty {
                project.projectTitle = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                didChange = true
            }

            let trimmedThumbnailPath = project.projectThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedThumbnailPath.isEmpty, let thumbnailPath = project.resolvedProjectThumbnailPath {
                project.projectThumbnailPath = thumbnailPath
                didChange = true
            }
        }

        guard didChange else { return }

        do {
            try context.save()
        } catch {
            errorMessage = "Failed to update project metadata: \(error.localizedDescription)"
            context.rollback()
        }
    }

    func projects() -> [Folder] {
        guard let context = libraryManager.viewContext, let library = libraryManager.currentLibrary else { return [] }
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND isTopLevel == YES AND isSmartFolder == NO", library)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Folder.name, ascending: true)]
        do {
            let folders = try context.fetch(request)
            backfillProjectMetadataIfNeeded(for: folders, in: context)
            return folders.sorted {
                $0.resolvedProjectTitle.localizedCaseInsensitiveCompare($1.resolvedProjectTitle) == .orderedAscending
            }
        } catch {
            errorMessage = "Failed to load projects: \(error.localizedDescription)"
            return []
        }
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

    func projectSections(for project: Folder, matching query: String? = nil) -> [ProjectSectionSnapshot] {
        let trimmedQuery = (query ?? projectSearchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmedQuery.isEmpty ? nil : trimmedQuery.localizedLowercase

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
            openProject(project)
        } else if let folder = video.folder {
            let topLevelFolder = topLevelAncestor(for: folder)
            if topLevelFolder.isProject {
                openProject(topLevelFolder)
            }
        }

        selectedVideo = video
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

    func openProject(_ project: Folder) {
        guard project.isProject else { return }

        if selectionKey(selectedSidebarItem) != selectionKey(.projects) {
            suppressNextSidebarSelectionChange = true
            selectedSidebarItem = .projects
        }

        if selectedProject?.objectID != project.objectID {
            selectedProject = project
        }

        if selectedTopLevelFolder?.objectID != project.objectID {
            selectedTopLevelFolder = project
        }

        if currentFolderID != project.id {
            currentFolderID = project.id
        }

        clearProjectDetailState()

        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }
    }

    func selectVideo(by id: UUID) {
        guard let context = libraryManager.viewContext else { return }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        if let v = try? context.fetch(request).first {
            selectedVideo = v
        }
    }

    // Reveal a video's location in the folder hierarchy and select it.
    func revealVideoLocation(_ video: Video) {
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

    func navigateBackFromDetail() {
        if selectedVideo != nil {
            selectedVideo = nil
            return
        }

        guard currentDestination == .projects, selectedProject != nil else { return }

        if selectionKey(selectedSidebarItem) != selectionKey(.projects) {
            suppressNextSidebarSelectionChange = true
            selectedSidebarItem = .projects
        }

        clearProjectDetailState(clearProject: true)
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
    
    // MARK: - Folder Management
    @discardableResult
    func createFolder(name: String, in parentFolderID: UUID? = nil) async -> UUID? {
        print("📁 STORE: createFolder called with name '\(name)' and parentID: \(parentFolderID?.uuidString ?? "nil")")
        
        guard let context = libraryManager.viewContext else {
            print("📁 STORE: No view context available")
            errorMessage = "Could not create folder - no context"
            return nil
        }
        
        guard let library = libraryManager.currentLibrary else {
            print("📁 STORE: No current library available")
            errorMessage = "Could not create folder - no library"
            return nil
        }
        
        guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            print("📁 STORE: Could not get Folder entity description")
            errorMessage = "Could not create folder - no entity"
            return nil
        }
        
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { 
            print("📁 STORE: Empty trimmed name")
            return nil
        }
        
        print("📁 STORE: Creating folder with library: \(library.name ?? "Unknown")")
        
        let folder = Folder(entity: folderEntityDescription, insertInto: context)
        folder.id = UUID()
        folder.name = trimmedName
        folder.projectTitle = (parentFolderID == nil) ? trimmedName : nil
        folder.projectProvider = nil
        folder.projectThumbnailPath = nil
        folder.isTopLevel = (parentFolderID == nil)
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.library = library
        
        print("📁 STORE: Created folder object with ID: \(folder.id?.uuidString ?? "nil"), name: '\(folder.name ?? "nil")'")
        
        if let parentFolderID = parentFolderID {
            let parentRequest = Folder.fetchRequest()
            parentRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, parentFolderID as CVarArg)
            do {
                if let parentFolder = try context.fetch(parentRequest).first {
                    // Don't allow smart folders to have children
                    if !parentFolder.isSmartFolder {
                        folder.parentFolder = parentFolder
                        folder.isTopLevel = false
                        folder.projectTitle = nil
                        folder.projectProvider = nil
                        folder.projectThumbnailPath = nil
                        print("📁 STORE: Set parent folder to: \(parentFolder.name ?? "nil")")
                    } else {
                        print("📁 STORE: Parent is a smart folder, creating as top-level instead")
                        folder.isTopLevel = true
                        folder.projectTitle = trimmedName
                    }
                }
            } catch {
                errorMessage = "Failed to find parent folder: \(error.localizedDescription)"
                context.rollback()
                return nil
            }
        }
        
        print("📁 STORE: Saving context...")
        await libraryManager.save()
        print("📁 STORE: Context saved successfully")
        return folder.id
    }
    
    func moveItems(_ itemIDs: Set<UUID>, to destinationFolderID: UUID?) async {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              !itemIDs.isEmpty else { return }

        do {
            let destinationFolder: Folder?
            if let destinationFolderID {
                let destinationRequest = Folder.fetchRequest()
                destinationRequest.predicate = NSPredicate(
                    format: "library == %@ AND id == %@",
                    library,
                    destinationFolderID as CVarArg
                )
                destinationRequest.fetchLimit = 1

                guard let fetchedDestination = try context.fetch(destinationRequest).first else {
                    errorMessage = "Destination folder could not be found."
                    return
                }

                guard !fetchedDestination.isSmartFolder else {
                    errorMessage = "Cannot move items into a smart folder."
                    return
                }

                destinationFolder = fetchedDestination
            } else {
                destinationFolder = nil
            }

            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND id IN %@", library, itemIDs)
            let videosToMove = try context.fetch(videoRequest)

            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "library == %@ AND id IN %@", library, itemIDs)
            let foldersToMove = try context.fetch(folderRequest)

            guard !videosToMove.isEmpty || !foldersToMove.isEmpty else { return }

            let selectedFolderIDs = Set(foldersToMove.compactMap(\.id))
            let effectiveFolders = foldersToMove.filter { folder in
                !hasSelectedAncestor(folder: folder, selectedFolderIDs: selectedFolderIDs)
            }
            let effectiveVideos = videosToMove.filter { video in
                guard let parentFolder = video.folder else { return true }
                return !isFolderOrAncestorSelected(parentFolder, selectedFolderIDs: selectedFolderIDs)
            }

            let videosForMove = effectiveVideos

            if let destinationFolder {
                for folder in effectiveFolders {
                    if folder.objectID == destinationFolder.objectID {
                        errorMessage = "Cannot move a folder into itself."
                        return
                    }

                    if isDescendant(candidate: destinationFolder, of: folder) {
                        errorMessage = "Cannot move a folder into one of its descendants."
                        return
                    }
                }
            }

            let now = Date()
            var hasChanges = false

            for video in videosForMove where video.folder != destinationFolder {
                video.folder = destinationFolder
                hasChanges = true
            }

            for folder in effectiveFolders {
                let shouldBeTopLevel = (destinationFolder == nil)
                let parentChanged = folder.parentFolder != destinationFolder
                let topLevelChanged = folder.isTopLevel != shouldBeTopLevel

                guard parentChanged || topLevelChanged else { continue }

                folder.parentFolder = destinationFolder
                folder.isTopLevel = shouldBeTopLevel
                folder.dateModified = now
                hasChanges = true
            }

            if hasChanges {
                await libraryManager.save()
            }
        } catch {
            errorMessage = "Failed to move items: \(error.localizedDescription)"
            context.rollback()
        }
    }

    private func hasSelectedAncestor(folder: Folder, selectedFolderIDs: Set<UUID>) -> Bool {
        var current = folder.parentFolder

        while let currentFolder = current {
            if let currentID = currentFolder.id, selectedFolderIDs.contains(currentID) {
                return true
            }
            current = currentFolder.parentFolder
        }

        return false
    }

    private func isFolderOrAncestorSelected(_ folder: Folder, selectedFolderIDs: Set<UUID>) -> Bool {
        var current: Folder? = folder

        while let currentFolder = current {
            if let currentID = currentFolder.id, selectedFolderIDs.contains(currentID) {
                return true
            }
            current = currentFolder.parentFolder
        }

        return false
    }

    private func isDescendant(candidate: Folder, of ancestor: Folder) -> Bool {
        var current = candidate.parentFolder

        while let currentFolder = current {
            if currentFolder.objectID == ancestor.objectID {
                return true
            }
            current = currentFolder.parentFolder
        }

        return false
    }
    
    // MARK: - Sorting
    private func applySorting(_ items: [ContentType]) -> [ContentType] {
        switch currentSortOption {
        case .nameAscending:
            return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return items.sorted { $0.name.localizedCompare($1.name) == .orderedDescending }
        case .dateCreatedNewest:
            return items.sorted { $0.dateCreated > $1.dateCreated }
        case .dateCreatedOldest:
            return items.sorted { $0.dateCreated < $1.dateCreated }
        case .foldersFirst:
            return items.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder {
                    return lhs.isFolder
                }
                return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
        }
    }
    
    // MARK: - Folder Name
    func folderName(for folderID: UUID?) -> String {
        guard let folderID = folderID,
              let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            return "Library"
        }
        
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        
        do {
            if let folder = try context.fetch(request).first {
                return folder.isProject ? folder.resolvedProjectTitle : (folder.name ?? "Untitled")
            }
        } catch {}
        
        return "Unknown Folder"
    }
    
    // MARK: - Current Folder
    var currentFolder: Folder? {
        guard let folderID = currentFolderID,
              let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            return nil
        }
        
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        
        do {
            return try context.fetch(request).first
        } catch {
            return nil
        }
    }
    
    // MARK: - Auto-select first video
    
    private func selectFirstVideoInCurrentFolderIfNeeded() {
        guard shouldAutoSelectFirstVideo else { return }
        // Build a list of videos in the current folder from the freshly refreshed flatContent
        let videosInFolder: [Video] = flatContent.compactMap {
            if case .video(let v) = $0 { return v }
            return nil
        }
        
        guard let firstVideo = videosInFolder.first else {
            // No videos in this folder; clear selection
            selectedVideo = nil
            return
        }
        
        // If nothing selected, select the first
        guard let currentSelected = selectedVideo else {
            selectedVideo = firstVideo
            return
        }
        
        // If a video is selected but it's not in the current folder's content, select the first
        let containsCurrent = videosInFolder.contains(where: { $0.objectID == currentSelected.objectID })
        if !containsCurrent {
            selectedVideo = firstVideo
        }
        
        // If containsCurrent is true, keep current selection (do not override)
    }

    private var shouldAutoSelectFirstVideo: Bool { false }
    
    // MARK: - Renaming
    func renameItem(id: UUID, to newName: String) async {
        guard let context = libraryManager.viewContext else { return }
        
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        do {
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            
            if let folder = try context.fetch(folderRequest).first {
                let previousName = folder.name
                folder.name = trimmedName
                if folder.isProject {
                    let existingTitle = folder.projectTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if existingTitle.isEmpty || existingTitle == (previousName ?? "") {
                        folder.projectTitle = trimmedName
                    }
                }
                folder.dateModified = Date()
                await libraryManager.save()
                return
            }
            
            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            
            if let video = try context.fetch(videoRequest).first {
                video.title = trimmedName
                await libraryManager.save()
                return
            }
        } catch {
            errorMessage = "Failed to find item to rename: \(error.localizedDescription)"
            context.rollback()
        }
    }
    
    // MARK: - Deletion
    func deleteItems(
        _ itemIDs: Set<UUID>,
        folderDeletionMode: FolderDeletionMode = .deleteAllVideos
    ) async -> Bool {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            errorMessage = "Unable to access library context"
            return false
        }
        
        do {
            // Find all folders to delete
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "id IN %@", itemIDs)
            let foldersToDelete = try context.fetch(folderRequest)
            
            // Find all videos to delete
            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "id IN %@", itemIDs)
            let videosToDelete = try context.fetch(videoRequest)
            
            // Prevent deletion of system folders
            for folder in foldersToDelete {
                if folder.isSmartFolder {
                    errorMessage = "Cannot delete system folders"
                    return false
                }
            }
            
            // Collect videos from folders recursively
            var videosInsideDeletedFolders: [Video] = []
            for folder in foldersToDelete {
                videosInsideDeletedFolders.append(contentsOf: collectAllVideos(from: folder))
            }

            videosInsideDeletedFolders = Array(Set(videosInsideDeletedFolders))
            let directlySelectedVideos = Array(Set(videosToDelete))
            let directlySelectedVideoObjectIDs = Set(directlySelectedVideos.map(\.objectID))

            var videosDeletedFromLibrary: [Video] = directlySelectedVideos

            switch folderDeletionMode {
            case .deleteAllVideos:
                var allVideosToDelete = videosInsideDeletedFolders
                allVideosToDelete.append(contentsOf: directlySelectedVideos)
                allVideosToDelete = Array(Set(allVideosToDelete))

                await deleteVideoFiles(allVideosToDelete, library: library)
                videosDeletedFromLibrary = allVideosToDelete

            case .keepVideosInLibrary:
                // Keep videos that are only included because their parent folder is being deleted.
                // Explicitly selected videos (if any) are still deleted.
                let videosToKeep = videosInsideDeletedFolders.filter { video in
                    !directlySelectedVideoObjectIDs.contains(video.objectID)
                }

                for video in videosToKeep where video.folder != nil {
                    video.folder = nil
                }

                if !directlySelectedVideos.isEmpty {
                    await deleteVideoFiles(directlySelectedVideos, library: library)
                }
            }
            
            // Delete from Core Data (this will cascade to child folders and videos)
            for folder in foldersToDelete {
                context.delete(folder)
            }
            
            for video in videosToDelete {
                context.delete(video)
            }
            
            // Save changes
            if context.hasChanges {
                try context.save()
                print("🗑️ DELETION: Successfully deleted \(itemIDs.count) items")
                
                // Update selected video if it was deleted
                let deletedVideoIDs = Set(videosDeletedFromLibrary.compactMap(\.id))
                if let selectedVideo = selectedVideo,
                   let selectedVideoID = selectedVideo.id,
                   deletedVideoIDs.contains(selectedVideoID) {
                    self.selectedVideo = nil
                }
                
                return true
            }
            
            return true
            
        } catch {
            errorMessage = "Failed to delete items: \(error.localizedDescription)"
            context.rollback()
            return false
        }
    }
    
    private func collectAllVideos(from folder: Folder) -> [Video] {
        var videos: [Video] = []
        
        // Add videos directly in this folder
        videos.append(contentsOf: folder.videosArray)
        
        // Recursively collect from child folders
        for childFolder in folder.childFoldersArray {
            videos.append(contentsOf: collectAllVideos(from: childFolder))
        }
        
        return videos
    }
    
    private func deleteVideoFiles(_ videos: [Video], library: Library) async {
        guard let libraryURL = library.url else { return }
        
        for video in videos {
            // Delete video file
            if let videoURL = video.fileURL {
                do {
                    try FileManager.default.removeItem(at: videoURL)
                    print("🗑️ DELETION: Deleted video file: \(videoURL.lastPathComponent)")
                } catch {
                    print("⚠️ DELETION: Failed to delete video file \(videoURL.lastPathComponent): \(error)")
                }
            }
            
            // Delete thumbnail
            if let thumbnailURL = video.thumbnailURL {
                do {
                    try FileManager.default.removeItem(at: thumbnailURL)
                    print("🗑️ DELETION: Deleted thumbnail: \(thumbnailURL.lastPathComponent)")
                } catch {
                    print("⚠️ DELETION: Failed to delete thumbnail \(thumbnailURL.lastPathComponent): \(error)")
                }
            }
            
            // Delete subtitles
            if let subtitles = video.subtitles as? Set<Subtitle> {
                for subtitle in subtitles {
                    if let subtitleURL = subtitle.fileURL {
                        do {
                            try FileManager.default.removeItem(at: subtitleURL)
                            print("🗑️ DELETION: Deleted subtitle: \(subtitleURL.lastPathComponent)")
                        } catch {
                            print("⚠️ DELETION: Failed to delete subtitle \(subtitleURL.lastPathComponent): \(error)")
                        }
                    }
                }
            }

            // Delete transcript artifacts
            if let transcriptURL = libraryManager.transcriptURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: transcriptURL.path) {
                        try FileManager.default.removeItem(at: transcriptURL)
                        print("🗑️ DELETION: Deleted transcript: \(transcriptURL.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ DELETION: Failed to delete transcript \(transcriptURL.lastPathComponent): \(error)")
                }
            }

            if let timedTranscriptURL = libraryManager.timedTranscriptURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: timedTranscriptURL.path) {
                        try FileManager.default.removeItem(at: timedTranscriptURL)
                        print("🗑️ DELETION: Deleted timed transcript: \(timedTranscriptURL.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ DELETION: Failed to delete timed transcript \(timedTranscriptURL.lastPathComponent): \(error)")
                }
            }

            if let summaryURL = libraryManager.summaryURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: summaryURL.path) {
                        try FileManager.default.removeItem(at: summaryURL)
                        print("🗑️ DELETION: Deleted summary: \(summaryURL.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ DELETION: Failed to delete summary \(summaryURL.lastPathComponent): \(error)")
                }
            }

            if let flashcardsURL = libraryManager.flashcardsURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: flashcardsURL.path) {
                        try FileManager.default.removeItem(at: flashcardsURL)
                        print("🗑️ DELETION: Deleted flashcards: \(flashcardsURL.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ DELETION: Failed to delete flashcards \(flashcardsURL.lastPathComponent): \(error)")
                }
            }

            for translationURL in libraryManager.translationURLs(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: translationURL.path) {
                        try FileManager.default.removeItem(at: translationURL)
                        print("🗑️ DELETION: Deleted translation: \(translationURL.lastPathComponent)")
                    }
                } catch {
                    print("⚠️ DELETION: Failed to delete translation \(translationURL.lastPathComponent): \(error)")
                }
            }
        }
        
        // Clean up empty directories
        await cleanupEmptyDirectories(in: libraryURL)
    }
    
    private func cleanupEmptyDirectories(in libraryURL: URL) async {
        let directories = [
            libraryURL.appendingPathComponent("Videos"),
            libraryURL.appendingPathComponent("Thumbnails"),
            libraryURL.appendingPathComponent("Subtitles")
        ]
        
        for directory in directories {
            await cleanupEmptyDirectoriesRecursively(at: directory)
        }
    }
    
    private func cleanupEmptyDirectoriesRecursively(at url: URL) async {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            
            // First, recursively clean subdirectories
            for item in contents {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    await cleanupEmptyDirectoriesRecursively(at: item)
                }
            }
            
            // Check if directory is now empty and remove it
            let updatedContents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            if updatedContents.isEmpty {
                try FileManager.default.removeItem(at: url)
                print("🗑️ DELETION: Cleaned up empty directory: \(url.lastPathComponent)")
            }
        } catch {
            // Directory doesn't exist or can't be read - that's fine
        }
    }
}
