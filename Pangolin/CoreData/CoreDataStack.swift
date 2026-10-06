import os
// CoreData/CoreDataStack.swift
import Foundation
import CoreData
import CloudKit

/// Singleton Core Data stack that ensures only one instance per database
/// Cloud-backed Core Data stack for Pangolin libraries
@MainActor
final class CoreDataStack {
    private let modelName = "Pangolin"
    private let libraryURL: URL
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    let cloudEventSourceID = UUID()

    /// Tags writes made by this app in persistent history so they can be told apart from CloudKit imports.
    nonisolated static let transactionAuthor = "pangolin-app"

    /// CloudKit mirroring needs the iCloud entitlement, which unit-test hosts don't have;
    /// without it Core Data traps on the first store load. Tests get a plain local store.
    nonisolated(unsafe) static var isCloudSyncEnabled =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    nonisolated static let persistentStoreFileProtectionOptionValue =
        FileProtectionType.completeUntilFirstUserAuthentication.rawValue

    // MARK: - Singleton Management
    private static var instances: [String: CoreDataStack] = [:]
    private static var loadingTasks: [String: Task<CoreDataStack, Error>] = [:]

    /// Get or create a CoreDataStack instance for the given library URL.
    /// Concurrent callers for the same path share one load, so only one container
    /// ever opens a given database file.
    static func getInstance(for libraryURL: URL) async throws -> CoreDataStack {
        let key = libraryURL.path

        if let existing = instances[key] {
            Logger.coredata.info("STACK: Reusing existing CoreDataStack for \(key)")
            return existing
        }

        if let loading = loadingTasks[key] {
            Logger.coredata.info("STACK: Awaiting in-flight CoreDataStack load for \(key)")
            return try await loading.value
        }

        Logger.coredata.info("STACK: Creating new CoreDataStack for \(key)")
        let task = Task { () throws -> CoreDataStack in
            let stack = CoreDataStack(libraryURL: libraryURL)
            try await stack.loadPersistentContainer()
            return stack
        }
        loadingTasks[key] = task
        defer { loadingTasks[key] = nil }

        let stack = try await task.value
        instances[key] = stack
        return stack
    }

    /// Release a CoreDataStack instance for the given library URL
    static func releaseInstance(for libraryURL: URL) {
        let key = libraryURL.path
        if let stack = instances.removeValue(forKey: key) {
            Logger.coredata.info("STACK: Releasing CoreDataStack for \(key)")
            stack.cleanup()
        }
    }

    // MARK: - Core Data Properties
    private var persistentContainer: NSPersistentCloudKitContainer?
    // Read from the nonisolated deinit, which only runs once nothing else can touch the stack.
    nonisolated(unsafe) private var cloudEventObserver: NSObjectProtocol?

    var viewContext: NSManagedObjectContext? {
        persistentContainer?.viewContext
    }

    // MARK: - Initialization
    private init(libraryURL: URL) {
        self.libraryURL = libraryURL
        Logger.coredata.info("STACK: Initialized CoreDataStack for \(libraryURL.path)")
    }

    deinit {
        Logger.coredata.info("STACK: CoreDataStack deallocated")
        if let cloudEventObserver {
            NotificationCenter.default.removeObserver(cloudEventObserver)
        }
    }

    // MARK: - Container Creation
    private func loadPersistentContainer() async throws {
        persistentContainer = try await createPersistentContainer()
    }

    private func createPersistentContainer() async throws -> NSPersistentCloudKitContainer {
        Logger.coredata.info("STACK: Creating NSPersistentCloudKitContainer...")

        let storeURL = libraryURL.appendingPathComponent("Library.sqlite")
        Logger.coredata.info("STACK: Database location: \(storeURL.path)")

        var container = makeContainer(storeURL: storeURL)

        do {
            try await loadStores(of: container)
        } catch let error as NSError where Self.isStoreCorruption(error) {
            Logger.coredata.error("STACK: Database corruption detected: \(error), \(error.userInfo)")
            try Self.moveCorruptedStoreAside(storeURL: storeURL)

            // A container that failed to load is not reused; retry once with a fresh one.
            container = makeContainer(storeURL: storeURL)
            do {
                try await loadStores(of: container)
            } catch {
                Logger.coredata.error("STACK: Reload after recovery failed: \(error)")
                throw CoreDataStackError.loadPersistentStoreFailed(error)
            }
        } catch {
            Logger.coredata.error("STACK: Core Data load error: \(error)")
            throw CoreDataStackError.loadPersistentStoreFailed(error)
        }

        Logger.coredata.info("STACK: Persistent store loaded successfully")

        configureViewContext(container.viewContext)
        registerCloudEventObserver(for: container)

        Logger.coredata.info("STACK: Core Data container configured for CloudKit sync")

        return container
    }

