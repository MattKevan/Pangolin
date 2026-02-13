//
//  LibraryManager.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import Foundation
import CoreData
import Combine
import SQLite3

// MARK: - Library Manager
@MainActor
class LibraryManager: ObservableObject {
    static let shared = LibraryManager()
    
    // MARK: - Published Properties
    @Published var currentLibrary: Library?
    @Published var isLibraryOpen = false
    @Published var recentLibraries: [LibraryDescriptor] = []
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0
    @Published var error: LibraryError?
    
    // MARK: - Private Properties
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var coreDataStack: CoreDataStack?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Constants
    private let libraryExtension = "pangolin"
    private let currentVersion = "1.0.0"
    private let recentLibrariesKey = "RecentLibraries"
    private let lastOpenedLibraryKey = "LastOpenedLibrary"
    
    // MARK: - Initialization
    private init() {
        loadRecentLibraries()
    }
    
    // MARK: - Public Properties
    
    /// Access to the current Core Data context
    var viewContext: NSManagedObjectContext? {
        return coreDataStack?.viewContext
    }
    
    /// Access to the current Core Data stack for sync engine
    var currentCoreDataStack: CoreDataStack? {
        return coreDataStack
    }
    
    // MARK: - Public Methods
    
    /// Saves the current library's data context if there are changes.
    func save() async {
        print("💽 LIBRARY: save() called")
        
        guard let context = self.viewContext else {
            print("❌ LIBRARY: No viewContext available")
            return
        }
        
        print("📊 LIBRARY: Context hasChanges: \(context.hasChanges)")
        print("📊 LIBRARY: Context insertedObjects count: \(context.insertedObjects.count)")
        print("📊 LIBRARY: Context updatedObjects count: \(context.updatedObjects.count)")
        print("📊 LIBRARY: Context deletedObjects count: \(context.deletedObjects.count)")
        
        // Log details about updated objects
        for obj in context.updatedObjects {
            print("📝 LIBRARY: Updated object: \(obj)")
            if let folder = obj as? Folder {
                print("📁 LIBRARY: Updated folder: '\(folder.name ?? "nil")' (ID: \(folder.id?.uuidString ?? "nil"))")
            } else if let video = obj as? Video {
                print("🎥 LIBRARY: Updated video: '\(video.title ?? "nil")' (ID: \(video.id?.uuidString ?? "nil"))")
            }
        }
        
        guard context.hasChanges else {
            print("ℹ️ LIBRARY: No changes to save")
            return
        }
        
        do {
            print("💾 LIBRARY: Attempting context.save()...")
            try context.save()
            print("✅ LIBRARY: Save successful!")
            
            // Verify that changes were actually saved by re-fetching
            print("🔄 LIBRARY: Verifying save by checking context state...")
            print("📊 LIBRARY: After save - hasChanges: \(context.hasChanges)")
            print("📊 LIBRARY: After save - updatedObjects count: \(context.updatedObjects.count)")
            
        } catch {
            print("💥 LIBRARY: Save failed: \(error.localizedDescription)")
            self.error = .saveFailed(error)
            context.rollback()
            print("🔄 LIBRARY: Context rolled back")
        }
    }
    
