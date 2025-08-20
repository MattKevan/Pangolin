//
//  FolderNavigationStore.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI
import CoreData
import Combine

@MainActor
class FolderNavigationStore: ObservableObject {
    // MARK: - Core State
    @Published var navigationPath = NavigationPath()
    @Published var currentFolderID: UUID?
    @Published var selectedTopLevelFolder: Folder?
    @Published var selectedVideo: Video?
    
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
    
    // MARK: - Content Fetching
    private func refreshContent() {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              let folderID = currentFolderID else {
            self.hierarchicalContent = []
            self.flatContent = []
            return
        }
        
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
    
    // MARK: - Folder Management
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
        default:
            return []
        }
        
        do {
            let videos = try context.fetch(videoRequest)
            contentItems = videos.map { .video($0) }
        } catch {
            errorMessage = "Failed to load smart folder content: \(error.localizedDescription)"
        }
        
        return contentItems
    }
    
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
}