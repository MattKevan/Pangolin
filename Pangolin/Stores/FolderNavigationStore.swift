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
    
    // MARK: - Navigation
    @MainActor
    func navigateToFolder(_ folderID: UUID) {
        currentFolderID = folderID
        navigationPath.append(folderID)
    }
    
    @MainActor
    func navigateBack() {
        #if os(macOS)
        // macOS might need special handling for keyboard shortcuts
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
            syncCurrentFolderFromPath()
        }
        #else
        // iOS relies on NavigationStack's automatic handling
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
            syncCurrentFolderFromPath()
        }
        #endif
    }
    
    @MainActor
    func navigateToRoot() {
        navigationPath = NavigationPath()
        currentFolderID = selectedTopLevelFolder?.id
    }
    
    @MainActor
    private func syncCurrentFolderFromPath() {
        // Keep currentFolderID in sync with navigation path
        // Since NavigationPath doesn't expose its contents directly,
        // we update based on the path state
        if navigationPath.isEmpty {
            currentFolderID = selectedTopLevelFolder?.id
        }
        // Note: For more complex path tracking, we might need to maintain
        // our own path array alongside NavigationPath
    }
    
    @MainActor
    func selectVideo(_ video: Video) {
        print("🏪 Store: Setting selectedVideo to \(video.title)")
        selectedVideo = video
    }
    
    private func updateCurrentFolder() {
        // NavigationPath doesn't directly expose its items, so we'll track current folder manually
        // This is already handled in navigateToFolder and navigateBack methods
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
        
        // Set parent folder if specified
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
                return
            }
        }
        
        do {
            try context.save()
            // Notify views that content has changed
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
        }
    }
    
    @MainActor
    func moveItems(_ itemIDs: Set<UUID>, to destinationFolderID: UUID?) async {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else { return }
        
        for itemID in itemIDs {
            // Try to find as folder first
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, itemID as CVarArg)
            
            do {
                if let folder = try context.fetch(folderRequest).first {
                    // Moving a folder
                    if let destinationFolderID = destinationFolderID {
                        let destRequest = Folder.fetchRequest()
                        destRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, destinationFolderID as CVarArg)
                        
                        if let destinationFolder = try context.fetch(destRequest).first {
                            folder.parentFolder = destinationFolder
                            folder.isTopLevel = false
                        }
                    } else {
                        folder.parentFolder = nil
                        folder.isTopLevel = true
                    }
                    folder.dateModified = Date()
                    continue
                }
            } catch {
                errorMessage = "Failed to move folder: \(error.localizedDescription)"
                continue
            }
            
            // Try to find as video
            let videoRequest = Video.fetchRequest()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, itemID as CVarArg)
            
            do {
                if let video = try context.fetch(videoRequest).first {
                    // Moving a video
                    if let destinationFolderID = destinationFolderID {
                        let destRequest = Folder.fetchRequest()
                        destRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, destinationFolderID as CVarArg)
                        
                        if let destinationFolder = try context.fetch(destRequest).first {
                            video.folder = destinationFolder
                        }
                    } else {
                        video.folder = nil
                    }
                }
            } catch {
                errorMessage = "Failed to move video: \(error.localizedDescription)"
            }
        }
        
        do {
            try context.save()
            // Notify views that content has changed
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
        } catch {
            errorMessage = "Failed to save changes: \(error.localizedDescription)"
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
        } catch {
            // Ignore error, return default
        }
        
        return "Unknown Folder"
    }
    
    // MARK: - Smart Folder Content
    @MainActor private func getSmartFolderContent(folder: Folder, library: Library, context: NSManagedObjectContext) -> [ContentType] {
        var contentItems: [ContentType] = []
        
        let videoRequest = Video.fetchRequest()
        videoRequest.predicate = NSPredicate(format: "library == %@", library)
        
        switch folder.name {
        case "All Videos":
            // Show all videos in the library
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
            
        case "Recent":
            // Show recently added videos (last 30 days or most recent 50)
            let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            videoRequest.predicate = NSPredicate(format: "library == %@ AND dateAdded >= %@", library, thirtyDaysAgo as NSDate)
            videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.dateAdded, ascending: false)]
            videoRequest.fetchLimit = 50
            
        case "Favorites":
            videoRequest.predicate = NSPredicate(format: "library == %@ AND isFavorite == YES", library)
                       videoRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Video.title, ascending: true)]
                       
                   default:
                       // Unknown smart folder type, show nothing
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
        

}
