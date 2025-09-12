// CoreData/CoreDataStack.swift
import Foundation
import CoreData
import CloudKit
import AVFoundation

class CoreDataStack {
    private let modelName = "Pangolin"
    private let libraryURL: URL
    
    lazy var persistentContainer: NSPersistentCloudKitContainer = {
        let container = NSPersistentCloudKitContainer(name: "Pangolin")
        
        // Configure for library-specific storage
        let storeURL = libraryURL.appendingPathComponent("Library.sqlite")
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        
        // CloudKit Configuration
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // Configure CloudKit container
        storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.pangolin.video-library"
        )
        
        container.persistentStoreDescriptions = [storeDescription]
        
        container.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                print("Core Data error: \(error), \(error.userInfo)")
                
                // Handle database corruption specifically
                if error.code == 11 { // SQLite corruption
                    print("❌ Database corruption detected. Attempting recovery...")
                    self.handleDatabaseCorruption(storeURL: storeDescription.url!, container: container)
                } else {
                    fatalError("Unresolved error \(error), \(error.userInfo)")
                }
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        return container
    }()
    
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
    }
    
    func saveContext() throws {
        let context = persistentContainer.viewContext
        
        if context.hasChanges {
            try context.save()
        }
    }
    
    func performBackgroundTask<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            persistentContainer.performBackgroundTask { context in
                do {
                    let result = try block(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Database Recovery
    
    private func handleDatabaseCorruption(storeURL: URL, container: NSPersistentCloudKitContainer) {
        print("🔧 Attempting database recovery...")
        
        let fileManager = FileManager.default
        let backupURL = storeURL.appendingPathExtension("backup")
        
        do {
            // Create backup of corrupted database
            if fileManager.fileExists(atPath: storeURL.path) {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.moveItem(at: storeURL, to: backupURL)
                print("✅ Corrupted database backed up")
            }
            
            // Remove related files (WAL, SHM)
            let walURL = storeURL.appendingPathExtension("sqlite-wal")
            let shmURL = storeURL.appendingPathExtension("sqlite-shm")
            
            if fileManager.fileExists(atPath: walURL.path) {
                try fileManager.removeItem(at: walURL)
            }
            if fileManager.fileExists(atPath: shmURL.path) {
                try fileManager.removeItem(at: shmURL)
            }
            
            print("✅ Database recovery complete - new database will be created")
            
            // Retry loading the store
            container.loadPersistentStores { (_, retryError) in
                if let retryError = retryError {
                    print("❌ Recovery failed: \(retryError)")
                    fatalError("Failed to recover from database corruption: \(retryError)")
                } else {
                    print("✅ New database created successfully")
                }
            }
            
        } catch {
            print("❌ Database recovery failed: \(error)")
            fatalError("Database recovery failed: \(error)")
        }
    }
}
