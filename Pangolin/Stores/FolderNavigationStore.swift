//
//  FolderNavigationStore.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI
import CoreData

class FolderNavigationStore: ObservableObject {
    // MARK: - Core State
    @Published var navigationPath = NavigationPath()
    @Published var currentFolderID: UUID?
    @Published var selectedTopLevelFolder: Folder?
    @Published var selectedVideo: Video?
    
    // MARK: - UI State
    @Published var currentSortOption: SortOption = .foldersFirst
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Dependencies
    private let libraryManager: LibraryManager
    
    init(libraryManager: LibraryManager) {
        self.libraryManager = libraryManager
        // Set initial folder to "All Videos" if available
        Task { @MainActor in
            if let allVideosFolder = systemFolders().first(where: { $0.name == "All Videos" }) {
                selectedTopLevelFolder = allVideosFolder
                currentFolderID = allVideosFolder.id
            }
        }
    }
    
    // MARK: - Content Access
    @MainActor func systemFolders() -> [Folder] {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return [] }
        
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
    
    @MainActor func userFolders() -> [Folder] {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return [] }
        
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
    
    @MainActor func topLevelFolders() -> [Folder] {
        return systemFolders() + userFolders()
    }
    
    @MainActor func content(for folderID: UUID?) -> [ContentType] {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return [] }
        
        var contentItems: [ContentType] = []
        
        if let folderID = folderID {
            // Load content of specific folder
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
            
            do {
                if let folder = try context.fetch(folderRequest).first {
                    if folder.isSmartFolder {
                        // Handle smart folders - show videos based on the folder type
                        contentItems = getSmartFolderContent(folder: folder, library: library, context: context)
                    } else {
                        // Regular folder - show child folders and videos
                        for childFolder in folder.childFoldersArray {
                            contentItems.append(.folder(childFolder))
                        }
                        
                        for video in folder.videosArray {
                            contentItems.append(.video(video))
                        }
                    }
                }
            } catch {
                errorMessage = "Failed to load folder content: \(error.localizedDescription)"
            }
        } else {
            // Load top-level content (if any videos are not in folders)
            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND folder == NULL", library)
            
            do {
                let videos = try context.fetch(videoRequest)
                for video in videos {
                    contentItems.append(.video(video))
                }
            } catch {
                errorMessage = "Failed to load videos: \(error.localizedDescription)"
            }
        }
        