    private func makeContainer(storeURL: URL) -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(name: modelName)
        container.persistentStoreDescriptions = [createStoreDescription(for: storeURL)]
        return container
    }

    private func loadStores(of container: NSPersistentCloudKitContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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

        if Self.isCloudSyncEnabled {
            storeDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerIdentifier)
        }

        // Additional options for better stability
        storeDescription.setOption(10000 as NSNumber, forKey: "busy_timeout")

        Logger.coredata.info("STACK: Core Data store configured with WAL mode, CloudKit sync \(Self.isCloudSyncEnabled ? "on" : "off")")
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
                Logger.coredata.info("STACK: CloudKit event \(String(describing: event.type)) failed: \(error.localizedDescription)")
            } else {
                Logger.coredata.info("STACK: CloudKit event \(String(describing: event.type)) completed")
            }
        }
    }
    
    private func configureViewContext(_ context: NSManagedObjectContext) {
        // This context is the app's editing context (imports, renames, and
        // state writes land here before save), so the in-memory object must
        // trump incoming CloudKit merges. Store-trump would silently overwrite
        // a user's unsaved edit with the server value on the next merge, and
        // the following save would persist it — silent edit loss.
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.transactionAuthor = Self.transactionAuthor

        // Do not pin the view context to a query generation. A long-lived pinned
        // reader prevents SQLite from truncating its WAL while CloudKit writes.
        Logger.coredata.info("STACK: View context configured for automatic merging")
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
            Logger.coredata.info("STACK: No changes to save")
            return
        }
        
        Logger.coredata.info("STACK: Saving context with \(context.insertedObjects.count) insertions, \(context.updatedObjects.count) updates, \(context.deletedObjects.count) deletions")
        
        do {
            try context.save()
            Logger.coredata.info("STACK: Context saved successfully")
        } catch {
            Logger.coredata.error("STACK: Save failed: \(error)")
            context.rollback()
            throw error
        }
    }
    
    func performBackgroundTask<T: Sendable>(
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        guard let container = persistentContainer else {
            throw CoreDataStackError.containerNotInitialized
        }

        return try await withCheckedThrowingContinuation { continuation in
            container.performBackgroundTask { context in
                context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
                context.transactionAuthor = Self.transactionAuthor
                do {
                    continuation.resume(returning: try block(context))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Database Recovery

    /// SQLITE_CORRUPT (11) and SQLITE_NOTADB (26), on the error or anything it wraps.
    nonisolated private static func isStoreCorruption(_ error: NSError) -> Bool {
        if error.domain == NSSQLiteErrorDomain, error.code == 11 || error.code == 26 {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isStoreCorruption(underlying)
        }
        return false
    }

    /// Moves the database and its WAL/SHM sidecars aside together, so a stale WAL
    /// is never replayed onto the fresh database. The backup is kept for inspection.
    nonisolated private static func moveCorruptedStoreAside(storeURL: URL) throws {
        Logger.coredata.warning("STACK: Moving corrupted database aside...")

        let fileManager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let backup = URL(fileURLWithPath: source.path + ".corrupted-\(stamp)")
            try fileManager.moveItem(at: source, to: backup)
            Logger.coredata.info("STACK: Backed up \(source.lastPathComponent) to \(backup.lastPathComponent)")
        }
    }

    // MARK: - Cleanup
    private func cleanup() {
        Logger.coredata.info("STACK: Cleaning up CoreDataStack...")

        if let cloudEventObserver {
            NotificationCenter.default.removeObserver(cloudEventObserver)
            self.cloudEventObserver = nil
        }

        persistentContainer = nil

        Logger.coredata.info("STACK: CoreDataStack cleanup complete")
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
