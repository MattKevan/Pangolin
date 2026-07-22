// CoreData/CoreDataStack.swift
import Foundation
import CoreData
import CloudKit

/// Singleton Core Data stack that ensures only one instance per database
/// Cloud-backed Core Data stack for Pangolin libraries
class CoreDataStack {
    private let modelName = "Pangolin"
    private let libraryURL: URL
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    let cloudEventSourceID = UUID()

    static let persistentStoreFileProtectionOptionValue =
        FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    
    // MARK: - Singleton Management
    private static var instances: [String: CoreDataStack] = [:]
    private static let instanceQueue = DispatchQueue(label: "com.pangolin.coredata.instances", attributes: .concurrent)
    
    /// Get or create a CoreDataStack instance for the given library URL
    /// This ensures only one stack per database file, preventing corruption
    static func getInstance(for libraryURL: URL) async throws -> CoreDataStack {
        let key = libraryURL.path

        if let existing = instanceQueue.sync(execute: { instances[key] }) {
            print("✅ STACK: Reusing existing CoreDataStack for \(key)")
            try await existing.loadPersistentContainerIfNeeded()
            return existing
        }

        print("🆕 STACK: Creating new CoreDataStack for \(key)")
        let stack = CoreDataStack(libraryURL: libraryURL)
        try await stack.loadPersistentContainerIfNeeded()

        var resolvedStack: CoreDataStack?
        instanceQueue.sync(flags: .barrier) {
            if let existing = instances[key] {
                resolvedStack = existing
            } else {
                instances[key] = stack
                resolvedStack = stack
            }
        }
        return resolvedStack ?? stack
    }
    
    /// Release a CoreDataStack instance for the given library URL
    static func releaseInstance(for libraryURL: URL) {
        let key = libraryURL.path
        let stack = instanceQueue.sync(flags: .barrier) {
            instances.removeValue(forKey: key)
        }
        if let stack {
            print("🗑️ STACK: Releasing CoreDataStack for \(key)")
            stack.cleanup()
        }
    }
    
    // MARK: - Core Data Properties
    private var _persistentContainer: NSPersistentCloudKitContainer?
    private var cloudEventObserver: NSObjectProtocol?
    private let containerQueue = DispatchQueue(label: "com.pangolin.coredata.container")
    
    var viewContext: NSManagedObjectContext? {
        return containerQueue.sync {
            _persistentContainer?.viewContext
        }
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
    private func loadPersistentContainerIfNeeded() async throws {
        if _persistentContainer != nil {
            return
        }

        let container = try await createPersistentContainer()
        await MainActor.run {
            _persistentContainer = container
        }
    }

    private func createPersistentContainer() async throws -> NSPersistentCloudKitContainer {
        print("🏗️ STACK: Creating NSPersistentCloudKitContainer...")

        let container = NSPersistentCloudKitContainer(name: modelName)
        
        // Set up database file location
        let storeURL = libraryURL.appendingPathComponent("Library.sqlite")
        print("📍 STACK: Database location: \(storeURL.path)")
        
        let storeDescription = createStoreDescription(for: storeURL)
        container.persistentStoreDescriptions = [storeDescription]
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { (storeDescription, error) in
                if let error = error as NSError? {
                    print("❌ STACK: Core Data load error: \(error), \(error.userInfo)")
                    
                    // Handle database corruption with proper recovery
                    if error.code == 11 || error.domain == NSSQLiteErrorDomain && error.code == 11 {
                        print("🔧 STACK: Database corruption detected - attempting recovery...")
                        do {
                            guard let storeURL = storeDescription.url else {
                                continuation.resume(throwing: CoreDataStackError.persistentStoreURLMissing)
                                return
                            }
                            try CoreDataStack.handleDatabaseCorruptionStatic(storeURL: storeURL)
                        } catch {
                            print("❌ STACK: Recovery failed: \(error)")
                            continuation.resume(throwing: error)
                            return
                        }
                    }
                    continuation.resume(throwing: CoreDataStackError.loadPersistentStoreFailed(error))
                } else {
                    print("✅ STACK: Persistent store loaded successfully")
                    continuation.resume()
                }
            }
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
        storeDescription.setOption(
            Self.persistentStoreFileProtectionOptionValue as NSString,
            forKey: NSPersistentStoreFileProtectionKey
        )
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
        let sourceID = cloudEventSourceID
        cloudEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else {
                return
            }

            Task { @MainActor in
                ProcessingQueueManager.shared.handleCloudKitEvent(event, sourceID: sourceID)
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

        // Do not pin the view context to a query generation. A long-lived pinned
        // reader prevents SQLite from truncating its WAL while CloudKit writes.
        print("✅ STACK: View context configured for automatic merging")
    }

    // MARK: - Query Generation Management

    /// Makes any queued context changes observable without retaining a WAL snapshot.
    func refreshViewContextIfNeeded() {
        guard let context = viewContext else { return }
        context.processPendingChanges()
    }

    
    // MARK: - Context Operations
    func saveContext() throws {
        guard let context = viewContext else {
            throw CoreDataStackError.containerNotInitialized
        }
        
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
        let container = try containerQueue.sync { () throws -> NSPersistentCloudKitContainer in
            guard let container = _persistentContainer else {
                throw CoreDataStackError.containerNotInitialized
            }
            return container
        }

        return try await withCheckedThrowingContinuation { continuation in
            container.performBackgroundTask { context in
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
    private static func handleDatabaseCorruptionStatic(storeURL: URL) throws {
        print("🔧 STACK: Attempting database corruption recovery...")
        
        let fileManager = FileManager.default
        let backupURL = storeURL.appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970))")
        
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

enum CoreDataStackError: LocalizedError {
    case loadPersistentStoreFailed(Error)
    case persistentStoreURLMissing
    case containerNotInitialized

    var errorDescription: String? {
        switch self {
        case .loadPersistentStoreFailed(let error):
            return "Failed to load persistent store: \(error.localizedDescription)"
        case .persistentStoreURLMissing:
            return "Persistent store URL is missing."
        case .containerNotInitialized:
            return "Core Data container is not initialized."
        }
    }
}
