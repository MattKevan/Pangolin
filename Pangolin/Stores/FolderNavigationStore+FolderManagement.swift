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
                Logger.navigation.info("DELETION: Successfully deleted \(itemIDs.count) items")
                
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
                    Logger.navigation.info("DELETION: Deleted video file: \(videoURL.lastPathComponent)")
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete video file \(videoURL.lastPathComponent): \(error)")
                }
            }
            
            // Delete subtitles
            if let subtitles = video.subtitles as? Set<Subtitle> {
                for subtitle in subtitles {
                    if let subtitleURL = subtitle.fileURL {
                        do {
                            try FileManager.default.removeItem(at: subtitleURL)
                            Logger.navigation.info("DELETION: Deleted subtitle: \(subtitleURL.lastPathComponent)")
                        } catch {
                            Logger.navigation.warning("DELETION: Failed to delete subtitle \(subtitleURL.lastPathComponent): \(error)")
                        }
                    }
                }
            }

            // Delete transcript artifacts
            if let transcriptURL = libraryManager.textArtifacts.transcriptURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: transcriptURL.path) {
                        try FileManager.default.removeItem(at: transcriptURL)
                        Logger.navigation.info("DELETION: Deleted transcript: \(transcriptURL.lastPathComponent)")
                    }
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete transcript \(transcriptURL.lastPathComponent): \(error)")
                }
            }

            if let timedTranscriptURL = libraryManager.textArtifacts.timedTranscriptURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: timedTranscriptURL.path) {
                        try FileManager.default.removeItem(at: timedTranscriptURL)
                        Logger.navigation.info("DELETION: Deleted timed transcript: \(timedTranscriptURL.lastPathComponent)")
                    }
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete timed transcript \(timedTranscriptURL.lastPathComponent): \(error)")
                }
            }

            if let summaryURL = libraryManager.textArtifacts.summaryURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: summaryURL.path) {
                        try FileManager.default.removeItem(at: summaryURL)
                        Logger.navigation.info("DELETION: Deleted summary: \(summaryURL.lastPathComponent)")
                    }
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete summary \(summaryURL.lastPathComponent): \(error)")
                }
            }

            if let flashcardsURL = libraryManager.textArtifacts.flashcardsURL(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: flashcardsURL.path) {
                        try FileManager.default.removeItem(at: flashcardsURL)
                        Logger.navigation.info("DELETION: Deleted flashcards: \(flashcardsURL.lastPathComponent)")
                    }
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete flashcards \(flashcardsURL.lastPathComponent): \(error)")
                }
            }

            for translationURL in libraryManager.textArtifacts.translationURLs(for: video) {
                do {
                    if FileManager.default.fileExists(atPath: translationURL.path) {
                        try FileManager.default.removeItem(at: translationURL)
                        Logger.navigation.info("DELETION: Deleted translation: \(translationURL.lastPathComponent)")
                    }
                } catch {
                    Logger.navigation.warning("DELETION: Failed to delete translation \(translationURL.lastPathComponent): \(error)")
                }
            }
        }
        
        // Clean up empty directories
        await cleanupEmptyDirectories(in: libraryURL)
    }
    
    private func cleanupEmptyDirectories(in libraryURL: URL) async {
        let directories = [
            libraryURL.appendingPathComponent("Videos"),
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
                Logger.navigation.info("DELETION: Cleaned up empty directory: \(url.lastPathComponent)")
            }
        } catch {
            // Directory doesn't exist or can't be read - that's fine
        }
    }
}