    /// Create a new library at the specified URL
    func createLibrary(at url: URL, name: String) async throws -> Library {
        print("📝 CREATE_LIBRARY: Starting createLibrary...")
        print("📝 CREATE_LIBRARY: Parent URL: \(url.path)")
        print("📝 CREATE_LIBRARY: Library name: \(name)")

        isLoading = true
        loadingProgress = 0

        defer {
            isLoading = false
            loadingProgress = 0
        }

        // Create library package directory
        let libraryURL = url.appendingPathComponent("\(name).\(libraryExtension)")
        print("📝 CREATE_LIBRARY: Full library URL: \(libraryURL.path)")

        // Check if already exists
        if fileManager.fileExists(atPath: libraryURL.path) {
            print("❌ CREATE_LIBRARY: Library already exists at path")
            throw LibraryError.libraryAlreadyExists(libraryURL)
        }
        
        // Create directory structure
        try createLibraryStructure(at: libraryURL)
        loadingProgress = 0.3
        
        // Initialize Core Data stack using singleton pattern
        let stack = try CoreDataStack.getInstance(for: libraryURL)
        self.coreDataStack = stack
        loadingProgress = 0.6
        
        // Create library entity using NSEntityDescription
        let context = stack.viewContext
        
        // Debug: Check if the managed object model is loaded correctly
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else {
            print("ERROR: No managed object model found")
            throw LibraryError.corruptedDatabase
        }
        
        print("Available entities: \(model.entitiesByName.keys)")
        
        guard let entityDescription = model.entitiesByName["Library"] else {
            print("ERROR: Library entity not found in model")
            throw LibraryError.corruptedDatabase
        }
        
        print("Creating library entity with description: \(entityDescription)")
        let library = Library(entity: entityDescription, insertInto: context)
        
        // Verify library was created successfully
        guard library.entity == entityDescription else {
            print("ERROR: Library entity creation failed")
            throw LibraryError.corruptedDatabase
        }
        
        print("Library entity created successfully, setting properties...")
        
        library.id = UUID()
        library.name = name
        library.libraryPath = libraryURL.path
        library.createdDate = Date()
        library.lastOpenedDate = Date()
        library.version = currentVersion
        
        print("Basic properties set, setting default settings...")
        
        // Set default settings
        library.copyFilesOnImport = true
        library.organizeByDate = true
        library.autoMatchSubtitles = true
        library.defaultPlaybackSpeed = 1.0
        library.rememberPlaybackPosition = true
        
        // Set default video storage to local storage
        library.videoStorageType = "local_library"
        
        print("All properties set successfully")
        
        // Create default smart folders
        createDefaultSmartFolders(for: library, in: context)
        loadingProgress = 0.8
        
        // Save context
        try context.save()
        
        // Update current library
        self.currentLibrary = library
        self.isLibraryOpen = true
        
        print("Library created successfully: \(library.name ?? "Untitled")")
        print("Library open state: \(self.isLibraryOpen)")
        
        // Add to recent libraries
        addToRecentLibraries(library)
        
        // Save as last opened
        saveLastOpenedLibrary(libraryURL)
        
        loadingProgress = 1.0
        
        return library
    }
    
    /// Open an existing library
    func openLibrary(at url: URL) async throws -> Library {
        isLoading = true
        loadingProgress = 0
        
        defer {
            isLoading = false
            loadingProgress = 0
        }
        
        // Validate library
        let validation = try validateLibrary(at: url)
        guard validation.isValid else {
            throw LibraryError.invalidLibrary(validation.errors)
        }
        loadingProgress = 0.2
        
        // Close current library if open
        if currentLibrary != nil {
            await closeCurrentLibrary()
        }
        loadingProgress = 0.3
        
        // Initialize Core Data stack using singleton pattern
        let stack = try CoreDataStack.getInstance(for: url)
        self.coreDataStack = stack
        loadingProgress = 0.5
        
        // Fetch library entity
        let context = stack.viewContext
        let request = Library.fetchRequest()
        request.fetchLimit = 1
        
        guard let library = try context.fetch(request).first else {
            throw LibraryError.libraryNotFound
        }
        loadingProgress = 0.7
        
        // Check for migration needs
        if library.version! != currentVersion {
            try await migrateLibrary(library, from: library.version!, to: currentVersion)
        }
        loadingProgress = 0.8
        
        // Ensure smart folders exist
        await ensureSmartFoldersExist(for: library, in: context)
        
        // Update library
        library.lastOpenedDate = Date()
        try context.save()
        
        // Set as current
        self.currentLibrary = library
        self.isLibraryOpen = true
        
        // Update recent libraries
        addToRecentLibraries(library)
        saveLastOpenedLibrary(url)
        
        loadingProgress = 1.0
        
        // Generate thumbnails for videos that don't have them (async in background)
        Task { @MainActor in
            let request = Video.fetchRequest()
            request.predicate = NSPredicate(format: "library == %@ AND thumbnailPath == nil", library)
            let videos = (try? context.fetch(request)) ?? []
            ProcessingQueueManager.shared.enqueueThumbnails(for: videos)
        }
        
        return library
    }
    
