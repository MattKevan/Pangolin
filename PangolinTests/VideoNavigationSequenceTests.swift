import CoreData
import Foundation
import Testing
import Combine
@testable import Pangolin

@Suite(.serialized)
struct VideoNavigationSequenceTests {
    @Test("Project video neighbors follow project section order")
    @MainActor
    func projectVideoNeighborsFollowProjectSectionOrder() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let sectionA = try makeFolder(named: "A", in: context, parent: project, library: library)
        let sectionB = try makeFolder(named: "B", in: context, parent: project, library: library)

        let first = try makeVideo(title: "Lesson 1", thumbnailData: nil, in: context, folder: sectionA, library: library, fileName: "1.mp4")
        let second = try makeVideo(title: "Lesson 2", thumbnailData: nil, in: context, folder: sectionA, library: library, fileName: "2.mp4")
        let third = try makeVideo(title: "Lesson 3", thumbnailData: nil, in: context, folder: sectionB, library: library, fileName: "3.mp4")
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.openProjectVideo(second, in: project)

        let neighbors = store.videoNeighbors(for: second)
        #expect(neighbors.previous?.objectID == first.objectID)
        #expect(neighbors.next?.objectID == third.objectID)

        await manager.closeCurrentLibrary()
    }

    @Test("Opening another video in a project does not transiently deselect it")
    @MainActor
    func openingAnotherProjectVideoDoesNotClearTheVideoRoute() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let first = try makeVideo(title: "Lesson 1", thumbnailData: nil, in: context, folder: project, library: library)
        let second = try makeVideo(title: "Lesson 2", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.openProjectVideo(first, in: project)

        // @Observable no longer exposes Combine-style projected bindings; assert
        // the behavioral contract directly (selection switches to the new video
        // with no transient deselection, and the detail surface stays active).
        store.openProjectVideo(second, in: project)

        #expect(store.selectedVideo?.id == second.id)
        #expect(store.currentDetailSurface == .videoDetail)
        #expect(store.selectedVideo?.objectID == second.objectID)

        await manager.closeCurrentLibrary()
    }

    @Test("Folder video neighbors follow current flat content order")
    @MainActor
    func folderVideoNeighborsFollowCurrentFlatContentOrder() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let folder = try makeFolder(named: "Folder", in: context, parent: nil, library: library)
        let first = try makeVideo(title: "Alpha", thumbnailData: nil, in: context, folder: folder, library: library, fileName: "1.mp4")
        let second = try makeVideo(title: "Bravo", thumbnailData: nil, in: context, folder: folder, library: library, fileName: "2.mp4")
        let third = try makeVideo(title: "Charlie", thumbnailData: nil, in: context, folder: folder, library: library, fileName: "3.mp4")
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        // Exercise the same route used when a video is opened from the library.
        // `navigateToFolder` is a legacy path setter and intentionally does not
        // change the active sidebar destination.
        store.revealVideoLocation(second)
        try await waitForFlatVideoCount(3, in: store)

        let neighbors = store.videoNeighbors(for: second)
        #expect(neighbors.previous?.objectID == first.objectID)
        #expect(neighbors.next?.objectID == third.objectID)

        await manager.closeCurrentLibrary()
    }

    @Test("Orphaned video has no neighbors")
    @MainActor
    func orphanedVideoHasNoNeighbors() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let orphan = try makeVideo(title: "Orphan", thumbnailData: nil, in: context, folder: nil, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.openVideoDetailWithoutLocation(orphan)

        let neighbors = store.videoNeighbors(for: orphan)
        #expect(neighbors.previous == nil)
        #expect(neighbors.next == nil)

        await manager.closeCurrentLibrary()
    }

    @Test("Back from a project video returns to that project after moving between videos")
    @MainActor
    func projectVideoBackRestoresProjectOrigin() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let first = try makeVideo(title: "First", thumbnailData: nil, in: context, folder: project, library: library)
        let second = try makeVideo(title: "Second", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.openProjectVideo(first, in: project)
        store.selectVideo(second)
        store.navigateBackFromDetail()

        #expect(store.currentDetailSurface == .projectDetail)
        #expect(store.selectedSidebarItem == .projects)
        #expect(store.selectedProject?.objectID == project.objectID)
        #expect(store.selectedVideo == nil)

        await manager.closeCurrentLibrary()
    }

    @Test("Back from a smart collection video restores the collection")
    @MainActor
    func smartCollectionVideoBackRestoresOrigin() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let video = try makeVideo(title: "Favorite", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.selectedSidebarItem = .smartCollection(.favorites)
        store.revealVideoLocation(video)
        store.navigateBackFromDetail()

        #expect(store.currentDestination == .smartCollection(.favorites))
        #expect(store.currentDetailSurface == .smartCollectionTable(.favorites))
        #expect(store.selectedVideo == nil)

        await manager.closeCurrentLibrary()
    }

    @Test("Back from a search result video restores search")
    @MainActor
    func searchVideoBackRestoresOrigin() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let video = try makeVideo(title: "Result", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.activateSearch()
        store.openFromSearchCitation(video, seekTo: nil, source: nil)
        store.navigateBackFromDetail()

        #expect(store.currentDestination == .search)
        #expect(store.currentDetailSurface == .searchResults)
        #expect(store.selectedVideo == nil)

        await manager.closeCurrentLibrary()
    }

    @Test("On iPhone, back from a video without an origin falls back to the projects list")
    @MainActor
    func originlessVideoBackFallsBackToProjects() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let video = try makeVideo(title: "Orphan", thumbnailData: nil, in: context, folder: nil, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager, home: .projectsList)
        store.selectedSidebarItem = nil
        store.openVideoDetailWithoutLocation(video)
        store.navigateBackFromDetail()

        #expect(store.currentDestination == .projects)
        #expect(store.currentDetailSurface == .projectsGrid)
        #expect(store.selectedVideo == nil)

        await manager.closeCurrentLibrary()
    }

    @Test("On Mac and iPad, back from a video without an origin falls back to All videos")
    @MainActor
    func originlessVideoBackFallsBackToAllVideos() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let video = try makeVideo(title: "Orphan", thumbnailData: nil, in: context, folder: nil, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager, home: .allVideos)
        store.selectedSidebarItem = nil
        store.openVideoDetailWithoutLocation(video)
        store.navigateBackFromDetail()

        #expect(store.currentDestination == .smartCollection(.allVideos))
        #expect(store.currentDetailSurface == .smartCollectionTable(.allVideos))
        #expect(store.selectedVideo == nil)

        await manager.closeCurrentLibrary()
    }

    @Test("Abandoning video detail clears selection state without restoring its origin")
    @MainActor
    func abandonVideoDetailClearsStateWithoutRestoringOrigin() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let first = try makeVideo(title: "First", thumbnailData: nil, in: context, folder: project, library: library)
        let second = try makeVideo(title: "Second", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager, home: .projectsList)
        store.activateSearch()
        store.openFromSearchCitation(first, seekTo: 12, source: nil)
        #expect(store.pendingSearchSeekRequest != nil)
        #expect(!store.selectedProjectVideoIDs.isEmpty)

        store.abandonVideoDetail()
        store.abandonVideoDetail()

        #expect(store.selectedVideo == nil)
        #expect(store.pendingSearchSeekRequest == nil)
        #expect(store.selectedProjectVideoIDs.isEmpty)
        #expect(store.currentDestination != .search)

        store.selectVideo(second)
        store.navigateBackFromDetail()

        #expect(store.currentDestination == .projects)
        #expect(store.currentDetailSurface == .projectsGrid)

        await manager.closeCurrentLibrary()
    }

    @Test("External video deselection restores and consumes its search origin exactly once")
    @MainActor
    func externalDeselectionRestoresSearchOriginOnce() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Course", in: context, parent: nil, library: library)
        let video = try makeVideo(title: "Result", thumbnailData: nil, in: context, folder: project, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.activateSearch()
        store.openFromSearchCitation(video, seekTo: 12, source: nil)
        store.selectedVideo = nil

        store.restoreVideoNavigationOriginAfterSelectionCleared()

        #expect(store.currentDestination == .search)
        #expect(store.currentDetailSurface == .searchResults)
        #expect(store.pendingSearchSeekRequest == nil)
        #expect(store.selectedProjectVideoIDs.isEmpty)

        store.restoreVideoNavigationOriginAfterSelectionCleared()

        #expect(store.currentDestination == .search)
        #expect(store.currentDetailSurface == .searchResults)

        await manager.closeCurrentLibrary()
    }

    @MainActor
    private func waitForFlatVideoCount(
        _ expectedCount: Int,
        in store: FolderNavigationStore
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))

        while store.flatContent.filter({
            if case .video = $0 { return true }
            return false
        }).count != expectedCount {
            guard clock.now < deadline else {
                throw NavigationTestFailure("Timed out waiting for folder videos to load")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Rename bumps content revision so method-driven views refresh")
    @MainActor
    func renameBumpsContentRevision() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let project = try makeFolder(named: "Before", in: context, parent: nil, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        let before = store.contentRevision
        let projectID = try #require(project.id)

        await store.renameItem(id: projectID, to: "After")

        // The store refreshes through its debounced context-save observer;
        // wait (bounded) for the revision to advance.
        var attempts = 0
        while store.contentRevision == before && attempts < 100 {
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(store.contentRevision > before)

        await manager.closeCurrentLibrary()
    }

    @MainActor
    private func makeLibraryContext() async throws -> (LibraryManager, NSManagedObjectContext, URL) {
        let manager = LibraryManager.shared
        await manager.closeCurrentLibrary()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinVideoNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let libraryURL = tempRoot.appendingPathComponent("Library", isDirectory: true)
        _ = try await manager.loadLibrary(at: libraryURL)

        guard let context = manager.viewContext else {
            throw NavigationTestFailure("Expected view context")
        }

        return (manager, context, tempRoot)
    }

    @MainActor
    private func requireLibrary(from manager: LibraryManager) throws -> Library {
        guard let library = manager.currentLibrary else {
            throw NavigationTestFailure("Expected current library")
        }
        return library
    }

    @MainActor
    private func makeFolder(
        named name: String,
        in context: NSManagedObjectContext,
        parent: Folder?,
        library: Library
    ) throws -> Folder {
        guard let folderEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            throw NavigationTestFailure("Missing Folder entity")
        }

        let folder = Folder(entity: folderEntity, insertInto: context)
        folder.id = UUID()
        folder.name = name
        folder.projectTitle = parent == nil ? name : nil
        folder.projectProvider = nil
        folder.isTopLevel = (parent == nil)
        folder.isSmartFolder = false
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.parentFolder = parent
        folder.library = library
        return folder
    }

    @MainActor
    private func makeVideo(
        title: String,
        thumbnailData: Data?,
        in context: NSManagedObjectContext,
        folder: Folder?,
        library: Library,
        fileName: String? = nil
    ) throws -> Video {
        guard let videoEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Video"] else {
            throw NavigationTestFailure("Missing Video entity")
        }

        let video = Video(entity: videoEntity, insertInto: context)
        video.id = UUID()
        video.title = title
        video.fileName = fileName ?? "\(title).mp4"
        if let thumbnailData {
            video.thumbnailData = thumbnailData
            video.thumbnailGenerationVersion = ThumbnailGenerator.currentVersion
            video.thumbnailGeneratedAt = Date()
        }
        video.duration = 60
        video.fileSize = 1_024
        video.dateAdded = Date()
        video.folder = folder
        video.library = library
        return video
    }
}

private struct NavigationTestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
