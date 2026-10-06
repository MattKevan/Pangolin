import os
import SwiftUI
import CoreData
import Combine
import Observation
// MARK: - Content fetching

extension FolderNavigationStore {
    // MARK: - Content Fetching
    func refreshContent() {
        backfillProjectMetadataIfNeeded()
        contentRevision &+= 1
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
        Logger.navigation.info("STORE: Refreshing content, preserving selection: \(preservedSelectionID?.uuidString ?? "none")")
        
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
                Logger.navigation.info("STORE: Preserved smart-collection selection \(preservedID.uuidString)")
            } else if selectedVideo != nil {
                Logger.navigation.error("STORE: Clearing selection not present in smart collection")
                selectedVideo = nil
            }
        } else if let preservedID = preservedSelectionID {
            let stillExists = containsVideo(withID: preservedID, in: newHierarchicalContent)
            
            if stillExists {
                Logger.navigation.info("STORE: Preserved selection \(preservedID.uuidString) still exists, keeping it")
                // Keep the current selectedVideo - don't change it
                return
            } else {
                Logger.navigation.error("STORE: Preserved selection \(preservedID.uuidString) no longer exists")
                selectedVideo = nil
            }
        }
        
        // Only select first video if we have no current selection
        if selectedVideo == nil {
            Logger.navigation.info("STORE: No selection, leaving empty")
        } else {
            Logger.navigation.info("STORE: Keeping existing selection: \(self.selectedVideo?.title ?? "unknown")")
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

    func observeContextSaveNotifications() {
        contextSaveCancellable?.cancel()

        guard let context = libraryManager.viewContext else {
            contextSaveCancellable = nil
            return
        }

        contextSaveCancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave, object: context)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Logger.navigation.info("STORE: Context saved, refreshing content.")

                if let stack = self?.libraryManager.currentCoreDataStack {
                    stack.refreshViewContextIfNeeded()
                }

                self?.refreshContent()
            }
    }

    func ensureInitialSelectionIfNeeded() {
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

    /// Fills in missing project titles and keeps each project's thumbnail video id current.
    /// Runs from `refreshContent()`, never from a view body: it saves the context, and saving
    /// triggers another refresh. That settles after one pass because the backfill is idempotent.
    private func backfillProjectMetadataIfNeeded() {
        guard let context = libraryManager.viewContext,
              !context.hasChanges,
              let projects = try? context.fetch(projectsFetchRequest()) else { return }

        var didChange = false

        for project in projects where project.isProject {
            let trimmedTitle = project.projectTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedTitle.isEmpty {
                project.projectTitle = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                didChange = true
            }

            let resolvedThumbnailVideoID = project.resolvedProjectThumbnailVideo?.id
            if project.projectThumbnailVideoID != resolvedThumbnailVideoID {
                project.projectThumbnailVideoID = resolvedThumbnailVideoID
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

    private func projectsFetchRequest() -> NSFetchRequest<Folder> {
        let request = Folder.fetchRequest()
        if let library = libraryManager.currentLibrary {
            request.predicate = NSPredicate(format: "library == %@ AND isTopLevel == YES AND isSmartFolder == NO", library)
        } else {
            request.predicate = NSPredicate(value: false)
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Folder.name, ascending: true)]
        return request
    }

    /// A plain read, safe to call from a view body.
    func projects() -> [Folder] {
        guard let context = libraryManager.viewContext else { return [] }
        do {
            return try context.fetch(projectsFetchRequest()).sorted {
                $0.resolvedProjectTitle.localizedCaseInsensitiveCompare($1.resolvedProjectTitle) == .orderedAscending
            }
        } catch {
            Logger.navigation.error("STORE: Failed to load projects: \(error.localizedDescription)")
            return []
        }
    }
}
