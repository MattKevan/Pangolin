import os
import SwiftUI
import CoreData
import Combine
import Observation
// MARK: - Folder management, sorting, renaming, deletion

extension FolderNavigationStore {
    // MARK: - Folder Management
    @discardableResult
    func createFolder(name: String, in parentFolderID: UUID? = nil) async -> UUID? {
        Logger.navigation.info("STORE: createFolder called with name '\(name)' and parentID: \(parentFolderID?.uuidString ?? "nil")")
        
        guard let context = libraryManager.viewContext else {
            Logger.navigation.info("STORE: No view context available")
            errorMessage = "Could not create folder - no context"
            return nil
        }
        
        guard let library = libraryManager.currentLibrary else {
            Logger.navigation.info("STORE: No current library available")
            errorMessage = "Could not create folder - no library"
            return nil
        }
        
        guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            Logger.navigation.info("STORE: Could not get Folder entity description")
            errorMessage = "Could not create folder - no entity"
            return nil
        }
        
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { 
            Logger.navigation.info("STORE: Empty trimmed name")
            return nil
        }
        
        Logger.navigation.info("STORE: Creating folder with library: \(library.name ?? "Unknown")")
        
        let folder = Folder(entity: folderEntityDescription, insertInto: context)
        folder.id = UUID()
        folder.name = trimmedName
        folder.projectTitle = (parentFolderID == nil) ? trimmedName : nil
        folder.projectProvider = nil
        folder.isTopLevel = (parentFolderID == nil)
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.library = library
        
        Logger.navigation.info("STORE: Created folder object with ID: \(folder.id?.uuidString ?? "nil"), name: '\(folder.name ?? "nil")'")
        
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
                        Logger.navigation.info("STORE: Set parent folder to: \(parentFolder.name ?? "nil")")
                    } else {
                        Logger.navigation.info("STORE: Parent is a smart folder, creating as top-level instead")
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
        
        Logger.navigation.info("STORE: Saving context...")
        await libraryManager.save()
        Logger.navigation.info("STORE: Context saved successfully")
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
    func applySorting(_ items: [ContentType]) -> [ContentType] {
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
            if case .video(let video) = $0 { return video }
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

            }

            // Read the file locations now; the objects are gone once the save lands.
            let fileURLs = fileURLsToDelete(for: videosDeletedFromLibrary)

            // Delete from Core Data (this will cascade to child folders and videos)
            for folder in foldersToDelete {
                context.delete(folder)
            }
            
            for video in videosToDelete {
                context.delete(video)
            }
            
            // Save first and delete files after: if the save fails the records come back
            // by rollback, and their media must still be on disk.
            if context.hasChanges {
                try context.save()
                Logger.navigation.info("DELETION: Successfully deleted \(itemIDs.count) items")
                if let libraryURL = library.url {
                    await Self.removeFiles(fileURLs, libraryURL: libraryURL)
                }
                
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
    
    /// Every file that belongs to the videos: media, subtitles and generated text.
    private func fileURLsToDelete(for videos: [Video]) -> [URL] {
        let artifacts = libraryManager.textArtifacts
        return videos.flatMap { video -> [URL] in
            var urls: [URL?] = [video.fileURL]
            urls += (video.subtitles as? Set<Subtitle> ?? []).map(\.fileURL)
            urls += [
                artifacts.transcriptURL(for: video),
                artifacts.timedTranscriptURL(for: video),
                artifacts.summaryURL(for: video),
                artifacts.flashcardsURL(for: video)
            ]
            return urls.compactMap { $0 } + artifacts.translationURLs(for: video)
        }
    }

    /// Removes the files off the main actor, then any directories left empty.
    nonisolated private static func removeFiles(_ urls: [URL], libraryURL: URL) async {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for url in urls where fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                    Logger.navigation.info("DELETION: Deleted \(url.lastPathComponent)")
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete \(url.lastPathComponent): \(error)")
                }
            }
            for name in ["Videos", "Subtitles"] {
                removeEmptyDirectories(at: libraryURL.appendingPathComponent(name))
            }
        }.value
    }

    nonisolated private static func removeEmptyDirectories(at url: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for item in contents where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            removeEmptyDirectories(at: item)
        }

        if (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
            try? fileManager.removeItem(at: url)
        }
    }
}
