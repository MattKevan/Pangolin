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
    case smartCollection(SmartCollectionKind)
    case folder(Folder)
    case video(Video)

    var id: String { stableKey }

    var stableKey: String {
        switch self {
        case .search:
            return "search"
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
    case smartCollectionTable(SmartCollectionKind)
    case videoDetail
    case empty
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
    @Published var selectedTopLevelFolder: Folder?
    @Published var selectedVideo: Video?
    
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

        if let kind = currentSmartCollection {
            return .smartCollectionTable(kind)
        }

        if selectedVideo != nil {
            return .videoDetail
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
            break
        case .smartCollection(let kind):
            applySmartCollectionSelection(kind)
        case .folder(let folder):
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

    private func applySmartCollectionSelection(_ kind: SmartCollectionKind) {
        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }

        if selectedTopLevelFolder != nil {
            selectedTopLevelFolder = nil
        }

        if currentFolderID != nil {
            currentFolderID = nil
        }

        if selectedVideo != nil {
            selectedVideo = nil
        }

        // Smart collections are virtual destinations, so refresh content directly.
        refreshContent()
    }

    private func applyFolderSelection(_ folder: Folder, clearSelectedVideo: Bool) {
        if !navigationPath.isEmpty {
            navigationPath = NavigationPath()
        }

        let topLevelFolder = topLevelAncestor(for: folder)
        if selectedTopLevelFolder?.id != topLevelFolder.id {
            selectedTopLevelFolder = topLevelFolder
        }

        if currentFolderID != folder.id {
            currentFolderID = folder.id
        }
        if clearSelectedVideo && selectedVideo != nil {
            selectedVideo = nil
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
        
        do {
            if let smartCollection = currentSmartCollection {
                let videos = try LibraryContentProvider.loadSmartCollection(smartCollection, library: library, context: context)
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
        if let preservedID = preservedSelectionID {
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
              selectedTopLevelFolder == nil,
              currentFolderID == nil,
              !isSearchMode,
              libraryManager.currentLibrary != nil else {
            return
        }

        selectedSidebarItem = .smartCollection(.allVideos)
    }

    private func applySidebarFolderSelectionWithoutCallback(_ folder: Folder, clearSelectedVideo: Bool) {
        let targetSelection: SidebarSelection = .folder(folder)
        if selectionKey(selectedSidebarItem) != selectionKey(targetSelection) {
            suppressNextSidebarSelectionChange = true
        }
        selectedSidebarItem = targetSelection
        applyFolderSelection(folder, clearSelectedVideo: clearSelectedVideo)
    }
    
    // MARK: - Content Access (for Sidebar)
    // Legacy persisted smart folders are kept for compatibility, but sidebar UI now renders
    // virtual smart collections from SmartCollectionKind.
    func systemFolders() -> [Folder] {
        guard let context = libraryManager.viewContext, let library = libraryManager.currentLibrary else { return [] }
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND isTopLevel == YES AND isSmartFolder == YES", library)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Folder.name, ascending: true)]
        do {
            return try context.fetch(request)
        } catch {
            errorMessage = "Failed to load system folders: \(error.localizedDescription)"
            return []
        }
    }
    
    func userFolders() -> [Folder] {
        guard let context = libraryManager.viewContext, let library = libraryManager.currentLibrary else { return [] }
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND isTopLevel == YES AND isSmartFolder == NO", library)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Folder.name, ascending: true)]
        do {
            return try context.fetch(request)
        } catch {
            errorMessage = "Failed to load user folders: \(error.localizedDescription)"
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
            // Keep the selected video even when we cannot derive a navigable folder path.
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
        selectedTopLevelFolder = top
        currentFolderID = folder.id

        // Outline mode represents hierarchy in-column, so we don't use stack-like back path here.
        navigationPath = NavigationPath()
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
                        print("📁 STORE: Set parent folder to: \(parentFolder.name ?? "nil")")
                    } else {
                        print("📁 STORE: Parent is a smart folder, creating as top-level instead")
                        folder.isTopLevel = true
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

            if destinationFolder == nil && !effectiveVideos.isEmpty && effectiveFolders.isEmpty {
                errorMessage = "Videos must stay inside a folder. Move videos into a folder destination."
                return
            }

            let videosForMove: [Video]
            if destinationFolder == nil {
                videosForMove = []
            } else {
                videosForMove = effectiveVideos
            }

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
                return folder.name!
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
                folder.name = trimmedName
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
    func deleteItems(_ itemIDs: Set<UUID>) async -> Bool {
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
            
            // Delete files from file system first
            var allVideosToDelete: [Video] = []
            
            // Collect videos from folders recursively
            for folder in foldersToDelete {
                allVideosToDelete.append(contentsOf: collectAllVideos(from: folder))
            }
            
            // Add directly selected videos
            allVideosToDelete.append(contentsOf: videosToDelete)
            
            // Remove duplicates
            allVideosToDelete = Array(Set(allVideosToDelete))
            
            // Delete files from disk
            await deleteVideoFiles(allVideosToDelete, library: library)
            
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
                if let selectedVideo = selectedVideo,
                   let selectedVideoID = selectedVideo.id,
                   itemIDs.contains(selectedVideoID) {
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
