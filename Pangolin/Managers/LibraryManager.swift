//
//  LibraryManager.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import Foundation
import CoreData

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
    var textArtifactsCloudRootURLProvider: () -> URL? = {
        let fileManager = FileManager.default
        return fileManager.url(forUbiquityContainerIdentifier: VideoFileManager.shared.cloudContainerIdentifier)
            ?? fileManager.url(forUbiquityContainerIdentifier: nil)
    }
    
    // MARK: - Constants
    private let currentVersion = "1.1.0"
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    private let recentLibrariesKey = "RecentLibraries"
    private let lastOpenedLibraryKey = "LastOpenedLibrary"
    private let defaultVideoStorageType = LibraryStoragePreference.optimizeStorage.rawValue
    private let defaultMaxLocalVideoCacheBytes = Library.defaultMaxLocalVideoCacheBytes
    
    // MARK: - Initialization
    private init() {
        loadRecentLibraries()
    }
    
    // MARK: - Public Properties
    
    var viewContext: NSManagedObjectContext? {
        return coreDataStack?.viewContext ?? nil
    }
    
    var currentCoreDataStack: CoreDataStack? {
        return coreDataStack
    }
    
    // MARK: - Library Path
    
    func libraryBaseURL() throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LibraryError.documentsFolderUnavailable
        }
        let url = appSupport.appendingPathComponent("com.pangolin", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    private func hasDatabase(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("Library.sqlite").path)
    }

    private func fetchLibraries(in context: NSManagedObjectContext) throws -> [Library] {
        let request = Library.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Library.createdDate, ascending: true)]
        return try context.fetch(request)
    }

    private func chooseCanonicalLibrary(from libraries: [Library]) -> Library? {
        libraries.max { lhs, rhs in
            let lhsScore = (lhs.folders?.count ?? 0) + (lhs.videos?.count ?? 0)
            let rhsScore = (rhs.folders?.count ?? 0) + (rhs.videos?.count ?? 0)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            let lhsDate = lhs.createdDate ?? .distantFuture
            let rhsDate = rhs.createdDate ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            return lhs.objectID.uriRepresentation().absoluteString > rhs.objectID.uriRepresentation().absoluteString
        }
    }

    private func consolidateDuplicateLibraries(
        in context: NSManagedObjectContext,
        preferredStoreURL: URL
    ) throws -> Library {
        let libraries = try fetchLibraries(in: context)
        guard let canonical = chooseCanonicalLibrary(from: libraries) else {
            throw LibraryError.libraryNotFound
        }

        let duplicates = libraries.filter { $0.objectID != canonical.objectID }
        if !duplicates.isEmpty {
            print("🔧 LIBRARY: Consolidating \(duplicates.count + 1) library records into one canonical library")
        }

        for duplicate in duplicates {
            if canonical.name?.isEmpty != false, let name = duplicate.name, !name.isEmpty {
                canonical.name = name
            }
            if canonical.version?.isEmpty != false, let version = duplicate.version, !version.isEmpty {
                canonical.version = version
            }
            if canonical.createdDate == nil {
                canonical.createdDate = duplicate.createdDate
            }
            if let duplicateLastOpened = duplicate.lastOpenedDate,
               canonical.lastOpenedDate == nil || duplicateLastOpened > canonical.lastOpenedDate! {
                canonical.lastOpenedDate = duplicateLastOpened
            }

            if let folders = duplicate.folders as? Set<Folder> {
                for folder in folders {
                    folder.library = canonical
                }
            }

            if let videos = duplicate.videos as? Set<Video> {
                for video in videos {
                    video.library = canonical
                }
            }

            context.delete(duplicate)
        }

        return canonical
    }
    
    // MARK: - Public Methods
    
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

    /// Fetches or creates a top-level folder in the current library.
    func ensureTopLevelFolder(named name: String) async -> Folder? {
        guard let context = viewContext,
              let library = currentLibrary else {
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let request = Folder.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "library == %@ AND name == %@", library, trimmedName)

        if let existing = try? context.fetch(request).first {
            return existing
        }

        guard let folderEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Folder"] else {
            return nil
        }

        let folder = Folder(entity: folderEntityDescription, insertInto: context)
        folder.id = UUID()
        folder.name = trimmedName
        folder.projectTitle = trimmedName
        folder.projectProvider = nil
        folder.projectThumbnailPath = nil
        folder.isTopLevel = true
        folder.dateCreated = Date()
        folder.dateModified = Date()
        folder.library = library

        await save()
        return folder
    }
    
    /// Create a new library at the specified URL
    func createLibrary(at url: URL, name: String) async throws -> Library {
        print("📝 CREATE_LIBRARY: Starting createLibrary...")
        print("📝 CREATE_LIBRARY: URL: \(url.path)")
        print("📝 CREATE_LIBRARY: Library name: \(name)")

        isLoading = true
        loadingProgress = 0

        defer {
            isLoading = false
            loadingProgress = 0
        }

        if hasDatabase(at: url) {
            print("❌ CREATE_LIBRARY: Library already exists at path")
            throw LibraryError.libraryAlreadyExists(url)
        }
        
        try createLibraryDirectories(at: url)
        loadingProgress = 0.3
        
        let stack: CoreDataStack
        do {
            stack = try await CoreDataStack.getInstance(for: url)
        } catch {
            throw LibraryError.databaseCorrupted(error)
        }
        self.coreDataStack = stack
        loadingProgress = 0.6
        
        guard let context = stack.viewContext else {
            throw LibraryError.corruptedDatabase
        }
        
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
        
        guard library.entity == entityDescription else {
            print("ERROR: Library entity creation failed")
            throw LibraryError.corruptedDatabase
        }
        
        print("Library entity created successfully, setting properties...")
        
        library.id = UUID()
        library.name = name
        library.libraryPath = url.path
        library.createdDate = Date()
        library.lastOpenedDate = Date()
        library.version = currentVersion
        
        print("Basic properties set, setting default settings...")
        
        library.copyFilesOnImport = true
        library.organizeByDate = true
        library.autoMatchSubtitles = true
        library.defaultPlaybackSpeed = 1.0
        library.rememberPlaybackPosition = true
        
        library.videoStorageType = defaultVideoStorageType
        library.maxLocalVideoCacheBytes = defaultMaxLocalVideoCacheBytes
        
        print("All properties set successfully")
        
        loadingProgress = 0.8
        
        try context.save()
        
        self.currentLibrary = library
        self.isLibraryOpen = true
        
        print("Library created successfully: \(library.name ?? "Untitled")")
        print("Library open state: \(self.isLibraryOpen)")
        
        addToRecentLibraries(library)
        saveLastOpenedLibrary(url)
        
        loadingProgress = 1.0
        
        return library
    }
    
    /// Open an existing library at the given URL
    func openLibrary(at url: URL) async throws -> Library {
        isLoading = true
        loadingProgress = 0
        
        defer {
            isLoading = false
            loadingProgress = 0
        }
        
        guard fileManager.fileExists(atPath: url.path) else {
            throw LibraryError.invalidLibrary(["Library directory does not exist at \(url.path)"])
        }
        
        guard hasDatabase(at: url) else {
            throw LibraryError.corruptedDatabase
        }
        loadingProgress = 0.2
        
        try createLibraryDirectories(at: url)
        loadingProgress = 0.3
        
        if currentLibrary != nil {
            await closeCurrentLibrary()
        }
        
        let stack: CoreDataStack
        do {
            stack = try await CoreDataStack.getInstance(for: url)
        } catch {
            throw LibraryError.databaseCorrupted(error)
        }
        self.coreDataStack = stack
        loadingProgress = 0.5
        
        guard let context = stack.viewContext else {
            throw LibraryError.corruptedDatabase
        }
        let library = try consolidateDuplicateLibraries(in: context, preferredStoreURL: url)
        let previousLibraryURL = library.libraryPath.map(URL.init(fileURLWithPath:))
        loadingProgress = 0.7
        
        let currentLibraryVersion = library.version ?? "0.0.0"
        if currentLibraryVersion != currentVersion {
            try await migrateLibrary(library, from: currentLibraryVersion, to: currentVersion)
        }
        loadingProgress = 0.8
        
        normalizeStorageSettings(for: library)
        try migrateTextArtifactsToPreferredLocation(for: library, legacyLibraryURL: previousLibraryURL)
        library.lastOpenedDate = Date()
        if library.libraryPath != url.path {
            print("🔧 LIBRARY: Updating stored libraryPath from \(library.libraryPath ?? "nil") to \(url.path)")
            library.libraryPath = url.path
        }
        try context.save()
        
        self.currentLibrary = library
        self.isLibraryOpen = true
        
        addToRecentLibraries(library)
        saveLastOpenedLibrary(url)
        
        loadingProgress = 1.0
        
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
        
        await save()
        
        if let libraryURL = library.url {
            CoreDataStack.releaseInstance(for: libraryURL)
        }
        
        coreDataStack = nil
        currentLibrary = nil
        isLibraryOpen = false
    }
    
    /// Switch to a different library
    func switchToLibrary(_ descriptor: LibraryDescriptor) async throws {
        let library = try await openLibrary(at: descriptor.path)
        await StoragePolicyManager.shared.applyPolicy(for: library)
    }
    
    /// Open the last used library
    func openLastLibrary() async throws {
        guard let lastLibraryPath = userDefaults.url(forKey: lastOpenedLibraryKey),
              fileManager.fileExists(atPath: lastLibraryPath.path) else {
            throw LibraryError.noLastLibrary
        }

        let library = try await openLibrary(at: lastLibraryPath)
        await StoragePolicyManager.shared.applyPolicy(for: library)
    }
    
    /// Smart startup — opens existing library or creates a fresh one
    func smartStartup() async throws -> Library {
        print("🚀 LIBRARY: Starting smart startup...")
        let libraryURL = try libraryBaseURL()
        print("📍 LIBRARY: Library URL: \(libraryURL.path)")
        print("📍 LIBRARY: Has database: \(hasDatabase(at: libraryURL))")

        if !hasDatabase(at: libraryURL) {
            print("🆕 LIBRARY: No existing library — creating fresh")
            return try await createNewUserLibrary(at: libraryURL, name: "Pangolin Library")
        }

        return try await openLibrary(at: libraryURL)
    }
    
    // MARK: - Smart Startup Support
    
    private func createNewUserLibrary(at libraryURL: URL, name: String) async throws -> Library {
        print("🆕 LIBRARY: Creating new library at \(libraryURL.path)")
        return try await createLibrary(at: libraryURL, name: name)
    }
    
    private func openExistingLibrary(at libraryURL: URL) async throws -> Library {
        return try await openLibrary(at: libraryURL)
    }
    
    // MARK: - Library Directories
    
    private func createLibraryDirectories(at url: URL) throws {
        let subdirectories = [
            "Videos",
            "Subtitles",
            "Thumbnails",
            "Transcripts",
            "Translations",
            "Summaries",
            "Flashcards"
        ]
        for dir in subdirectories {
            let dirURL = url.appendingPathComponent(dir)
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Database Recovery
    
    func resetCorruptedDatabase() async throws -> Library {
        print("🔧 LIBRARY: Resetting corrupted database...")
        let libraryURL = try libraryBaseURL()
        
        CoreDataStack.releaseInstance(for: libraryURL)
        
        let databaseURL = libraryURL.appendingPathComponent("Library.sqlite")
        let walURL = databaseURL.appendingPathExtension("sqlite-wal")
        let shmURL = databaseURL.appendingPathExtension("sqlite-shm")
        
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
        
        print("🆕 LIBRARY: Creating fresh library...")
        let newLibrary = try await createLibrary(at: libraryURL, name: "Pangolin Library")
        
        print("✅ LIBRARY: Fresh library created successfully")
        return newLibrary
    }
    
    // MARK: - Private Methods
    
    private func loadRecentLibraries() {
        if let data = userDefaults.data(forKey: recentLibrariesKey),
           let libraries = try? JSONDecoder().decode([LibraryDescriptor].self, from: data) {
            self.recentLibraries = libraries
        }
    }
    
    private func addToRecentLibraries(_ library: Library) {
        guard let url = library.url,
              let libraryID = library.id,
              let libraryName = library.name,
              let lastOpenedDate = library.lastOpenedDate,
              let createdDate = library.createdDate else {
            return
        }
        
        let descriptor = LibraryDescriptor(
            id: libraryID,
            name: libraryName,
            path: url,
            lastOpenedDate: lastOpenedDate,
            createdDate: createdDate,
            version: library.version ?? currentVersion,
            thumbnailData: nil,
            videoCount: library.videoCount,
            totalSize: library.totalSize
        )
        
        recentLibraries.removeAll { $0.id == descriptor.id }
        recentLibraries.insert(descriptor, at: 0)
        
        if recentLibraries.count > 10 {
            recentLibraries = Array(recentLibraries.prefix(10))
        }
        
        if let data = try? JSONEncoder().encode(recentLibraries) {
            userDefaults.set(data, forKey: recentLibrariesKey)
        }
    }
    
    private func saveLastOpenedLibrary(_ url: URL) {
        userDefaults.set(url, forKey: lastOpenedLibraryKey)
    }
    
    private func migrateLibrary(_ library: Library, from oldVersion: String, to newVersion: String) async throws {
        guard let context = library.managedObjectContext else {
            throw LibraryError.corruptedDatabase
        }

        if isVersion(oldVersion, lessThan: "1.1.0") {
            try wipeLegacyTextArtifactsAndFields(for: library, in: context)
        }

        library.version = newVersion
        try context.save()
    }

    private func isVersion(_ lhs: String, lessThan rhs: String) -> Bool {
        let lhsComponents = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsComponents = rhs.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }
        return false
    }

    private func wipeLegacyTextArtifactsAndFields(for library: Library, in context: NSManagedObjectContext) throws {
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        let videos = try context.fetch(request)

        for video in videos {
            video.transcriptText = nil
            video.transcriptLanguage = nil
            video.transcriptDateGenerated = nil
            video.translatedText = nil
            video.translatedLanguage = nil
            video.translationDateGenerated = nil
            video.transcriptSummary = nil
            video.summaryDateGenerated = nil
        }

        var directoriesByPath: [String: URL] = [:]

        if let localDirectories = localTextArtifactsDirectories(for: library) {
            directoriesByPath[localDirectories.transcripts.standardizedFileURL.path] = localDirectories.transcripts
            directoriesByPath[localDirectories.translations.standardizedFileURL.path] = localDirectories.translations
            directoriesByPath[localDirectories.summaries.standardizedFileURL.path] = localDirectories.summaries
            directoriesByPath[localDirectories.flashcards.standardizedFileURL.path] = localDirectories.flashcards
        }

        if let cloudDirectories = cloudTextArtifactsDirectories() {
            directoriesByPath[cloudDirectories.transcripts.standardizedFileURL.path] = cloudDirectories.transcripts
            directoriesByPath[cloudDirectories.translations.standardizedFileURL.path] = cloudDirectories.translations
            directoriesByPath[cloudDirectories.summaries.standardizedFileURL.path] = cloudDirectories.summaries
            directoriesByPath[cloudDirectories.flashcards.standardizedFileURL.path] = cloudDirectories.flashcards
        }

        for directory in directoriesByPath.values {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        try ensureTextArtifactDirectories(for: library)
    }

    private func normalizeStorageSettings(for library: Library) {
        let existingType = library.videoStorageType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExistingTypeValid: Bool
        if let existingType,
           !existingType.isEmpty,
           existingType != "icloud_hybrid",
           LibraryStoragePreference(rawValue: existingType) != nil {
            isExistingTypeValid = true
        } else {
            isExistingTypeValid = false
        }

        if !isExistingTypeValid {
            library.videoStorageType = defaultVideoStorageType
        }

        if library.maxLocalVideoCacheBytes <= 0 {
            library.maxLocalVideoCacheBytes = defaultMaxLocalVideoCacheBytes
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
            return "Check file system permissions and ensure the Application Support folder is accessible."
        }
    }
}

// MARK: - Text Artifact Directories & I/O

extension LibraryManager {
    private typealias TextArtifactDirectories = (transcripts: URL, translations: URL, summaries: URL, flashcards: URL)

    private func localTextArtifactsDirectories(
        for library: Library? = nil,
        baseOverride: URL? = nil
    ) -> TextArtifactDirectories? {
        if let baseOverride {
            return (
                baseOverride.appendingPathComponent("Transcripts", isDirectory: true),
                baseOverride.appendingPathComponent("Translations", isDirectory: true),
                baseOverride.appendingPathComponent("Summaries", isDirectory: true),
                baseOverride.appendingPathComponent("Flashcards", isDirectory: true)
            )
        }

        let target = library ?? currentLibrary
        guard let base = target?.url else { return nil }
        return (
            base.appendingPathComponent("Transcripts", isDirectory: true),
            base.appendingPathComponent("Translations", isDirectory: true),
            base.appendingPathComponent("Summaries", isDirectory: true),
            base.appendingPathComponent("Flashcards", isDirectory: true)
        )
    }

    private func cloudTextArtifactsDirectories() -> TextArtifactDirectories? {
        guard let root = textArtifactsCloudRootURLProvider() else { return nil }
        return (
            root.appendingPathComponent("Transcripts", isDirectory: true),
            root.appendingPathComponent("Translations", isDirectory: true),
            root.appendingPathComponent("Summaries", isDirectory: true),
            root.appendingPathComponent("Flashcards", isDirectory: true)
        )
    }

    private func textArtifactsDirectories(for library: Library? = nil) -> TextArtifactDirectories? {
        cloudTextArtifactsDirectories() ?? localTextArtifactsDirectories(for: library)
    }

    private func migrateArtifactIfNeeded(from sourceURL: URL, to preferredURL: URL) {
        guard sourceURL.standardizedFileURL != preferredURL.standardizedFileURL else { return }
        guard fileManager.fileExists(atPath: sourceURL.path),
              !fileManager.fileExists(atPath: preferredURL.path) else { return }

        do {
            try fileManager.createDirectory(at: preferredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: preferredURL)
        } catch {
            print("⚠️ LIBRARY: Failed to migrate artifact \(sourceURL.lastPathComponent) to shared storage: \(error)")
        }
    }

    private func resolveExistingArtifactURL(preferredURL: URL?, fallbackURLs: [URL]) -> URL? {
        if let preferredURL, fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        for fallbackURL in fallbackURLs {
            guard fileManager.fileExists(atPath: fallbackURL.path) else { continue }
            if let preferredURL {
                migrateArtifactIfNeeded(from: fallbackURL, to: preferredURL)
                if fileManager.fileExists(atPath: preferredURL.path) {
                    return preferredURL
                }
            }
            return fallbackURL
        }

        return nil
    }

    private func migrateArtifacts(
        from sourceDirectories: TextArtifactDirectories,
        to destinationDirectories: TextArtifactDirectories
    ) throws {
        let directoryPairs = [
            (sourceDirectories.transcripts, destinationDirectories.transcripts),
            (sourceDirectories.translations, destinationDirectories.translations),
            (sourceDirectories.summaries, destinationDirectories.summaries),
            (sourceDirectories.flashcards, destinationDirectories.flashcards),
        ]

        for (sourceDirectory, destinationDirectory) in directoryPairs {
            guard sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL,
                  fileManager.fileExists(atPath: sourceDirectory.path) else { continue }

            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for fileURL in files {
                let destinationURL = destinationDirectory.appendingPathComponent(fileURL.lastPathComponent)
                migrateArtifactIfNeeded(from: fileURL, to: destinationURL)
            }
        }
    }

    private func migrateTextArtifactsToPreferredLocation(
        for library: Library,
        legacyLibraryURL: URL? = nil
    ) throws {
        guard let preferredDirectories = cloudTextArtifactsDirectories() else { return }

        if let localDirectories = localTextArtifactsDirectories(for: library) {
            try migrateArtifacts(from: localDirectories, to: preferredDirectories)
        }

        if let legacyLibraryURL,
           let legacyDirectories = localTextArtifactsDirectories(baseOverride: legacyLibraryURL) {
            try migrateArtifacts(from: legacyDirectories, to: preferredDirectories)
        }
    }
    
    func ensureTextArtifactDirectories(for library: Library? = nil) throws {
        guard let dirs = textArtifactsDirectories(for: library) else { return }
        try FileManager.default.createDirectory(at: dirs.transcripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.translations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.summaries, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.flashcards, withIntermediateDirectories: true)
    }
    
    func transcriptURL(for video: Video) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return nil }
        return dirs.transcripts.appendingPathComponent("\(id.uuidString).txt")
    }

    func existingTranscriptURL(for video: Video) -> URL? {
        guard let id = video.id else { return nil }
        let preferredURL = textArtifactsDirectories(for: video.library)?
            .transcripts
            .appendingPathComponent("\(id.uuidString).txt")
        let fallbackURLs = [
            localTextArtifactsDirectories(for: video.library)?
                .transcripts
                .appendingPathComponent("\(id.uuidString).txt")
        ].compactMap { $0 }
        return resolveExistingArtifactURL(preferredURL: preferredURL, fallbackURLs: fallbackURLs)
    }
    
    func timedTranscriptURL(for video: Video) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return nil }
        return dirs.transcripts.appendingPathComponent("\(id.uuidString).timed.json")
    }

    func existingTimedTranscriptURL(for video: Video) -> URL? {
        guard let id = video.id else { return nil }
        let preferredURL = textArtifactsDirectories(for: video.library)?
            .transcripts
            .appendingPathComponent("\(id.uuidString).timed.json")
        let fallbackURLs = [
            localTextArtifactsDirectories(for: video.library)?
                .transcripts
                .appendingPathComponent("\(id.uuidString).timed.json")
        ].compactMap { $0 }
        return resolveExistingArtifactURL(preferredURL: preferredURL, fallbackURLs: fallbackURLs)
    }

    func translationURL(for video: Video, languageCode: String) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return nil }
        let safeLang = languageCode.replacingOccurrences(of: "/", with: "-")
        return dirs.translations.appendingPathComponent("\(id.uuidString)_\(safeLang).txt")
    }

    func existingTranslationURL(for video: Video, languageCode: String) -> URL? {
        guard let id = video.id else { return nil }
        let safeLang = languageCode.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(id.uuidString)_\(safeLang).txt"
        let preferredURL = textArtifactsDirectories(for: video.library)?
            .translations
            .appendingPathComponent(fileName)
        let fallbackURLs = [
            localTextArtifactsDirectories(for: video.library)?
                .translations
                .appendingPathComponent(fileName)
        ].compactMap { $0 }
        return resolveExistingArtifactURL(preferredURL: preferredURL, fallbackURLs: fallbackURLs)
    }

    func timedTranslationURL(for video: Video, languageCode: String) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return nil }
        let safeLang = languageCode.replacingOccurrences(of: "/", with: "-")
        return dirs.translations.appendingPathComponent("\(id.uuidString)_\(safeLang).timed.json")
    }

    func existingTimedTranslationURL(for video: Video, languageCode: String) -> URL? {
        guard let id = video.id else { return nil }
        let safeLang = languageCode.replacingOccurrences(of: "/", with: "-")
        let fileName = "\(id.uuidString)_\(safeLang).timed.json"
        let preferredURL = textArtifactsDirectories(for: video.library)?
            .translations
            .appendingPathComponent(fileName)
        let fallbackURLs = [
            localTextArtifactsDirectories(for: video.library)?
                .translations
                .appendingPathComponent(fileName)
        ].compactMap { $0 }
        return resolveExistingArtifactURL(preferredURL: preferredURL, fallbackURLs: fallbackURLs)
    }

    func translationURLs(for video: Video) -> [URL] {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return [] }
        let prefix = id.uuidString + "_"
        let urls = (try? FileManager.default.contentsOfDirectory(at: dirs.translations, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    
    func summaryURL(for video: Video) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return nil }
        return dirs.summaries.appendingPathComponent("\(id.uuidString).md")
    }

    func existingSummaryURL(for video: Video) -> URL? {
        guard let id = video.id else { return nil }
        let preferredURL = textArtifactsDirectories(for: video.library)?
            .summaries
            .appendingPathComponent("\(id.uuidString).md")
        let fallbackURLs = [
            localTextArtifactsDirectories(for: video.library)?
                .summaries
                .appendingPathComponent("\(id.uuidString).md")
        ].compactMap { $0 }
        return resolveExistingArtifactURL(preferredURL: preferredURL, fallbackURLs: fallbackURLs)
    }

    func flashcardsURL(for video: Video) -> URL? {
        guard let id = video.id, let dirs = textArtifactsDirectories(for: video.library) else { return nil }
        return dirs.flashcards.appendingPathComponent("\(id.uuidString).json")
    }

    func existingFlashcardsURL(for video: Video) -> URL? {
        guard let id = video.id else { return nil }
        let preferredURL = textArtifactsDirectories(for: video.library)?
            .flashcards
            .appendingPathComponent("\(id.uuidString).json")
        let fallbackURLs = [
            localTextArtifactsDirectories(for: video.library)?
                .flashcards
                .appendingPathComponent("\(id.uuidString).json")
        ].compactMap { $0 }
        return resolveExistingArtifactURL(preferredURL: preferredURL, fallbackURLs: fallbackURLs)
    }
    
    func writeTimedTranscriptAtomically(_ transcript: TimedTranscript, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transcript)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }

    func readTimedTranscript(from url: URL) throws -> TimedTranscript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TimedTranscript.self, from: Data(contentsOf: url))
    }

    func readTimedTranscriptIfAvailable(from url: URL) throws -> TimedTranscript? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readTimedTranscript(from: url)
    }

    func writeTimedTranslationAtomically(_ translation: TimedTranslation, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(translation)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }

    func readTimedTranslation(from url: URL) throws -> TimedTranslation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TimedTranslation.self, from: Data(contentsOf: url))
    }

    func writeTextAtomically(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString)
        try text.data(using: .utf8)?.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }

    func writeFlashcardDeckAtomically(_ deck: FlashcardDeck, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(deck)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }

    func readFlashcardDeck(from url: URL) throws -> FlashcardDeck {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FlashcardDeck.self, from: Data(contentsOf: url))
    }
}
