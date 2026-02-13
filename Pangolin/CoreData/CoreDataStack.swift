// CoreData/CoreDataStack.swift
import Foundation
import CoreData
import CloudKit

/// Singleton Core Data stack that ensures only one instance per database
/// Cloud-backed Core Data stack for .pangolin library packages
class CoreDataStack {
    private let modelName = "Pangolin"
    private let libraryURL: URL
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    
    // MARK: - Singleton Management
    private static var instances: [String: CoreDataStack] = [:]
    private static let instanceQueue = DispatchQueue(label: "com.pangolin.coredata.instances", attributes: .concurrent)
    
    /// Get or create a CoreDataStack instance for the given library URL
    /// This ensures only one stack per database file, preventing corruption
    static func getInstance(for libraryURL: URL) throws -> CoreDataStack {
        let key = libraryURL.path
        
        return instanceQueue.sync {
            if let existing = instances[key] {
                print("✅ STACK: Reusing existing CoreDataStack for \(key)")
                return existing
            }
            
            print("🆕 STACK: Creating new CoreDataStack for \(key)")
            let stack = CoreDataStack(libraryURL: libraryURL)
            instances[key] = stack
            return stack
        }
    }
    
    /// Release a CoreDataStack instance for the given library URL
    static func releaseInstance(for libraryURL: URL) {
        let key = libraryURL.path
        instanceQueue.async(flags: .barrier) {
            if let stack = instances[key] {
                print("🗑️ STACK: Releasing CoreDataStack for \(key)")
                stack.cleanup()
                instances[key] = nil
            }
        }
    }
    
    // MARK: - Core Data Properties
    private var _persistentContainer: NSPersistentCloudKitContainer?
    private var cloudEventObserver: NSObjectProtocol?
    private let containerQueue = DispatchQueue(label: "com.pangolin.coredata.container")

    lazy var persistentContainer: NSPersistentCloudKitContainer = {
        return containerQueue.sync {
            if let existing = _persistentContainer {
                return existing
            }

            let container = createPersistentContainer()
            _persistentContainer = container
            return container
        }
    }()
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    // MARK: - Initialization
    private init(libraryURL: URL) {
        self.libraryURL = libraryURL
        print("🏗️ STACK: Initialized CoreDataStack for \(libraryURL.path)")
    }
    
    deinit {
        print("♻️ STACK: CoreDataStack deallocated")
        cleanup()
    }
    
    // MARK: - Container Creation
    private func createPersistentContainer() -> NSPersistentCloudKitContainer {
        print("🏗️ STACK: Creating NSPersistentCloudKitContainer...")

        let container = NSPersistentCloudKitContainer(name: modelName)
        
        // Set up database file location
        let storeURL = libraryURL.appendingPathComponent("Library.sqlite")
        print("📍 STACK: Database location: \(storeURL.path)")
        
        let storeDescription = createStoreDescription(for: storeURL)
        container.persistentStoreDescriptions = [storeDescription]
        
        // Use semaphore to ensure synchronous loading
        let semaphore = DispatchSemaphore(value: 0)
        var loadError: Error?
        
        container.loadPersistentStores { (storeDescription, error) in
            defer { semaphore.signal() }
            
            if let error = error as NSError? {
                print("❌ STACK: Core Data load error: \(error), \(error.userInfo)")
                loadError = error
                
                // Handle database corruption with proper recovery
                if error.code == 11 || error.domain == NSSQLiteErrorDomain && error.code == 11 {
                    print("🔧 STACK: Database corruption detected - attempting recovery...")
                    do {
                        try self.handleDatabaseCorruption(storeURL: storeDescription.url!)
                    } catch {
                        print("❌ STACK: Recovery failed: \(error)")
                        loadError = error
                    }
                }
            } else {
                print("✅ STACK: Persistent store loaded successfully")
            }
        }
        
        semaphore.wait()
        
        if let loadError = loadError {
            fatalError("Failed to load Core Data stack: \(loadError)")
        }
        
        // Configure view context
        configureViewContext(container.viewContext)

        registerCloudEventObserver(for: container)

        print("✅ STACK: Core Data container configured for CloudKit sync")
        
        return container
    }
    
    private func createStoreDescription(for storeURL: URL) -> NSPersistentStoreDescription {
        let storeDescription = NSPersistentStoreDescription(url: storeURL)

        // CRITICAL: Core Data best practices
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true

        // Enable WAL mode for query generation support and better concurrency
        storeDescription.setOption("WAL" as NSString, forKey: "journal_mode")

        // Enable file protection for better security (iOS only)
        #if os(iOS)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreFileProtectionKey)
        #endif

        // Enable persistent history tracking for better data integrity
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        // CloudKit metadata sync
        storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerIdentifier)

