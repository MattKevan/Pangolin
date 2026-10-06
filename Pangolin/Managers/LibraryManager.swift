import os
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
@Observable
final class LibraryManager {
    static let shared = LibraryManager()
    
    // MARK: - Observable State
    var currentLibrary: Library?
    var isLibraryOpen = false
    var isLoading = false
    var loadingProgress: Double = 0
    var error: LibraryError?
    
    // MARK: - Private Properties
    private let fileManager = FileManager.default
    private var coreDataStack: CoreDataStack?
    @ObservationIgnored private var thumbnailReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var libraryRecordsObserverTask: Task<Void, Never>?
    @ObservationIgnored private var isReconcilingCloudImportedLibraries = false
    let textArtifacts = TextArtifactStore()
    
    // MARK: - Constants
    private let currentVersion = "1.1.0"
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    private static let defaultLibraryName = "Pangolin Library"
    private let defaultVideoStorageType = LibraryStoragePreference.optimizeStorage.rawValue
    private let defaultMaxLocalVideoCacheBytes = Library.defaultMaxLocalVideoCacheBytes
    
    // MARK: - Initialization
    private init() {}
    
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

    /// Returns the single library record, merging any duplicates that CloudKit
    /// imported from another device. Returns nil when the store has no library yet.
    private func consolidateDuplicateLibraries(in context: NSManagedObjectContext) throws -> Library? {
        let libraries = try fetchLibraries(in: context)
        guard let canonical = chooseCanonicalLibrary(from: libraries) else {
            return nil
        }

        let duplicates = libraries.filter { $0.objectID != canonical.objectID }
        if !duplicates.isEmpty {
            Logger.library.warning("LIBRARY: Consolidating \(duplicates.count + 1) library records into one canonical library")
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

    private func observeCloudImportedLibraries(in context: NSManagedObjectContext) {
        libraryRecordsObserverTask?.cancel()
        libraryRecordsObserverTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
            for await notification in notifications {
                guard Self.didChangeLibraryRecords(notification) else { continue }
                await self?.reconcileCloudImportedLibrariesIfNeeded()
            }
        }
    }

    private static func didChangeLibraryRecords(_ notification: Notification) -> Bool {
        let changeKeys = [NSInsertedObjectsKey, NSUpdatedObjectsKey]
        return changeKeys
            .compactMap { notification.userInfo?[$0] as? Set<NSManagedObject> }
            .joined()
            .contains { $0 is Library }
    }

    /// Replaces a locally-created empty library with the data-bearing library
    /// imported from the same user's CloudKit private database.
    func reconcileCloudImportedLibrariesIfNeeded() async {
        guard !isReconcilingCloudImportedLibraries,
              let context = viewContext,
              currentLibrary?.url != nil else {
            return
        }

        let request = Library.fetchRequest()
        guard let libraries = try? context.fetch(request), libraries.count > 1 else {
            return
        }

        isReconcilingCloudImportedLibraries = true
        defer { isReconcilingCloudImportedLibraries = false }

        do {
            let previousLibraryID = currentLibrary?.id
            guard let reconciledLibrary = try consolidateDuplicateLibraries(in: context) else { return }

            guard currentLibrary?.objectID != reconciledLibrary.objectID else { return }

            if let previousLibraryID,
               previousLibraryID != reconciledLibrary.id,
               let sourceID = coreDataStack?.cloudEventSourceID {
                await ProcessingQueueManager.shared.cancelThumbnailWork(
                    for: previousLibraryID,
                    sourceID: sourceID
                )
            }

            currentLibrary = reconciledLibrary

            if let libraryID = reconciledLibrary.id,
               let sourceID = coreDataStack?.cloudEventSourceID {
                ProcessingQueueManager.shared.activateThumbnailWork(
                    for: libraryID,
                    sourceID: sourceID
                )
            }
            scheduleThumbnailReconciliation(for: reconciledLibrary)
        } catch {
            self.error = .saveFailed(error)
        }
    }
    
    // MARK: - Public Methods
    
    func save() async {
        Logger.library.info("LIBRARY: save() called")
        
        guard let context = self.viewContext else {
            Logger.library.error("LIBRARY: No viewContext available")
            return
        }
        
        Logger.library.info(
            "LIBRARY: Context changes — inserted: \(context.insertedObjects.count), updated: \(context.updatedObjects.count), deleted: \(context.deletedObjects.count)"
        )
        
        guard context.hasChanges else {
            Logger.library.info("LIBRARY: No changes to save")
            return
        }
        
        do {
            Logger.library.info("LIBRARY: Attempting context.save()...")
            try context.save()
            Logger.library.info("LIBRARY: Save successful!")
            
            Logger.library.info("LIBRARY: Verifying save by checking context state...")
            Logger.library.info("LIBRARY: After save - hasChanges: \(context.hasChanges)")
            Logger.library.info("LIBRARY: After save - updatedObjects count: \(context.updatedObjects.count)")
            
        } catch {
            Logger.library.error("LIBRARY: Save failed: \(error.localizedDescription)")
            self.error = .saveFailed(error)
            context.rollback()
            Logger.library.info("LIBRARY: Context rolled back")
        }
    }

    /// Opens the library stored at `url`, creating it first if the store is empty.
    /// There is only ever one library; any previously open one is closed first.
    @discardableResult
    func loadLibrary(at url: URL) async throws -> Library {
        isLoading = true
        loadingProgress = 0
        defer {
            isLoading = false
            loadingProgress = 0
        }

        await closeCurrentLibrary()

        try createLibraryDirectories(at: url)
        loadingProgress = 0.2

        let stack: CoreDataStack
        do {
            stack = try await CoreDataStack.getInstance(for: url)
        } catch {
            throw LibraryError.databaseCorrupted(error)
        }
        coreDataStack = stack
        loadingProgress = 0.5

        guard let context = stack.viewContext else {
            throw LibraryError.corruptedDatabase
        }
        observeCloudImportedLibraries(in: context)

        let library = try consolidateDuplicateLibraries(in: context) ?? (try makeLibrary(at: url, in: context))
        let previousLibraryURL = library.libraryPath.map(URL.init(fileURLWithPath:))
        // Resolve everything below against where the library actually is, not a stale stored path.
        if library.libraryPath != url.path {
            Logger.library.warning("LIBRARY: Updating stored libraryPath from \(library.libraryPath ?? "nil") to \(url.path)")
            library.libraryPath = url.path
        }
        loadingProgress = 0.7

        let storedVersion = library.version ?? "0.0.0"
        if storedVersion != currentVersion {
            try migrateLibrary(library, from: storedVersion, to: currentVersion)
        }

        normalizeStorageSettings(for: library)
        textArtifacts.libraryRoot = url
        try textArtifacts.migrateToPreferredLocation(libraryRoot: url, legacyRoot: previousLibraryURL)
        library.lastOpenedDate = Date()
        try context.save()

        currentLibrary = library
        isLibraryOpen = true
        loadingProgress = 1.0

        if let libraryID = library.id {
            ProcessingQueueManager.shared.activateThumbnailWork(
                for: libraryID,
                sourceID: stack.cloudEventSourceID
            )
        }
        scheduleThumbnailReconciliation(for: library)

        return library
    }

    private func makeLibrary(at url: URL, in context: NSManagedObjectContext) throws -> Library {
        Logger.library.info("LIBRARY: Creating new library at \(url.path)")
        // Look the entity up on this context's own model; several stacks can be loaded in one process.
        guard let entity = NSEntityDescription.entity(forEntityName: "Library", in: context) else {
            throw LibraryError.corruptedDatabase
        }
        let library = Library(entity: entity, insertInto: context)
        library.id = UUID()
        library.name = Self.defaultLibraryName
        library.libraryPath = url.path
        library.createdDate = Date()
        library.version = currentVersion
        library.videoStorageType = defaultVideoStorageType
        library.maxLocalVideoCacheBytes = defaultMaxLocalVideoCacheBytes
        return library
    }

    /// Close the current library
    func closeCurrentLibrary() async {
        thumbnailReconciliationTask?.cancel()
        thumbnailReconciliationTask = nil
        libraryRecordsObserverTask?.cancel()
        libraryRecordsObserverTask = nil
        guard let library = currentLibrary else { return }

        if let sourceID = coreDataStack?.cloudEventSourceID {
            await ProcessingQueueManager.shared.cancelThumbnailWork(
                for: library.id,
                sourceID: sourceID
            )
        } else {
            assertionFailure("An open library must retain its CoreData stack until close drains")
        }
        await save()
        
        if let libraryURL = library.url {
            CoreDataStack.releaseInstance(for: libraryURL)
        }
        
        coreDataStack = nil
        currentLibrary = nil
        textArtifacts.libraryRoot = nil
        isLibraryOpen = false
    }

    private func scheduleThumbnailReconciliation(for library: Library) {
        thumbnailReconciliationTask?.cancel()
        guard let libraryID = library.id else { return }
        thumbnailReconciliationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }

            guard let self,
                  self.isLibraryOpen,
                  let currentLibrary = self.currentLibrary,
                  currentLibrary.id == libraryID else { return }

            ProcessingQueueManager.shared.requestThumbnailReconciliation(for: libraryID)
        }
    }
    
    /// Opens the app's library, creating it on first launch.
    func smartStartup() async throws -> Library {
        try await loadLibrary(at: libraryBaseURL())
    }