    /// Close the current library
    func closeCurrentLibrary() async {
        guard let library = currentLibrary else { return }
        
        // Save any pending changes
        await save()
        
        // Release the CoreDataStack instance for this library
        if let libraryURL = library.url {
            CoreDataStack.releaseInstance(for: libraryURL)
        }
        
        // Clean up
        coreDataStack = nil
        currentLibrary = nil
        isLibraryOpen = false
    }
    
    /// Switch to a different library
    func switchToLibrary(_ descriptor: LibraryDescriptor) async throws {
        _ = try await openLibrary(at: descriptor.path)
    }
    
    /// Open the last used library
    func openLastLibrary() async throws {
        guard let lastLibraryPath = userDefaults.url(forKey: lastOpenedLibraryKey),
              fileManager.fileExists(atPath: lastLibraryPath.path) else {
            throw LibraryError.noLastLibrary
        }

        _ = try await openLibrary(at: lastLibraryPath)
    }
    
    /// Smart startup following Apple's performance best practices
    func smartStartup() async throws -> Library {
        print("🚀 LIBRARY: Starting smart startup...")

        // FAST PATH 1: Get real user Documents directory (not sandboxed)
        // Use NSHomeDirectory() to get the actual user home, not sandboxed version
        let realHomeDirectory = NSHomeDirectory()
        let documentsURL = URL(fileURLWithPath: realHomeDirectory).appendingPathComponent("Documents")

        print("🏠 LIBRARY: Real home directory: \(realHomeDirectory)")
        print("📁 LIBRARY: Real Documents directory: \(documentsURL.path)")

        // Verify we can access the real Documents folder
        guard fileManager.fileExists(atPath: documentsURL.path) else {
            throw LibraryError.documentsFolderUnavailable
        }

        let pangolinDirectory = documentsURL.appendingPathComponent("Pangolin")
        let libraryName = "Library"
        let libraryURL = pangolinDirectory.appendingPathComponent("\(libraryName).pangolin")

        print("📍 LIBRARY: Pangolin directory: \(pangolinDirectory.path)")
        print("📍 LIBRARY: Library path: \(libraryURL.path)")
        print("📍 LIBRARY: Library exists: \(fileManager.fileExists(atPath: libraryURL.path))")

        print("🎯 ==> LIBRARY LOCATION: \(libraryURL.path)")

        // FAST PATH 2: New user - no library folder exists
        if !fileManager.fileExists(atPath: libraryURL.path) {
            print("👤 LIBRARY: New user detected - creating fresh library")
            return try await createNewUserLibrary(at: libraryURL, name: libraryName)
        }
        
        // FAST PATH 3: Check database validity quickly
        let databaseURL = libraryURL.appendingPathComponent("Library.sqlite")
        
        let databaseExists = fileManager.fileExists(atPath: databaseURL.path)
        let databaseHealthy = databaseExists ? await isDatabaseHealthy(databaseURL) : false
        
        if databaseExists && databaseHealthy {
            print("✅ LIBRARY: Existing healthy library found - opening directly")
            return try await openExistingLibrary(at: libraryURL)
        }
        
        // PROBLEM PATH: Only now do expensive operations
        print("⚠️ LIBRARY: Database issue detected - analyzing situation...")
        return try await handleDatabaseIssue(libraryURL: libraryURL, libraryName: libraryName)
    }
    
    
    // MARK: - Smart Startup Support Methods
    
