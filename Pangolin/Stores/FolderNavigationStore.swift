//
//  FolderNavigationStore.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI
import CoreData
import Combine

// MARK: - Sidebar Selection Types
enum SidebarSelection: Hashable, Identifiable {
    case search
    case folder(Folder)
    case video(Video)
    
    var id: String {
        switch self {
        case .search: return "search"
        case .folder(let folder): return folder.id?.uuidString ?? ""
        case .video(let video): return video.id?.uuidString ?? ""
        }
    }
}

@MainActor
class FolderNavigationStore: ObservableObject {
    // MARK: - Core State
    @Published var navigationPath = NavigationPath()
    @Published var currentFolderID: UUID?
    @Published var selectedSidebarItem: SidebarSelection? {
        didSet {
            handleSidebarSelectionChange()
        }
    }
    @Published var selectedTopLevelFolder: Folder? {
        didSet {
            // When the top-level folder changes, ensure a video is selected
            // Defer to next runloop to avoid publishing during view updates
            Task { @MainActor in
                self.selectedVideo = nil
            }
        }
    }
    @Published var selectedVideo: Video?
    @Published var isSearchMode = false
    
    // Reactive data sources for the UI
    @Published var hierarchicalContent: [HierarchicalContentItem] = []
    @Published var flatContent: [ContentType] = []

    // MARK: - UI State
    @Published var currentSortOption: SortOption = .foldersFirst {
        didSet {
            // Re-apply sorting whenever the option changes
            self.flatContent = applySorting(self.flatContent)
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Dependencies
    private let libraryManager: LibraryManager
    private var cancellables = Set<AnyCancellable>()
    
    init(libraryManager: LibraryManager) {
        self.libraryManager = libraryManager
        
        // Subscribe to Core Data saves to auto-refresh the UI
        if let context = libraryManager.viewContext {
            NotificationCenter.default
                .publisher(for: .NSManagedObjectContextDidSave, object: context)
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main) // Prevent refresh storms
                .sink { [weak self] _ in
                    print("🧠 STORE: Context saved, refreshing content.")

                    // Try to refresh context with query generation if needed
                    if let stack = self?.libraryManager.currentCoreDataStack {
                        stack.refreshViewContextIfNeeded()
                    }

                    self?.refreshContent()
                }
                .store(in: &cancellables)
        }

        
        // Subscribe to internal navigation changes to refresh content
        $currentFolderID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("🧠 STORE: Current folder changed, refreshing content.")
                self?.refreshContent()
            }
            .store(in: &cancellables)
        
        // Set initial folder and load initial content
        Task {
            guard let context = libraryManager.viewContext,
                  let library = libraryManager.currentLibrary else {
                refreshContent()
                return
            }
            
            let request = Folder.fetchRequest()
            request.predicate = NSPredicate(format: "library == %@ AND isTopLevel == YES AND isSmartFolder == YES AND name == %@", library, "All Videos")
            request.fetchLimit = 1
            
            do {
                if let allVideosFolder = try context.fetch(request).first {
                    selectedTopLevelFolder = allVideosFolder
                    selectedSidebarItem = .folder(allVideosFolder)
                    currentFolderID = allVideosFolder.id // This triggers the sink above to load content
                } else {
                    refreshContent()
                }
            } catch {
                print("Error setting initial folder: \(error)")
                refreshContent()
            }
        }
    }
    
    // MARK: - Search Support
    private func handleSidebarSelectionChange() {
        Task { @MainActor in
            switch selectedSidebarItem {
            case .search:
                isSearchMode = true
                // Don't change currentFolderID when in search mode
                // Content will be managed by SearchManager
            case .folder(let folder):
                isSearchMode = false
                if folder.isTopLevel {
                    navigationPath = NavigationPath()
                }
                selectedTopLevelFolder = folder
                currentFolderID = folder.id
                if folder.isSmartFolder {
                    selectedVideo = nil
                }
            case .video(let video):
                isSearchMode = false
                selectedVideo = video
            case .none:
                isSearchMode = false
                // Keep current state
            }
        }
    }
    
    func activateSearch() {
        selectedSidebarItem = .search
    }
    
    func selectAllVideos() {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return }
        
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND isTopLevel == YES AND isSmartFolder == YES AND name == %@", library, "All Videos")
        request.fetchLimit = 1
        
