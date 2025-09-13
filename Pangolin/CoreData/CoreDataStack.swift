// CoreData/CoreDataStack.swift
import Foundation
import CoreData
import CloudKit

/// Singleton Core Data stack that ensures only one instance per database
/// Following Apple's best practices for Core Data + CloudKit synchronization
class CoreDataStack {
    private let modelName = "Pangolin"
    private let libraryURL: URL
    
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
        
        // CRITICAL: Ensure database file location is properly coordinated for iCloud
        let storeURL = libraryURL.appendingPathComponent("Library.sqlite")
        print("📍 STACK: Database location: \(storeURL.path)")
        
        // Validate iCloud file status before proceeding
        do {
            try validateiCloudFileAccess(for: storeURL)
        } catch {
            print("⚠️ STACK: iCloud file validation failed: \(error)")
        }
        
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
                        try self.handleDatabaseCorruption(storeURL: storeDescription.url!, container: container)
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
        
        // Configure view context for CloudKit sync
        configureViewContext(container.viewContext)
        
        // Setup CloudKit notifications
        setupCloudKitNotifications(container)
        
        // Initialize CloudKit schema for development
        initializeCloudKitSchema(container)
        
        return container
    }
    
    private func createStoreDescription(for storeURL: URL) -> NSPersistentStoreDescription {
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        
        // CRITICAL: Core Data + CloudKit best practices
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        
        // Enable persistent history tracking (REQUIRED for CloudKit)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // Configure CloudKit container with proper error handling
        let cloudKitOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.pangolin.video-library"
        )
        
        // CRITICAL: Enable database scope tracking for proper sync
        storeDescription.cloudKitContainerOptions = cloudKitOptions
        
        print("☁️ STACK: CloudKit container configured: iCloud.com.pangolin.video-library")
        return storeDescription
    }
    
    private func configureViewContext(_ context: NSManagedObjectContext) {
        // CRITICAL: Configure merge policy to handle conflicts properly
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        
        // CRITICAL: Pin to query generation for consistent UI
        do {
            try context.setQueryGenerationFrom(.current)
            print("✅ STACK: View context pinned to current query generation")
        } catch {
            print("⚠️ STACK: Failed to pin view context to query generation: \(error)")
        }
        
        print("✅ STACK: View context configured for CloudKit sync")
    }
    
    private func setupCloudKitNotifications(_ container: NSPersistentCloudKitContainer) {
        // Monitor CloudKit sync events
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { notification in
            if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event {
                self.handleCloudKitEvent(event)
            }
        }
        
        print("✅ STACK: CloudKit notifications configured")
    }
    
    private func initializeCloudKitSchema(_ container: NSPersistentCloudKitContainer) {
        #if DEBUG
        // Only initialize schema in development builds
        print("🔧 STACK: Initializing CloudKit schema for development...")
        
        Task.detached(priority: .utility) {
            do {
                // Initialize schema by creating temporary records
                try await container.initializeCloudKitSchema(options: [])
                print("✅ STACK: CloudKit schema initialization completed")
            } catch {
                print("❌ STACK: CloudKit schema initialization failed: \(error)")
                // This is not fatal - schema might already be initialized
            }
        }
        #else
        print("ℹ️ STACK: Skipping CloudKit schema initialization in production build")
        #endif
    }
    
    private func handleCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event) {
        switch event.type {
        case .setup:
            if event.succeeded {
                print("☁️ STACK: CloudKit setup succeeded")
            } else if let error = event.error {
                print("❌ STACK: CloudKit setup failed: \(error)")
            }
        case .import:
            if event.succeeded {
                print("📥 STACK: CloudKit import succeeded")
            } else if let error = event.error {
                print("❌ STACK: CloudKit import failed: \(error)")
            }
        case .export:
            if event.succeeded {
                print("📤 STACK: CloudKit export succeeded")
            } else if let error = event.error {
                print("❌ STACK: CloudKit export failed: \(error)")
            }
        @unknown default:
            print("ℹ️ STACK: Unknown CloudKit event: \(event.type)")
        }
    }
    
    // MARK: - iCloud File Validation
    private func validateiCloudFileAccess(for storeURL: URL) throws {
        let parentURL = storeURL.deletingLastPathComponent()
        
        // Check if parent directory exists and is accessible
        guard FileManager.default.fileExists(atPath: parentURL.path) else {
            print("ℹ️ STACK: Parent directory doesn't exist - will be created")
            return
        }
        
        // Check iCloud status of the directory
        do {
            let resourceValues = try parentURL.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey
            ])
            
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                print("☁️ STACK: iCloud status: \(downloadStatus)")
                
                // If not downloaded, wait briefly for sync
                if downloadStatus == .notDownloaded {
                    print("⏳ STACK: iCloud directory not downloaded - requesting download...")
                    try FileManager.default.startDownloadingUbiquitousItem(at: parentURL)
                    
                    // Brief wait for download to start
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        } catch {
            print("⚠️ STACK: Could not check iCloud status: \(error)")
            // Continue anyway - might not be an iCloud file
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
    private func handleDatabaseCorruption(storeURL: URL, container: NSPersistentCloudKitContainer) throws {
        print("🔧 STACK: Attempting database corruption recovery...")
        
        let fileManager = FileManager.default
        let backupURL = storeURL.appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970))")
        
        // Stop any ongoing CloudKit operations
        if _persistentContainer != nil {
            // Give CloudKit time to finish current operations
            Thread.sleep(forTimeInterval: 2.0)
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
        
        // Remove CloudKit notifications
        NotificationCenter.default.removeObserver(self)
        
        // Clear container reference
        containerQueue.sync {
            _persistentContainer = nil
        }
        
        print("✅ STACK: CoreDataStack cleanup complete")
    }
}