        // Additional options for better stability
        storeDescription.setOption(10000 as NSNumber, forKey: "busy_timeout")

        print("📦 STACK: Core Data store configured with WAL mode + CloudKit container \(cloudContainerIdentifier)")
        return storeDescription
    }

    private func registerCloudEventObserver(for container: NSPersistentCloudKitContainer) {
        cloudEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else {
                return
            }

            if let error = event.error {
                print("☁️ STACK: CloudKit event \(event.type) failed: \(error.localizedDescription)")
            } else {
                print("☁️ STACK: CloudKit event \(event.type) completed")
            }
        }
    }
    
    private func configureViewContext(_ context: NSManagedObjectContext) {
        // Configure merge policy to handle conflicts properly
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

        // Try to pin to query generation, but handle gracefully if it fails
        do {
            try context.setQueryGenerationFrom(.current)
            print("✅ STACK: View context pinned to current query generation")
        } catch let error as NSError {
            print("⚠️ STACK: Query generation not supported, using automatic merging: \(error)")

            // For SQLite error 769 (SQLITE_SNAPSHOT_STALE), we need different handling
            if error.domain == NSSQLiteErrorDomain && error.code == 769 {
                print("📝 STACK: Snapshot stale error detected - using context refresh strategy")
                // Don't pin to query generation, rely on automatic merging instead
            } else {
                print("📝 STACK: Other query generation error - fallback to automatic merging")
            }
        }

        print("✅ STACK: View context configured with fallback handling")
    }

    // MARK: - Query Generation Management

    /// Refreshes the view context when query generation fails
    func refreshViewContextIfNeeded() {
        let context = viewContext

        // Try to advance to the latest query generation
        do {
            try context.setQueryGenerationFrom(.current)
            print("✅ STACK: Successfully advanced to current query generation")
        } catch let error as NSError {
            print("🔄 STACK: Query generation failed, refreshing context objects: \(error)")

            // Fallback: refresh all objects to get latest data
            context.refreshAllObjects()

            // Also try to reset and re-pin if possible
            do {
                context.reset()
                try context.setQueryGenerationFrom(.current)
                print("✅ STACK: Successfully reset and re-pinned context")
            } catch {
                print("⚠️ STACK: Could not re-pin after reset, continuing with automatic merging")
            }
        }
    }

    
    // MARK: - Context Operations
    func saveContext() throws {
        let context = persistentContainer.viewContext
        
        guard context.hasChanges else {
            print("ℹ️ STACK: No changes to save")
            return
        }
        
        print("💾 STACK: Saving context with \(context.insertedObjects.count) insertions, \(context.updatedObjects.count) updates, \(context.deletedObjects.count) deletions")
        
        do {
            try context.save()
            print("✅ STACK: Context saved successfully")
        } catch {
            print("❌ STACK: Save failed: \(error)")
            context.rollback()
            throw error
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
    private func handleDatabaseCorruption(storeURL: URL) throws {
        print("🔧 STACK: Attempting database corruption recovery...")
        
        let fileManager = FileManager.default
        let backupURL = storeURL.appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970))")
        
        // Stop any ongoing operations
        if _persistentContainer != nil {
            // Give operations time to finish
            Thread.sleep(forTimeInterval: 1.0)
        }
        
        // Create backup of corrupted database
        if fileManager.fileExists(atPath: storeURL.path) {
            try fileManager.moveItem(at: storeURL, to: backupURL)
            print("✅ STACK: Corrupted database backed up to \(backupURL.lastPathComponent)")
        }
        
        // Remove WAL and SHM files
        let walURL = storeURL.appendingPathExtension("sqlite-wal")
        let shmURL = storeURL.appendingPathExtension("sqlite-shm")
        
        [walURL, shmURL].forEach { url in
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        
        print("✅ STACK: Database recovery prepared - new database will be created on next load")
    }
    
    // MARK: - Cleanup
    private func cleanup() {
        print("🧹 STACK: Cleaning up CoreDataStack...")

        if let cloudEventObserver {
            NotificationCenter.default.removeObserver(cloudEventObserver)
            self.cloudEventObserver = nil
        }

        // Clear container reference
        containerQueue.sync {
            _persistentContainer = nil
        }

        print("✅ STACK: CoreDataStack cleanup complete")
    }
}