        do {
            if let allVideosFolder = try context.fetch(request).first {
                selectedSidebarItem = .folder(allVideosFolder)
            }
        } catch {
            print("Error selecting All Videos folder: \(error)")
        }
    }
    
    // MARK: - Content Fetching
    private func refreshContent() {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              let folderID = currentFolderID else {
            self.hierarchicalContent = []
            self.flatContent = []
            return
        }
        
        // 🔍 SELECTION PRESERVATION: Capture current selection before refresh
        let preservedSelectionID = selectedVideo?.id
        print("🔄 STORE: Refreshing content, preserving selection: \(preservedSelectionID?.uuidString ?? "none")")
        
        let folderRequest = Folder.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        
        var newHierarchicalContent: [HierarchicalContentItem] = []
        var newFlatContent: [ContentType] = []
        
        do {
            if let folder = try context.fetch(folderRequest).first {
                if folder.isSmartFolder {
                    let contentItems = getSmartFolderContent(folder: folder, library: library, context: context)
                    newFlatContent = contentItems
                    newHierarchicalContent = contentItems.compactMap { item in
                        if case .video(let video) = item { return HierarchicalContentItem(video: video) }
                        return nil
                    }
                } else {
                    let childFolders = folder.childFoldersArray
                    let childVideos = folder.videosArray

                    for childFolder in childFolders {
                        newHierarchicalContent.append(HierarchicalContentItem(folder: childFolder))
                        newFlatContent.append(.folder(childFolder))
                    }
                    for video in childVideos {
                        newHierarchicalContent.append(HierarchicalContentItem(video: video))
                        newFlatContent.append(.video(video))
                    }
                }
            }
        } catch {
            errorMessage = "Failed to load content: \(error.localizedDescription)"
        }
        
        // Populate the publishers
        self.hierarchicalContent = newHierarchicalContent
        self.flatContent = applySorting(newFlatContent)
        
        // 🔍 SELECTION PRESERVATION: Restore selection if it still exists in content
        if let preservedID = preservedSelectionID {
            let stillExists = newHierarchicalContent.contains { item in
                if case .video(let video) = item.contentType {
                    return video.id == preservedID
                }
                return false
            }
            
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
    
    // MARK: - Content Access (for Sidebar)
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
        selectedVideo = video
        guard let folder = video.folder else { return }

        var top = folder
        var path: [Folder] = []
        while let parent = top.parentFolder {
            path.append(parent)
            top = parent
        }
        path = path.reversed()

        selectedSidebarItem = .folder(top)
        selectedTopLevelFolder = top
        currentFolderID = folder.id

        // Rebuild navigation path (used for back button state).
        var nav = NavigationPath()
        for f in path {
            if let id = f.id {
                nav.append(id)
            }
        }
        navigationPath = nav
    }
    
    // MARK: - Folder Management
    func createFolder(name: String, in parentFolderID: UUID? = nil) async {
        print("📁 STORE: createFolder called with name '\(name)' and parentID: \(parentFolderID?.uuidString ?? "nil")")
        
        guard let context = libraryManager.viewContext else {
            print("📁 STORE: No view context available")
            errorMessage = "Could not create folder - no context"
            return
        }
        
        guard let library = libraryManager.currentLibrary else {
            print("📁 STORE: No current library available")
            errorMessage = "Could not create folder - no library"
            return
        }
        
        guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            print("📁 STORE: Could not get Folder entity description")
            errorMessage = "Could not create folder - no entity"
            return
        }
        
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { 
            print("📁 STORE: Empty trimmed name")
            return 
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
                return
            }
        }
        
        print("📁 STORE: Saving context...")
        await libraryManager.save()
        print("📁 STORE: Context saved successfully")
    }
    
    func moveItems(_ itemIDs: Set<UUID>, to destinationFolderID: UUID?) async {
        guard let context = libraryManager.viewContext,
              libraryManager.currentLibrary != nil, !itemIDs.isEmpty else { return }
        
        do {
            let destinationFolder: Folder?
            if let destID = destinationFolderID {
                let destRequest = Folder.fetchRequest()
                destRequest.predicate = NSPredicate(format: "id == %@", destID as CVarArg)
                destinationFolder = try context.fetch(destRequest).first
            } else {
                destinationFolder = nil
            }
            
            var itemsToMove: [NSManagedObject] = []
            
            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "id IN %@", itemIDs)
            itemsToMove.append(contentsOf: try context.fetch(videoRequest))
            
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "id IN %@", itemIDs)
            itemsToMove.append(contentsOf: try context.fetch(folderRequest))

            for item in itemsToMove {
                if let video = item as? Video {
                    video.folder = destinationFolder
                } else if let folder = item as? Folder {
                    folder.parentFolder = destinationFolder
                    folder.isTopLevel = (destinationFolder == nil)
                    folder.dateModified = Date()
                }
            }
            
            if context.hasChanges {
                await libraryManager.save()
            }
        } catch {
            errorMessage = "Failed to move items: \(error.localizedDescription)"
            context.rollback()
        }
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
    
    // MARK: - Smart Folder Content
    private func getSmartFolderContent(folder: Folder, library: Library, context: NSManagedObjectContext) -> [ContentType] {
        var contentItems: [ContentType] = []
        let videoRequest = Video.fetchRequest()
        
        switch folder.name {
        case "All Videos":
            videoRequest.predicate = NSPredicate(format: "library == %@", library)
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
        case "Recent":
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND dateAdded >= %@", library, thirtyDaysAgo as NSDate)
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.dateAdded, ascending: false)]
            videoRequest.fetchLimit = 50
        case "Favorites":
            videoRequest.predicate = NSPredicate(format: "library == %@ AND isFavorite == YES", library)
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
            print("🧠 STORE: Fetching Favorites smart folder content")
        default:
            return []
        }
        
        do {
            let videos = try context.fetch(videoRequest)
            if folder.name == "Favorites" {
                print("🧠 STORE: Found \(videos.count) favorite videos")
                for video in videos {
                    print("🧠 STORE: Favorite video: '\(video.title ?? "Unknown")' (isFavorite: \(video.isFavorite))")
                }
            }
            contentItems = videos.map { .video($0) }
        } catch {
            errorMessage = "Failed to load smart folder content: \(error.localizedDescription)"
        }
        
        return contentItems
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
