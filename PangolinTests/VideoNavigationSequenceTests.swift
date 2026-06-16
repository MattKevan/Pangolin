import CoreData
import Foundation
import Testing
@testable import Pangolin

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

        let first = try makeVideo(title: "Lesson 1", thumbnailPath: nil, in: context, folder: sectionA, library: library, fileName: "1.mp4")
        let second = try makeVideo(title: "Lesson 2", thumbnailPath: nil, in: context, folder: sectionA, library: library, fileName: "2.mp4")
        let third = try makeVideo(title: "Lesson 3", thumbnailPath: nil, in: context, folder: sectionB, library: library, fileName: "3.mp4")
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.openProjectVideo(second, in: project)

        let neighbors = store.videoNeighbors(for: second)
        #expect(neighbors.previous?.objectID == first.objectID)
        #expect(neighbors.next?.objectID == third.objectID)

        await manager.closeCurrentLibrary()
    }

    @Test("Folder video neighbors follow current flat content order")
    @MainActor
    func folderVideoNeighborsFollowCurrentFlatContentOrder() async throws {
        let (manager, context, tempRoot) = try await makeLibraryContext()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let library = try requireLibrary(from: manager)
        let folder = try makeFolder(named: "Folder", in: context, parent: nil, library: library)
        let first = try makeVideo(title: "One", thumbnailPath: nil, in: context, folder: folder, library: library, fileName: "1.mp4")
        let second = try makeVideo(title: "Two", thumbnailPath: nil, in: context, folder: folder, library: library, fileName: "2.mp4")
        let third = try makeVideo(title: "Three", thumbnailPath: nil, in: context, folder: folder, library: library, fileName: "3.mp4")
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.navigateToFolder(try #require(folder.id))
        store.selectVideo(second)

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
        let orphan = try makeVideo(title: "Orphan", thumbnailPath: nil, in: context, folder: nil, library: library)
        try context.save()

        let store = FolderNavigationStore(libraryManager: manager)
        store.openVideoDetailWithoutLocation(orphan)

        let neighbors = store.videoNeighbors(for: orphan)
        #expect(neighbors.previous == nil)
        #expect(neighbors.next == nil)

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
        _ = try await manager.createLibrary(at: libraryURL, name: "Navigation Test Library")

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
        folder.projectThumbnailPath = nil
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
        thumbnailPath: String?,
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
        video.thumbnailPath = thumbnailPath
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