// MARK: - Library Directories
    
    private func createLibraryDirectories(at url: URL) throws {
        let subdirectories = [
            "Videos",
            "Subtitles",
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
        Logger.library.warning("LIBRARY: Resetting corrupted database...")
        let libraryURL = try libraryBaseURL()

        await closeCurrentLibrary()

        let databasePath = libraryURL.appendingPathComponent("Library.sqlite").path
        for path in [databasePath, databasePath + "-wal", databasePath + "-shm"] where fileManager.fileExists(atPath: path) {
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                Logger.library.warning("LIBRARY: Failed to remove \(path): \(error)")
            }
        }

        return try await loadLibrary(at: libraryURL)
    }

    /// Deletes the video's generated text files and clears the matching fields.
    func clearGeneratedTextArtifacts(for video: Video) async throws {
        let removableURLs = [
            textArtifacts.existingTranscriptURL(for: video),
            textArtifacts.existingTimedTranscriptURL(for: video),
            textArtifacts.existingSummaryURL(for: video)
        ].compactMap { $0 } + textArtifacts.translationURLs(for: video)

        for url in removableURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        video.clearGeneratedText()
        try viewContext?.save()
    }

    // MARK: - Private Methods
    
    private func migrateLibrary(_ library: Library, from oldVersion: String, to newVersion: String) throws {
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
        for video in try context.fetch(request) {
            video.clearGeneratedText()
        }
        try textArtifacts.removeAllDirectories(libraryRoot: library.url)
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
    case libraryNotFound
    case invalidLibrary([String])
    case migrationFailed(String)
    case corruptedDatabase
    case databaseCorrupted(Error)
    case insufficientPermissions
    case diskSpaceInsufficient
    case saveFailed(Error)
    case documentsFolderUnavailable
    case unexpected(Error)
    
    var errorDescription: String? {
        switch self {
        case .libraryNotFound:
            return "Library not found"
        case .invalidLibrary(let errors):
            return "Invalid library: \(errors.joined(separator: ", "))"
        case .migrationFailed(let reason):
            return "Migration failed: \(reason)"
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
        case .unexpected(let error):
            return "Something went wrong opening the library. \(error.localizedDescription)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .libraryNotFound:
            return "Restart the app. If the problem persists, reset the library."
        case .invalidLibrary:
            return "Try repairing the library or create a new one"
        case .migrationFailed, .saveFailed, .unexpected:
            return "Please try the operation again. If the problem persists, restart the application."
        case .corruptedDatabase, .databaseCorrupted:
            return "Reset the library to rebuild it. Synced data will download again from iCloud."
        case .insufficientPermissions:
            return "Check file permissions and try again"
        case .diskSpaceInsufficient:
            return "Free up disk space and try again"
        case .documentsFolderUnavailable:
            return "Check file system permissions and ensure the Application Support folder is accessible."
        }
    }
}
