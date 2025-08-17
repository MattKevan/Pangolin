//
//  LibraryManager.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import Foundation
import CoreData
import Combine

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
    
    // MARK: - Public Methods
    
    /// Create a new library at the specified URL
    func createLibrary(at url: URL, name: String) async throws -> Library {
        isLoading = true
        loadingProgress = 0
        
        defer {
            isLoading = false
            loadingProgress = 0
        }
        
        // Create library package directory
        let libraryURL = url.appendingPathComponent("\(name).\(libraryExtension)")
        
        // Check if already exists
        if fileManager.fileExists(atPath: libraryURL.path) {
            throw LibraryError.libraryAlreadyExists(libraryURL)
        }
        
        // Create directory structure
        try createLibraryStructure(at: libraryURL)
        loadingProgress = 0.3
        
        // Initialize Core Data stack
        let stack = try CoreDataStack(libraryURL: libraryURL)
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
        
        print("All properties set successfully")
        
        // Create default playlists
        createDefaultPlaylists(for: library, in: context)
        loadingProgress = 0.8
        
        // Save context
        try context.save()
        
        // Update current library
        self.currentLibrary = library
        self.isLibraryOpen = true
        
        print("Library created successfully: \(library.name)")
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
        
        // Initialize Core Data stack
        let stack = try CoreDataStack(libraryURL: url)
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
        if library.version != currentVersion {
            try await migrateLibrary(library, from: library.version, to: currentVersion)
        }
        loadingProgress = 0.8
        
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
        Task {
            await FileSystemManager.shared.generateMissingThumbnails(for: library, context: context)
        }
        
        return library
    }
    
    /// Close the current library
    func closeCurrentLibrary() async {
        guard currentLibrary != nil else { return }
        
        // Save any pending changes
        if let context = coreDataStack?.viewContext, context.hasChanges {
            try? context.save()
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
        guard let lastLibraryPath = userDefaults.url(forKey: lastOpenedLibraryKey) else {
            throw LibraryError.noLastLibrary
        }
        
        _ = try await openLibrary(at: lastLibraryPath)
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
        
        // Check for required subdirectories
        let requiredDirs = ["Videos", "Subtitles", "Thumbnails", "Backups"]
        for dir in requiredDirs {
            let dirPath = url.appendingPathComponent(dir)
            if !fileManager.fileExists(atPath: dirPath.path) {
                errors.append("Missing directory: \(dir)")
            }
        }
        
        // Check for database
        let dbPath = url.appendingPathComponent("Library.sqlite")
        if !fileManager.fileExists(atPath: dbPath.path) {
            errors.append("Database file not found")
        }
        
        // Check Info.plist
        let infoPlistPath = url.appendingPathComponent("Info.plist")
        if !fileManager.fileExists(atPath: infoPlistPath.path) {
            errors.append("Info.plist not found")
        }
        
        let isValid = errors.isEmpty
        let isRepairable = !errors.contains("Database file not found")
        
        return LibraryValidation(isValid: isValid,
                                errors: errors,
                                isRepairable: isRepairable)
    }
    
    // MARK: - Private Methods
    
    private func createLibraryStructure(at url: URL) throws {
        // Create main directory
        try fileManager.createDirectory(at: url,
                                       withIntermediateDirectories: true)
        
        // Create subdirectories
        let subdirectories = ["Videos", "Subtitles", "Thumbnails", "Backups"]
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
    
    private func createDefaultPlaylists(for library: Library, in context: NSManagedObjectContext) {
        let systemPlaylists = PlaylistType.systemPlaylists
        
        guard let playlistEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Playlist"] else {
            print("Could not find Playlist entity description")
            return
        }
        
        for (index, playlistInfo) in systemPlaylists.enumerated() {
            let playlist = Playlist(entity: playlistEntityDescription, insertInto: context)
            playlist.id = UUID()
            playlist.name = playlistInfo.name
            playlist.type = PlaylistType.system.rawValue
            playlist.iconName = playlistInfo.icon
            playlist.sortOrder = Int32(index)
            playlist.dateCreated = Date()
            playlist.dateModified = Date()
            playlist.library = library
        }
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
            id: library.id,
            name: library.name,
            path: url,
            lastOpenedDate: library.lastOpenedDate,
            createdDate: library.createdDate,
            version: library.version,
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
}

// MARK: - Library Errors
enum LibraryError: LocalizedError {
    case libraryAlreadyExists(URL)
    case libraryNotFound
    case invalidLibrary([String])
    case migrationFailed(String)
    case noLastLibrary
    case corruptedDatabase
    case insufficientPermissions
    case diskSpaceInsufficient
    
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
        case .insufficientPermissions:
            return "Insufficient permissions to access library"
        case .diskSpaceInsufficient:
            return "Not enough disk space available"
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
        case .migrationFailed:
            return "Restore from a backup or contact support"
        case .corruptedDatabase:
            return "Restore from a backup or rebuild the library"
        case .insufficientPermissions:
            return "Check file permissions and try again"
        case .diskSpaceInsufficient:
            return "Free up disk space and try again"
        }
    }
}