        return applySorting(contentItems)
    }
    
    // MARK: - Hierarchical Content
    
    /// Get hierarchical content for the selected top-level folder
    @MainActor func hierarchicalContent(for folderID: UUID?) -> [HierarchicalContentItem] {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              let folderID = folderID else { return [] }
        
        let folderRequest = Folder.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        
        do {
            if let folder = try context.fetch(folderRequest).first {
                if folder.isSmartFolder {
                    // Smart folders show flat list of videos as hierarchical items
                    let contentItems = getSmartFolderContent(folder: folder, library: library, context: context)
                    return contentItems.compactMap { item in
                        if case .video(let video) = item {
                            return HierarchicalContentItem(video: video)
                        }
                        return nil
                    }
                } else {
                    // Regular folder - create hierarchical structure
                    var hierarchicalItems: [HierarchicalContentItem] = []
                    
                    // Add child folders (with their own hierarchical content)
                    for childFolder in folder.childFoldersArray {
                        hierarchicalItems.append(HierarchicalContentItem(folder: childFolder))
                    }
                    
                    // Add videos as leaf nodes
                    for video in folder.videosArray {
                        hierarchicalItems.append(HierarchicalContentItem(video: video))
                    }
                    
                    return hierarchicalItems
                }
            }
        } catch {
            errorMessage = "Failed to load hierarchical content: \(error.localizedDescription)"
        }
        
        return []
    }
    
    // MARK: - Navigation
    func navigateToFolder(_ folderID: UUID) {
        navigationPath.append(folderID)
    }
    
    func navigateBack() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        
        // Update currentFolderID based on remaining path
        if navigationPath.isEmpty {
            currentFolderID = selectedTopLevelFolder?.id
        } else {
            // For proper navigation, we need to track the parent folder
            // This is a limitation of NavigationPath - we'll handle it in the destination
        }
    }
    
    func navigateToRoot() {
        navigationPath = NavigationPath()
        currentFolderID = selectedTopLevelFolder?.id
    }
    
    func selectVideo(_ video: Video) {
        selectedVideo = video
    }
    
    // MARK: - Folder Management
    @MainActor
    func createFolder(name: String, in parentFolderID: UUID? = nil) async {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            errorMessage = "Could not create folder"
            return
        }
        
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let folder = Folder(entity: folderEntityDescription, insertInto: context)
        folder.id = UUID()
        folder.name = trimmedName
        folder.isTopLevel = (parentFolderID == nil)
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.library = library
        
        if let parentFolderID = parentFolderID {
            let parentRequest = Folder.fetchRequest()
            parentRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, parentFolderID as CVarArg)
            do {
                if let parentFolder = try context.fetch(parentRequest).first {
                    folder.parentFolder = parentFolder
                    folder.isTopLevel = false
                }
            } catch {
                errorMessage = "Failed to find parent folder: \(error.localizedDescription)"
                context.rollback()
                return
            }
        }
        await libraryManager.save()
        // Notify UI to refresh after successful folder creation
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }
    
    @MainActor
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
                // Notify UI to refresh after successful move
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
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
    @MainActor func folderName(for folderID: UUID?) -> String {
        guard let folderID = folderID,
              let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            return "Library"
        }
        
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        
        do {
            if let folder = try context.fetch(request).first {
                return folder.name
            }
        } catch {}
        
        return "Unknown Folder"
    }
    
    // MARK: - Smart Folder Content
    @MainActor private func getSmartFolderContent(folder: Folder, library: Library, context: NSManagedObjectContext) -> [ContentType] {
        var contentItems: [ContentType] = []
        
        let videoRequest = Video.fetchRequest()
        videoRequest.predicate = NSPredicate(format: "library == %@", library)
        
        switch folder.name {
        case "All Videos":
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
        case "Recent":
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND dateAdded >= %@", library, thirtyDaysAgo as NSDate)
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.dateAdded, ascending: false)]
            videoRequest.fetchLimit = 50
        case "Favorites":
            videoRequest.predicate = NSPredicate(format: "library == %@ AND lastPlayed != NULL", library)
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.lastPlayed, ascending: false)]
            videoRequest.fetchLimit = 50
        default:
            return []
        }
        
        do {
            let videos = try context.fetch(videoRequest)
            for video in videos {
                contentItems.append(.video(video))
            }
        } catch {
            errorMessage = "Failed to load smart folder content: \(error.localizedDescription)"
        }
        
        return contentItems
    }
    
    // MARK: - Renaming
    @MainActor
    func renameItem(id: UUID, to newName: String) async {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { 
            return 
        }
        
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { 
            return 
        }
        
        do {
            // Work directly on main context - no background queue needed for simple operations
            
            // Try to find and rename a folder
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, id as CVarArg)
            
            if let folder = try context.fetch(folderRequest).first {
                folder.name = trimmedName
                folder.dateModified = Date()
                
                if context.hasChanges {
                    try context.save()
                    // No manual notification needed - SwiftUI will automatically detect Core Data changes
                }
                return
            }
            
            // Try to find and rename a video
            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, id as CVarArg)
            
            if let video = try context.fetch(videoRequest).first {
                video.title = trimmedName
                
                if context.hasChanges {
                    try context.save()
                    // No manual notification needed - SwiftUI will automatically detect Core Data changes
                }
                return
            }
            
        } catch {
            errorMessage = "Failed to rename item: \(error.localizedDescription)"
            context.rollback()
        }
    }
}