    /// Fast new user library creation
    private func createNewUserLibrary(at libraryURL: URL, name: String) async throws -> Library {
        print("🆕 LIBRARY: Creating new user library...")
        print("📍 LIBRARY: Target library URL: \(libraryURL.path)")
        print("📍 LIBRARY: Library name: \(name)")

        let pangolinDirectory = libraryURL.deletingLastPathComponent()
        print("📁 LIBRARY: Parent directory: \(pangolinDirectory.path)")

        // Create directory structure if needed
        do {
            print("🔧 LIBRARY: Creating parent directory...")
            try fileManager.createDirectory(at: pangolinDirectory, withIntermediateDirectories: true, attributes: nil)
            print("✅ LIBRARY: Parent directory created successfully")
        } catch {
            print("❌ LIBRARY: Failed to create parent directory: \(error)")
            throw error
        }

        // Create library - pass the parent directory, createLibrary will append the name
        do {
            print("🔧 LIBRARY: Calling createLibrary...")
            let newLibrary = try await createLibrary(at: pangolinDirectory, name: name)
            print("✅ LIBRARY: Library created successfully")
            return newLibrary
        } catch {
            print("❌ LIBRARY: Failed to create library: \(error)")
            throw error
        }
    }
    
    /// Fast existing library opening
    private func openExistingLibrary(at libraryURL: URL) async throws -> Library {
        return try await openLibrary(at: libraryURL)
    }
    
    /// Quick database health check (cross-platform compatible)
    private func isDatabaseHealthy(_ databaseURL: URL) async -> Bool {
        do {
            // Quick SQLite integrity check without full diagnostics
            var sqlite: OpaquePointer?
            let result = sqlite3_open_v2(databaseURL.path, &sqlite, SQLITE_OPEN_READONLY, nil)
            
            guard result == SQLITE_OK, let db = sqlite else {
                if sqlite != nil { sqlite3_close(sqlite) }
                return false
            }
            
            // Quick pragma check
            let testQuery = "PRAGMA integrity_check(1)"
            var statement: OpaquePointer?
            
            let prepareResult = sqlite3_prepare_v2(db, testQuery, -1, &statement, nil)
            if prepareResult == SQLITE_OK {
                let stepResult = sqlite3_step(statement)
                sqlite3_finalize(statement)
                sqlite3_close(db)
                return stepResult == SQLITE_ROW || stepResult == SQLITE_DONE
            } else {
                sqlite3_close(db)
                return false
            }
        } catch {
            print("⚠️ LIBRARY: Database health check failed: \(error)")
            return false
        }
    }
    
    /// Handle database corruption/missing scenarios (expensive operations)
    private func handleDatabaseIssue(libraryURL: URL, libraryName: String) async throws -> Library {
        // For simplified version, just recreate the library
        print("🔄 LIBRARY: Database issue detected - recreating library")
        return try await recreateEmptyLibrary(at: libraryURL, name: libraryName)
    }
    
    /// Scan for existing videos (only called when needed)
    private func scanExistingVideos() async -> (videoCount: Int, totalSize: Int64) {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return (0, 0)
        }

