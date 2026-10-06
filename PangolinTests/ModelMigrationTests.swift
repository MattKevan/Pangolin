import CoreData
import Foundation
import Testing
@testable import Pangolin

@Suite(.serialized)
struct ModelMigrationTests {
    private func modelURL(named name: String) throws -> URL {
        let bundle = Bundle(for: CoreDataStack.self)
        let modelDirectory = try #require(bundle.url(forResource: "Pangolin", withExtension: "momd"))
        return modelDirectory.appendingPathComponent("\(name).mom")
    }

    @Test("The current model drops the per-device fields and adds fetch indexes")
    func currentModelShape() throws {
        let current = try #require(NSManagedObjectModel(contentsOf: modelURL(named: "Pangolin 2")))
        let library = try #require(current.entitiesByName["Library"])

        #expect(library.attributesByName["libraryPath"] == nil)
        #expect(library.attributesByName["maxLocalVideoCacheBytes"] == nil)
        #expect(!(current.entitiesByName["Video"]?.indexes.isEmpty ?? true))
        #expect(!(current.entitiesByName["Folder"]?.indexes.isEmpty ?? true))
    }

    @Test("A store written with the original model opens with the current one and keeps its data")
    @MainActor
    func originalStoreMigratesInPlace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinModelMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = CoreDataStack.storeURL(forLibraryAt: directory)

        // Write a store with the original (version 1) model, including the fields that are going away.
        let original = try #require(NSManagedObjectModel(contentsOf: modelURL(named: "Pangolin")))
        #expect(original.entitiesByName["Library"]?.attributesByName["libraryPath"] != nil)

        let videoID = UUID()
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: original)
            let store = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: nil
            )
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            try context.performAndWait {
                let library = NSEntityDescription.insertNewObject(forEntityName: "Library", into: context)
                library.setValue(UUID(), forKey: "id")
                library.setValue("Migrated Library", forKey: "name")
                library.setValue("/old/mac/path", forKey: "libraryPath")
                library.setValue(Int64(5_000_000_000), forKey: "maxLocalVideoCacheBytes")

                let video = NSEntityDescription.insertNewObject(forEntityName: "Video", into: context)
                video.setValue(videoID, forKey: "id")
                video.setValue("Kept Video", forKey: "title")
                video.setValue(library, forKey: "library")
                try context.save()
            }
            try coordinator.remove(store)
        }

        // Open it the way the app does. Core Data must migrate it without help.
        let stack = try await CoreDataStack.getInstance(for: directory)
        defer { CoreDataStack.releaseInstance(for: directory) }

        let context = try #require(stack.viewContext)
        let libraries = try context.fetch(Library.fetchRequest())
        #expect(libraries.count == 1)
        #expect(libraries.first?.name == "Migrated Library")

        let videoRequest = Video.fetchRequest()
        videoRequest.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
        let videos = try context.fetch(videoRequest)
        #expect(videos.first?.title == "Kept Video")
        #expect(videos.first?.library?.name == "Migrated Library")

        let migratedModel = try #require(context.persistentStoreCoordinator?.managedObjectModel)
        #expect(migratedModel.entitiesByName["Library"]?.attributesByName["libraryPath"] == nil)
    }

    @Test("Library.url follows the loaded location and the cache limit is a per-device preference")
    @MainActor
    func perDeviceValuesAreNotStored() async throws {
        let manager = LibraryManager.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinPerDevice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try await manager.loadLibrary(at: directory)

        #expect(library.url == directory)
        #expect(library.maxLocalVideoCacheBytes == Library.defaultMaxLocalVideoCacheBytes)

        library.maxLocalCacheGB = 3
        #expect(library.maxLocalVideoCacheBytes == 3 * 1024 * 1024 * 1024)
        #expect(!library.changedValues().keys.contains("maxLocalVideoCacheBytes"))

        if let id = library.id {
            UserDefaults.standard.removeObject(forKey: "maxLocalVideoCacheBytes.\(id.uuidString)")
        }
        await manager.closeCurrentLibrary()
    }
}
