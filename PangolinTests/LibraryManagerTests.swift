import Foundation
import CoreData
import Testing
@testable import Pangolin

struct LibraryManagerTests {
    @Test("Open library consolidates duplicate library records")
    @MainActor
    func openLibraryConsolidatesDuplicateLibraryRecords() async throws {
        let manager = LibraryManager.shared
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("PangolinLibraryMerge-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let libraryURL = tempRoot.appendingPathComponent("CanonicalLibrary", isDirectory: true)
        let library = try await manager.createLibrary(at: libraryURL, name: "Pangolin Library")

        guard let context = manager.viewContext else {
            #expect(false)
            return
        }

        guard let libraryEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Library"],
              let folderEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            #expect(false)
            return
        }

        let duplicate = Library(entity: libraryEntity, insertInto: context)
        duplicate.id = UUID()
        duplicate.name = "Pangolin Library"
        duplicate.libraryPath = libraryURL.path
        duplicate.createdDate = Date().addingTimeInterval(10)
        duplicate.lastOpenedDate = Date().addingTimeInterval(10)
        duplicate.version = "1.1.0"
        duplicate.copyFilesOnImport = true
        duplicate.organizeByDate = true
        duplicate.autoMatchSubtitles = true
        duplicate.defaultPlaybackSpeed = 1.0
        duplicate.rememberPlaybackPosition = true
        duplicate.videoStorageType = LibraryStoragePreference.optimizeStorage.rawValue
        duplicate.maxLocalVideoCacheBytes = Library.defaultMaxLocalVideoCacheBytes

        let macFolder = Folder(entity: folderEntity, insertInto: context)
        macFolder.id = UUID()
        macFolder.name = "Mac Folder"
        macFolder.isTopLevel = true
        macFolder.isSmartFolder = false
        macFolder.dateCreated = Date()
        macFolder.dateModified = Date()
        macFolder.library = library

        let phoneFolder = Folder(entity: folderEntity, insertInto: context)
        phoneFolder.id = UUID()
        phoneFolder.name = "Phone Folder"
        phoneFolder.isTopLevel = true
        phoneFolder.isSmartFolder = false
        phoneFolder.dateCreated = Date()
        phoneFolder.dateModified = Date()
        phoneFolder.library = duplicate

        try context.save()
        await manager.closeCurrentLibrary()

        let reopenedLibrary = try await manager.openLibrary(at: libraryURL)
        guard let reopenedContext = manager.viewContext else {
            #expect(false)
            return
        }

        let libraryRequest = Library.fetchRequest()
        let libraries = try reopenedContext.fetch(libraryRequest)
        #expect(libraries.count == 1)
        #expect(libraries.first?.objectID == reopenedLibrary.objectID)

        let folderRequest = Folder.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "library == %@", reopenedLibrary)
        let folders = try reopenedContext.fetch(folderRequest)
        let names = Set(folders.compactMap(\.name))
        #expect(names == Set(["Mac Folder", "Phone Folder"]))

        await manager.closeCurrentLibrary()
    }
}