        let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "wmv"])
        var videoCount = 0
        var totalSize: Int64 = 0

        // Search common locations in Documents and other local folders
        let searchPaths = [
            documentsURL,
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
        
        for searchPath in searchPaths {
            do {
                let contents = try fileManager.contentsOfDirectory(at: searchPath, 
                                                                  includingPropertiesForKeys: [.fileSizeKey],
                                                                  options: [.skipsHiddenFiles])
                
                for fileURL in contents {
                    let fileExtension = fileURL.pathExtension.lowercased()
                    if videoExtensions.contains(fileExtension) {
                        videoCount += 1
                        
                        if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                           let fileSize = resourceValues.fileSize {
                            totalSize += Int64(fileSize)
                        }
                    }
                }
            } catch {
                // Continue searching other paths if one fails
                continue
            }
        }
        
        print("📊 LIBRARY: Video scan complete - found \(videoCount) videos (\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)))")
        return (videoCount, totalSize)
    }
    
    /// Recreate empty library
    private func recreateEmptyLibrary(at libraryURL: URL, name: String) async throws -> Library {
        // Clean up any existing broken files
        if fileManager.fileExists(atPath: libraryURL.path) {
            try fileManager.removeItem(at: libraryURL)
        }
        
        return try await createNewUserLibrary(at: libraryURL, name: name)
    }
    
    // MARK: - Library Validation
    
    struct LibraryValidation {
        let isValid: Bool
        let errors: [String]
        let isRepairable: Bool
    }
    
    func validateLibrary(at url: URL) throws -> LibraryValidation {
        var errors: [String] = []
        
        // Check if directory exists
        guard fileManager.fileExists(atPath: url.path) else {
            return LibraryValidation(isValid: false,
                                    errors: ["Library does not exist"],
                                    isRepairable: false)
        }
        
        // Check for required subdirectories (create them if missing)
        let requiredDirs = ["Videos", "Subtitles", "Thumbnails", "Transcripts", "Translations", "Summaries", "Backups"]
        for dir in requiredDirs {
            let dirPath = url.appendingPathComponent(dir)
            if !fileManager.fileExists(atPath: dirPath.path) {
                // Try to create missing directories
                do {
                    try fileManager.createDirectory(at: dirPath, withIntermediateDirectories: true)
                    print("📁 Created missing directory: \(dir)")
                } catch {
                    errors.append("Missing directory: \(dir)")
                }
            }
        }
        
        // Check for database file
        let dbPath = url.appendingPathComponent("Library.sqlite")
        if !fileManager.fileExists(atPath: dbPath.path) {
            errors.append("Database file not found")
        }
        
        // Check Info.plist (create if missing)
        let infoPlistPath = url.appendingPathComponent("Info.plist")
        if !fileManager.fileExists(atPath: infoPlistPath.path) {
            // Try to create Info.plist
            do {
                let info: [String: Any] = [
                    "Version": currentVersion,
                    "CreatedDate": Date(),
                    "BundleIdentifier": "com.pangolin.library",
                    "LibraryType": "VideoLibrary"
                ]
                let plistData = try PropertyListSerialization.data(fromPropertyList: info,
                                                                  format: .xml,
                                                                  options: 0)
                try plistData.write(to: infoPlistPath)
                print("📄 Created missing Info.plist")
            } catch {
                errors.append("Info.plist not found")
            }
        }
        
        let isValid = errors.isEmpty
        let isRepairable = !errors.contains("Database file not found")
        
        return LibraryValidation(isValid: isValid,
                                errors: errors,
                                isRepairable: isRepairable)
    }
    
    
    // MARK: - Database Recovery
    
    /// Delete corrupted database and start fresh, then reimport existing videos
    func resetCorruptedDatabase() async throws -> Library {
        print("🔧 LIBRARY: Resetting corrupted database...")

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw LibraryError.documentsFolderUnavailable
        }

        let pangolinDirectory = documentsURL.appendingPathComponent("Pangolin")
        let libraryName = "Library"
        let libraryURL = pangolinDirectory.appendingPathComponent("\(libraryName).pangolin")
        
        // If library folder exists, clean it up first
        if fileManager.fileExists(atPath: libraryURL.path) {
            print("🔧 LIBRARY: Removing existing library structure...")
            
            // Release any existing CoreDataStack instance for this library
            CoreDataStack.releaseInstance(for: libraryURL)
            
            let databaseURL = libraryURL.appendingPathComponent("Library.sqlite")
            let walURL = databaseURL.appendingPathExtension("sqlite-wal")  
            let shmURL = databaseURL.appendingPathExtension("sqlite-shm")
            
            // Remove database files if they exist
            for fileURL in [databaseURL, walURL, shmURL] {
                if fileManager.fileExists(atPath: fileURL.path) {
                    do {
                        try fileManager.removeItem(at: fileURL)
                        print("🗑️ LIBRARY: Removed \(fileURL.lastPathComponent)")
                    } catch {
                        print("⚠️ LIBRARY: Failed to remove \(fileURL.lastPathComponent): \(error)")
                    }
                }
            }
        }
        
        // Create fresh library
        print("🆕 LIBRARY: Creating fresh library...")
        let newLibrary = try await createLibrary(at: libraryURL, name: libraryName)
        
        // Open the new library to set up Core Data context
        try await openLibrary(at: libraryURL)

        print("✅ LIBRARY: Fresh library created and opened successfully")
        
        return newLibrary
    }
    
    // MARK: - Private Methods
    
    private func createLibraryStructure(at url: URL) throws {
        print("🏗️ CREATE_STRUCTURE: Creating library structure at: \(url.path)")

        // Create main directory
        do {
            print("🏗️ CREATE_STRUCTURE: Creating main directory...")
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            print("✅ CREATE_STRUCTURE: Main directory created successfully")
        } catch {
            print("❌ CREATE_STRUCTURE: Failed to create main directory: \(error)")
            throw error
        }

        // Create subdirectories - ALL content goes inside the package
        let subdirectories = [
            "Videos",        // All video files here
            "Subtitles",     // All subtitle files here
            "Thumbnails",    // All generated thumbnails here
            "Transcripts",   // All transcription files here
            "Translations",  // All translation files here
            "Summaries",     // All summary files here
            "Backups"        // Any backup data here
        ]
        print("🏗️ CREATE_STRUCTURE: Creating subdirectories: \(subdirectories)")
        for dir in subdirectories {
            let dirURL = url.appendingPathComponent(dir)
            try fileManager.createDirectory(at: dirURL,
                                          withIntermediateDirectories: true)
        }
        
        // Create Info.plist
        let info: [String: Any] = [
            "Version": currentVersion,
            "CreatedDate": Date(),
            "BundleIdentifier": "com.pangolin.library",
            "LibraryType": "VideoLibrary"
        ]
        
        let infoPlistURL = url.appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(fromPropertyList: info,
                                                          format: .xml,
                                                          options: 0)
        try plistData.write(to: infoPlistURL)
    }
    
    
    private func loadRecentLibraries() {
        if let data = userDefaults.data(forKey: recentLibrariesKey),
           let libraries = try? JSONDecoder().decode([LibraryDescriptor].self, from: data) {
            self.recentLibraries = libraries
        }
    }
    
    private func addToRecentLibraries(_ library: Library) {
        guard let url = library.url else { return }
        
        let descriptor = LibraryDescriptor(
            id: library.id!,
            name: library.name!,
            path: url,
            lastOpenedDate: library.lastOpenedDate!,
            createdDate: library.createdDate!,
            version: library.version!,
            thumbnailData: nil,
            videoCount: library.videoCount,
            totalSize: library.totalSize
        )
        
        // Remove if already exists
        recentLibraries.removeAll { $0.id == descriptor.id }
        
        // Add to front
        recentLibraries.insert(descriptor, at: 0)
        
        // Keep only last 10
        if recentLibraries.count > 10 {
            recentLibraries = Array(recentLibraries.prefix(10))
        }
        
        // Save
        if let data = try? JSONEncoder().encode(recentLibraries) {
            userDefaults.set(data, forKey: recentLibrariesKey)
        }
    }
    
    private func saveLastOpenedLibrary(_ url: URL) {
        userDefaults.set(url, forKey: lastOpenedLibraryKey)
    }
    
    private func migrateLibrary(_ library: Library, from oldVersion: String, to newVersion: String) async throws {
        // Implement migration logic here
        library.version = newVersion
    }
    
    private func createDefaultSmartFolders(for library: Library, in context: NSManagedObjectContext) {
        guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            print("Could not find Folder entity description")
            return
        }
        
        let smartFolders = [
            ("All Videos", "video.fill"),
            ("Recent", "clock.fill"),
            ("Favorites", "heart.fill")
        ]
        
        // CORRECTED: The unused 'index' variable is replaced with '_'
        for (_, folderInfo) in smartFolders.enumerated() {
            let folder = Folder(entity: folderEntityDescription, insertInto: context)
            folder.id = UUID()
            folder.name = folderInfo.0
            folder.isTopLevel = true
            folder.isSmartFolder = true
            folder.dateCreated = Date()
            folder.dateModified = Date()
            folder.library = library
        }
    }
    
    private func ensureSmartFoldersExist(for library: Library, in context: NSManagedObjectContext) async {
        // Check if smart folders already exist
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND isSmartFolder == YES", library)
        
        do {
            let existingSmartFolders = try context.fetch(request)
            let existingNames = Set(existingSmartFolders.map { $0.name })
            
            let requiredSmartFolders = ["All Videos", "Recent", "Favorites"]
            
            // Create any missing smart folders
            for folderName in requiredSmartFolders {
                if !existingNames.contains(folderName) {
                    guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
                        continue
                    }
                    
                    let folder = Folder(entity: folderEntityDescription, insertInto: context)
                    folder.id = UUID()
                    folder.name = folderName
                    folder.isTopLevel = true
                    folder.isSmartFolder = true
                    folder.dateCreated = Date()
                    folder.dateModified = Date()
                    folder.library = library
                }
            }
            
            try context.save()
        } catch {
            print("Failed to ensure smart folders exist: \(error)")
        }
    }
}

// MARK: - Library Errors
enum LibraryError: LocalizedError {
    case libraryAlreadyExists(URL)
    case libraryNotFound
    case invalidLibrary([String])
    case migrationFailed(String)
    case noLastLibrary
    case corruptedDatabase
    case databaseCorrupted(Error)
    case insufficientPermissions
    case diskSpaceInsufficient
    case saveFailed(Error)
    case documentsFolderUnavailable
    
    var errorDescription: String? {
        switch self {
        case .libraryAlreadyExists(let url):
            return "A library already exists at \(url.lastPathComponent)"
        case .libraryNotFound:
            return "Library not found"
        case .invalidLibrary(let errors):
            return "Invalid library: \(errors.joined(separator: ", "))"
        case .migrationFailed(let reason):
            return "Migration failed: \(reason)"
        case .noLastLibrary:
            return "No previously opened library found"
        case .corruptedDatabase:
            return "The library database is corrupted"
        case .databaseCorrupted(let error):
            return "Database corruption detected: \(error.localizedDescription)"
        case .insufficientPermissions:
            return "Insufficient permissions to access library"
        case .diskSpaceInsufficient:
            return "Not enough disk space available"
        case .saveFailed(let error):
            return "Failed to save the library. \(error.localizedDescription)"
        case .documentsFolderUnavailable:
            return "Documents folder is not accessible"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .libraryAlreadyExists:
            return "Choose a different location or name for your library"
        case .libraryNotFound, .noLastLibrary:
            return "Create a new library or open an existing one"
        case .invalidLibrary:
            return "Try repairing the library or create a new one"
        case .migrationFailed, .saveFailed:
            return "Please try the operation again. If the problem persists, restart the application."
        case .corruptedDatabase, .databaseCorrupted:
            return "Restore from a backup or rebuild the library"
        case .insufficientPermissions:
            return "Check file permissions and try again"
        case .diskSpaceInsufficient:
            return "Free up disk space and try again"
        case .documentsFolderUnavailable:
            return "Check file system permissions and ensure the Documents folder is accessible."
        }
    }
}

// MARK: - Text Artifact Directories & I/O

extension LibraryManager {
    private var textArtifactsDirectories: (transcripts: URL, translations: URL, summaries: URL)? {
        guard let base = currentLibrary?.url else { return nil }
        return (base.appendingPathComponent("Transcripts"),
                base.appendingPathComponent("Translations"),
                base.appendingPathComponent("Summaries"))
    }
    
    func ensureTextArtifactDirectories() throws {
        guard let dirs = textArtifactsDirectories else { return }
        try FileManager.default.createDirectory(at: dirs.transcripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.translations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.summaries, withIntermediateDirectories: true)
    }
    
    func transcriptURL(for video: Video) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories else { return nil }
        return dirs.transcripts.appendingPathComponent("\(id.uuidString).txt")
    }
    
    func translationURL(for video: Video, languageCode: String) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories else { return nil }
        let safeLang = languageCode.replacingOccurrences(of: "/", with: "-")
        return dirs.translations.appendingPathComponent("\(id.uuidString)_\(safeLang).txt")
    }
    
    func summaryURL(for video: Video) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories else { return nil }
        return dirs.summaries.appendingPathComponent("\(id.uuidString).md")
    }
    
    func writeTextAtomically(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString)
        try text.data(using: .utf8)?.write(to: tmp, options: .atomic)
        // Remove existing file if present to avoid replaceItem oddities across volumes
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }
}
