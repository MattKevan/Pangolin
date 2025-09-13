//
//  PangolinSyncEngine.swift
//  Pangolin
//
//  Modern CloudKit sync using CKSyncEngine for iOS 26+
//  Replaces NSPersistentCloudKitContainer with complete visibility and control
//

import Foundation
import CloudKit
import Observation
import OSLog

@MainActor
@Observable
class PangolinSyncEngine: CKSyncEngineDelegate, ObservableObject {
    
    // MARK: - Published Properties for UI
    
    /// Overall sync status for main UI indicators
    var syncStatus: OverallSyncStatus = .idle
    
    /// Per-video sync statuses for detailed tracking
    var videoStatuses: [UUID: VideoSyncStatus] = [:]
    
    /// Upload progress (0.0 to 1.0) for active uploads
    var uploadProgress: Double = 0.0
    
    /// Download progress (0.0 to 1.0) for active downloads  
    var downloadProgress: Double = 0.0
    
    /// Videos currently being uploaded
    var pendingUploads: [UUID] = []
    
    /// Videos currently being downloaded
    var pendingDownloads: [UUID] = []
    
    /// Recent sync errors for user notification
    var syncErrors: [SyncError] = []
    
    /// Last successful sync timestamp
    var lastSyncDate: Date?
    
    /// iCloud account status
    var accountStatus: CKAccountStatus = .couldNotDetermine
    
    /// Network connectivity status
    var isNetworkAvailable: Bool = true
    
    /// Storage quota information
    var storageQuotaUsed: Double = 0.0
    var storageQuotaTotal: Double = 0.0
    
    // MARK: - Private Properties
    
    private var syncEngine: CKSyncEngine?
    private let database: CKDatabase
    private let container: CKContainer
    private let localStore: CoreDataStack
    private let logger = Logger(subsystem: "com.pangolin.sync", category: "SyncEngine")
    
    // Sync state persistence
    private let syncStateURL: URL
    
    // Internal tracking
    private var pendingRecordChanges: [CKRecord.ID: CKRecord] = [:]
    private var uploadProgressTracking: [UUID: Double] = [:]
    private var downloadProgressTracking: [UUID: Double] = [:]
    
    // MARK: - Initialization
    
    init(localStore: CoreDataStack, libraryURL: URL) {
        self.localStore = localStore
        // Use the same CloudKit container as the main app
        self.container = CKContainer(identifier: "iCloud.com.pangolin.video-library")
        self.database = container.privateCloudDatabase
        self.syncStateURL = libraryURL.appendingPathComponent("SyncState.data")
        
        logger.info("🚀 SYNC: Initializing PangolinSyncEngine")
        setupSyncEngine()
        startAccountStatusMonitoring()
    }
    
    deinit {
        logger.info("♻️ SYNC: PangolinSyncEngine deallocated")
    }
    
    // MARK: - Sync Engine Setup
    
    private func setupSyncEngine() {
        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadSyncState(),
            delegate: self
        )
        
        syncEngine = CKSyncEngine(config)
        logger.info("✅ SYNC: CKSyncEngine initialized successfully")
        
        // Start initial sync
        Task {
            await performInitialSync()
        }
    }
    
    // MARK: - Public Sync Methods
    
    /// Start a manual sync operation
    func startSync() async {
        logger.info("🔄 SYNC: Manual sync started")
        await MainActor.run {
            syncStatus = .syncing
        }
        
        do {
            // Fetch changes from CloudKit
            try await syncEngine?.fetchChanges()
            
            // Send any pending changes
            try await syncEngine?.sendChanges()
            
            await MainActor.run {
                lastSyncDate = Date()
                
                if syncErrors.isEmpty {
                    syncStatus = .idle
                    logger.info("✅ SYNC: Manual sync completed successfully")
                } else {
                    syncStatus = .error(syncErrors)
                    logger.warning("⚠️ SYNC: Manual sync completed with errors")
                }
            }
            
        } catch {
            logger.error("❌ SYNC: Manual sync failed: \(error, privacy: .public)")
            let syncError = SyncError(type: .syncFailed, message: error.localizedDescription)
            await MainActor.run {
                syncErrors.append(syncError)
                syncStatus = .error([syncError])
            }
        }
    }
    
    // MARK: - Public API for Library and Folder Operations
    
    /// Upload a library to CloudKit
    func uploadLibrary(_ library: Library) async throws {
        guard let libraryID = library.id else {
            throw SyncError(type: .invalidData, message: "Library missing ID")
        }
        
        logger.info("📚 SYNC: Starting upload for library: \(library.name ?? "unknown")")
        
        do {
            // Create CloudKit record from Core Data
            let libraryRecord = try await LibraryRecord.create(from: library)
            
            // Store record for when sync engine requests it
            pendingRecordChanges[libraryRecord.recordID] = libraryRecord.record
            
            // Add to sync engine for upload
            syncEngine?.state.add(pendingRecordZoneChanges: [
                .saveRecord(libraryRecord.recordID)
            ])
            
            // Trigger upload
            try await syncEngine?.sendChanges()
            
            logger.info("✅ SYNC: Library queued for upload: \(libraryID)")
            
        } catch {
            logger.error("❌ SYNC: Upload failed for library \(libraryID): \(error, privacy: .public)")
            throw error
        }
    }
    
    /// Upload a folder to CloudKit
    func uploadFolder(_ folder: Folder) async throws {
        guard let folderID = folder.id else {
            throw SyncError(type: .invalidData, message: "Folder missing ID")
        }
        
        logger.info("📁 SYNC: Starting upload for folder: \(folder.name ?? "unknown")")
        
        do {
            // Create CloudKit record from Core Data
            let folderRecord = try await FolderRecord.create(from: folder)
            
            // Store record for when sync engine requests it
            pendingRecordChanges[folderRecord.recordID] = folderRecord.record
            
            // Add to sync engine for upload
            syncEngine?.state.add(pendingRecordZoneChanges: [
                .saveRecord(folderRecord.recordID)
            ])
            
            // Trigger upload
            try await syncEngine?.sendChanges()
            
            logger.info("✅ SYNC: Folder queued for upload: \(folderID)")
            
        } catch {
            logger.error("❌ SYNC: Upload failed for folder \(folderID): \(error, privacy: .public)")
            throw error
        }
    }
    
    // MARK: - Public API for Video Operations
    
    /// Upload a video to CloudKit
    func uploadVideo(_ video: Video) async throws {
        guard let videoID = video.id else {
            throw SyncError(type: .invalidData, message: "Video missing ID")
        }
        
        logger.info("📤 SYNC: Starting upload for video: \(video.title ?? "unknown")")
        
        // Update status
        videoStatuses[videoID] = .uploading(0.0)
        pendingUploads.append(videoID)
        uploadProgressTracking[videoID] = 0.0
        
        do {
            // Create CloudKit record from video
            let videoRecord = try await VideoRecord.create(from: video, localStore: localStore)
            
            // Add to pending changes
            syncEngine?.state.add(pendingRecordZoneChanges: [
                .saveRecord(videoRecord.recordID)
            ])
            
            // Store record for when sync engine requests it
            pendingRecordChanges[videoRecord.recordID] = videoRecord.record
            
            // Trigger upload
            try await syncEngine?.sendChanges()
            
            logger.info("✅ SYNC: Video upload initiated: \(videoID)")
            
        } catch {
            logger.error("❌ SYNC: Video upload failed: \(videoID) - \(error, privacy: .public)")
            
            // Update status
            videoStatuses[videoID] = .error(SyncError(type: .uploadFailed, message: error.localizedDescription))
            pendingUploads.removeAll { $0 == videoID }
            uploadProgressTracking.removeValue(forKey: videoID)
            
            throw error
        }
    }
    
    /// Download a video from CloudKit
    func downloadVideo(recordID: CKRecord.ID) async throws {
        let videoIDString = recordID.recordName
        guard let videoID = UUID(uuidString: videoIDString) else {
            throw SyncError(type: .invalidData, message: "Invalid video ID in record")
        }
        
        logger.info("📥 SYNC: Starting download for video: \(videoID)")
        
        // Update status
        videoStatuses[videoID] = .downloading(0.0)
        pendingDownloads.append(videoID)
        downloadProgressTracking[videoID] = 0.0
        
        // Trigger fetch to get the latest version
        try await syncEngine?.fetchChanges()
    }
    
    /// Get sync status for a specific video
    func getSyncStatus(for videoID: UUID) -> VideoSyncStatus {
        return videoStatuses[videoID] ?? .local
    }
    
    /// Retry failed sync operations
    func retryFailedSyncs() async {
        logger.info("🔄 SYNC: Retrying failed syncs")
        
        let failedVideos = videoStatuses.compactMap { (key, value) -> UUID? in
            if case .error = value { return key }
            return nil
        }
        
        for videoID in failedVideos {
            // Reset status and retry
            videoStatuses[videoID] = .local
            
            // Find the video and retry upload
            do {
                try await localStore.performBackgroundTask { context in
                    let request = Video.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
                    
                    if let video = try? context.fetch(request).first {
                        Task { @MainActor in
                            try? await self.uploadVideo(video)
                        }
                    }
                }
            } catch {
                logger.error("❌ SYNC: Failed to retry failed uploads: \(error, privacy: .public)")
            }
        }
    }
    
    /// Force a complete re-sync
    func resetSync() async {
        logger.info("🔄 SYNC: Resetting sync state")
        
        // Clear all tracking
        await MainActor.run {
            videoStatuses.removeAll()
            pendingUploads.removeAll()
            pendingDownloads.removeAll()
            uploadProgressTracking.removeAll()
            downloadProgressTracking.removeAll()
            syncErrors.removeAll()
            
            // Reset sync engine state if needed
            syncStatus = .idle
        }
        
        // Restart sync
        await startSync()
    }
    
    // MARK: - CKSyncEngineDelegate Implementation
    
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            await saveSyncState(stateUpdate.stateSerialization)
            
        case .accountChange(let accountChange):
            await handleAccountChange(accountChange)
            
        case .fetchedDatabaseChanges(let changes):
            await handleDatabaseChanges(changes)
            
        case .fetchedRecordZoneChanges(let changes):
            await handleRecordZoneChanges(changes)
            
        case .sentDatabaseChanges(let changes):
            await handleSentDatabaseChanges(changes)
            
        case .sentRecordZoneChanges(let changes):
            await handleSentRecordZoneChanges(changes)
            
        case .willFetchChanges(let reason):
            logger.info("🔄 SYNC: Will fetch changes - reason: \(String(describing: reason), privacy: .public)")
            await MainActor.run {
                if syncStatus == .idle {
                    syncStatus = .syncing
                }
            }
            
        case .didFetchChanges(let reason):
            logger.info("✅ SYNC: Did fetch changes - reason: \(String(describing: reason), privacy: .public)")
            await updateOverallSyncStatus()
            
        case .willSendChanges(let reason):
            logger.info("🔄 SYNC: Will send changes - reason: \(String(describing: reason), privacy: .public)")
            
        case .didSendChanges(let reason):
            logger.info("✅ SYNC: Did send changes - reason: \(String(describing: reason), privacy: .public)")
            await updateOverallSyncStatus()
            
        default:
            logger.warning("⚠️ SYNC: Unhandled sync engine event: \(String(describing: event), privacy: .public)")
        }
    }
    
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        
        // Snapshot pending changes on the main actor
        let recordsToSend: [CKRecord] = await MainActor.run {
            Array(self.pendingRecordChanges.values)
        }
        
        if !recordsToSend.isEmpty {
            return await CKSyncEngine.RecordZoneChangeBatch(
                pendingChanges: recordsToSend.map { .saveRecord($0.recordID) },
                recordProvider: { recordID async in
                    // Read main-actor-isolated storage safely
                    return await MainActor.run {
                        self.pendingRecordChanges[recordID]
                    }
                }
            )
        }
        
        return nil
    }
    
    // MARK: - Private Event Handlers
    
    private func handleAccountChange(_ accountChange: CKSyncEngine.Event.AccountChange) async {
        logger.info("👤 SYNC: Account change occurred")
        
        switch accountChange.changeType {
        case .signIn:
            await MainActor.run {
                accountStatus = .available
                syncStatus = .idle
            }
            // Use detached task to avoid delegate callback deadlock
            Task.detached { [weak self] in
                await self?.startSync()
            }
            
        case .signOut:
            await MainActor.run {
                accountStatus = .noAccount
                syncStatus = .accountIssue
            }
            
        case .switchAccounts:
            await MainActor.run {
                accountStatus = .available
            }
            // Use detached task to avoid delegate callback deadlock
            Task.detached { [weak self] in
                await self?.resetSync()
            }
            
        default:
            logger.warning("⚠️ SYNC: Unknown account change type")
        }
    }
    
    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        logger.info("📊 SYNC: Fetched database changes")
        
        // Handle database-level changes if needed
        // For now, most changes will be at the record zone level
    }
    
    private func handleRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        logger.info("📁 SYNC: Fetched record zone changes: \(changes.modifications.count) modifications, \(changes.deletions.count) deletions")
        
        // Process modified records
        for modification in changes.modifications {
            await processModifiedRecord(modification.record)
        }
        
        // Process deleted records
        for deletion in changes.deletions {
            await processDeletedRecord(deletion.recordID)
        }
    }
    
    private func handleSentDatabaseChanges(_ changes: CKSyncEngine.Event.SentDatabaseChanges) async {
        logger.info("📤 SYNC: Sent database changes")
        // Handle database-level sent changes if needed
    }
    
    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) async {
        logger.info("📤 SYNC: Sent record zone changes: \(changes.savedRecords.count) saved, \(changes.failedRecordSaves.count) failed")
        
        // Process successfully saved records
        for savedRecord in changes.savedRecords {
            await processSuccessfulUpload(savedRecord)
        }
        
        // Process failed saves
        for failedSave in changes.failedRecordSaves {
            // TODO: Fix when correct API property is available  
            // await processFailedUpload(failedSave.recordID, error: failedSave.error)
            logger.error("❌ SYNC: Failed to upload record: \(String(describing: failedSave), privacy: .public)")
        }
        
        // Remove processed records from pending
        for savedRecord in changes.savedRecords {
            pendingRecordChanges.removeValue(forKey: savedRecord.recordID)
        }
        
        for failedSave in changes.failedRecordSaves {
            // TODO: Fix when correct API property is available
            // pendingRecordChanges.removeValue(forKey: failedSave.recordID)
            logger.error("❌ SYNC: Failed to save record: \(String(describing: failedSave), privacy: .public)")
        }
    }
    
    // MARK: - Record Processing
    
    private func processModifiedRecord(_ record: CKRecord) async {
        logger.info("📝 SYNC: Processing modified record: \(record.recordID, privacy: .public)")
        
        // Handle different record types - both our custom types and Core Data CloudKit types
        switch record.recordType {
        case VideoRecord.recordType, "CD_Video":
            await processModifiedVideoRecord(record)
        case LibraryRecord.recordType, "CD_Library":
            await processModifiedLibraryRecord(record)
        case FolderRecord.recordType, "CD_Folder":
            await processModifiedFolderRecord(record)
        case "CD_Subtitle":
            // Handle subtitle records if needed
            logger.info("📝 SYNC: Processing subtitle record: \(record.recordID, privacy: .public)")
        default:
            logger.warning("⚠️ SYNC: Unknown record type: \(record.recordType, privacy: .public)")
        }
    }
    
    private func processModifiedVideoRecord(_ record: CKRecord) async {
        // Extract video ID from record name
        let recordName = record.recordID.recordName.replacingOccurrences(of: "-video", with: "")
        guard let videoID = UUID(uuidString: recordName) else {
            logger.error("❌ SYNC: Invalid video ID in record: \(record.recordID, privacy: .public)")
            return
        }
        
        do {
            // Update Core Data with CloudKit record
            try await VideoRecord.updateCoreData(from: record, videoID: videoID, localStore: localStore)
            
            await MainActor.run {
                videoStatuses[videoID] = .synced
                pendingDownloads.removeAll { $0 == videoID }
                downloadProgressTracking.removeValue(forKey: videoID)
            }
            
            logger.info("✅ SYNC: Video record updated: \(videoID, privacy: .public)")
            
        } catch {
            logger.error("❌ SYNC: Failed to update video record: \(videoID, privacy: .public) - \(error, privacy: .public)")
            
            await MainActor.run {
                videoStatuses[videoID] = .error(SyncError(type: .downloadFailed, message: error.localizedDescription))
                pendingDownloads.removeAll { $0 == videoID }
                downloadProgressTracking.removeValue(forKey: videoID)
            }
        }
    }
    
    private func processModifiedLibraryRecord(_ record: CKRecord) async {
        // Extract library ID from record name
        let recordName = record.recordID.recordName.replacingOccurrences(of: "-library", with: "")
        guard let libraryID = UUID(uuidString: recordName) else {
            logger.error("❌ SYNC: Invalid library ID in record: \(record.recordID, privacy: .public)")
            return
        }
        
        do {
            // Update Core Data with CloudKit record
            try await LibraryRecord.updateCoreData(from: record, libraryID: libraryID, localStore: localStore)
            logger.info("✅ SYNC: Library record updated: \(libraryID, privacy: .public)")
            
        } catch {
            logger.error("❌ SYNC: Failed to update library record: \(libraryID, privacy: .public) - \(error, privacy: .public)")
        }
    }
    
    private func processModifiedFolderRecord(_ record: CKRecord) async {
        // Extract folder ID from record name
        let recordName = record.recordID.recordName.replacingOccurrences(of: "-folder", with: "")
        guard let folderID = UUID(uuidString: recordName) else {
            logger.error("❌ SYNC: Invalid folder ID in record: \(record.recordID, privacy: .public)")
            return
        }
        
        do {
            // Update Core Data with CloudKit record
            try await FolderRecord.updateCoreData(from: record, folderID: folderID, localStore: localStore)
            logger.info("✅ SYNC: Folder record updated: \(folderID, privacy: .public)")
            
        } catch {
            logger.error("❌ SYNC: Failed to update folder record: \(folderID, privacy: .public)")
        }
    }
    
    private func processDeletedRecord(_ recordID: CKRecord.ID) async {
        logger.info("🗑️ SYNC: Processing deleted record: \(recordID, privacy: .public)")
        
        // Handle deletion based on record type (inferred from record ID or metadata)
        // This would typically involve removing the corresponding Core Data entity
        
        do {
            try await localStore.performBackgroundTask { context in
                // Find and delete corresponding Core Data objects
                // Implementation depends on how we map CloudKit IDs to Core Data objects
            }
        } catch {
            logger.error("❌ SYNC: Failed to process deleted record: \(error, privacy: .public)")
        }
    }
    
    
    private func processSuccessfulUpload(_ record: CKRecord) async {
        guard let videoIDString = record.recordID.recordName.components(separatedBy: "-").first,
              let videoID = UUID(uuidString: videoIDString) else {
            logger.warning("⚠️ SYNC: Could not extract video ID from record: \(record.recordID, privacy: .public)")
            return
        }
        
        logger.info("✅ SYNC: Video uploaded successfully: \(videoID, privacy: .public)")
        
        // Update status
        videoStatuses[videoID] = .synced
        pendingUploads.removeAll { $0 == videoID }
        uploadProgressTracking.removeValue(forKey: videoID)
        
        // Update overall progress
        await updateOverallSyncStatus()
    }
    
    private func processFailedUpload(_ recordID: CKRecord.ID, error: Error) async {
        guard let videoIDString = recordID.recordName.components(separatedBy: "-").first,
              let videoID = UUID(uuidString: videoIDString) else {
            logger.warning("⚠️ SYNC: Could not extract video ID from failed record: \(recordID, privacy: .public)")
            return
        }
        
        logger.error("❌ SYNC: Video upload failed: \(videoID, privacy: .public) - \(error, privacy: .public)")
        
        let syncError = SyncError(type: .uploadFailed, message: error.localizedDescription)
        
        // Update status
        videoStatuses[videoID] = .error(syncError)
        pendingUploads.removeAll { $0 == videoID }
        uploadProgressTracking.removeValue(forKey: videoID)
        syncErrors.append(syncError)
        
        // Update overall status
        await updateOverallSyncStatus()
    }
    
    // MARK: - Status Management
    
    private func updateOverallSyncStatus() async {
        await MainActor.run {
            if !pendingUploads.isEmpty || !pendingDownloads.isEmpty {
                syncStatus = .syncing
                
                // Update progress
                let totalOperations = Double(pendingUploads.count + pendingDownloads.count)
                let completedProgress = uploadProgressTracking.values.reduce(0, +) + downloadProgressTracking.values.reduce(0, +)
                
                if totalOperations > 0 {
                    let overallProgress = completedProgress / totalOperations
                    uploadProgress = overallProgress
                }
                
            } else if !syncErrors.isEmpty {
                syncStatus = .error(syncErrors)
            } else if accountStatus != .available {
                syncStatus = .accountIssue
            } else if !isNetworkAvailable {
                syncStatus = .offline
            } else {
                syncStatus = .idle
                uploadProgress = 0.0
                downloadProgress = 0.0
                lastSyncDate = Date()
            }
        }
    }
    
    // MARK: - State Persistence
    
    private func loadSyncState() -> CKSyncEngine.State.Serialization? {
        guard FileManager.default.fileExists(atPath: syncStateURL.path) else {
            logger.info("ℹ️ SYNC: No existing sync state found, starting fresh")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: syncStateURL)
            let decoder = JSONDecoder()
            let stateSerialization = try decoder.decode(CKSyncEngine.State.Serialization.self, from: data)
            logger.info("✅ SYNC: Loaded existing sync state")
            return stateSerialization
        } catch {
            logger.error("❌ SYNC: Failed to load sync state: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func saveSyncState(_ stateSerialization: CKSyncEngine.State.Serialization) async {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(stateSerialization)
            try data.write(to: syncStateURL)
            logger.debug("💾 SYNC: State saved successfully")
        } catch {
            logger.error("❌ SYNC: Failed to save sync state: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Account Status Monitoring
    
    private func startAccountStatusMonitoring() {
        Task {
            await checkAccountStatus()
            
            // Set up periodic monitoring
            Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                Task {
                    await self?.checkAccountStatus()
                }
            }
        }
    }
    
    private func checkAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            await MainActor.run {
                let previousStatus = self.accountStatus
                self.accountStatus = status
                
                // Only log if status changed or if it's the first check
                if previousStatus != status || previousStatus == .couldNotDetermine {
                    switch status {
                    case .available:
                        self.logger.info("✅ SYNC: iCloud account available")
                    case .noAccount:
                        self.logger.warning("⚠️ SYNC: No iCloud account signed in")
                    case .restricted:
                        self.logger.warning("⚠️ SYNC: iCloud account restricted")
                    case .couldNotDetermine:
                        self.logger.warning("⚠️ SYNC: Could not determine iCloud account status")
                    case .temporarilyUnavailable:
                        self.logger.warning("⚠️ SYNC: iCloud account temporarily unavailable")
                    @unknown default:
                        self.logger.warning("⚠️ SYNC: Unknown iCloud account status: \(String(describing: status))")
                    }
                }
            }
        } catch {
            await MainActor.run {
                // Only log error if we haven't successfully determined status yet
                if self.accountStatus == .couldNotDetermine {
                    self.logger.error("❌ SYNC: Could not determine iCloud account status: \(error.localizedDescription)")
                }
            }
            
            // Retry after a brief delay on first failure
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            // Try one more time
            do {
                let status = try await container.accountStatus()
                await MainActor.run {
                    self.accountStatus = status
                    self.logger.info("✅ SYNC: iCloud account status determined on retry: \(String(describing: status))")
                }
            } catch {
                self.logger.error("❌ SYNC: Failed to get account status after retry: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Initial Sync
    
    private func performInitialSync() async {
        logger.info("🚀 SYNC: Performing initial sync")
        
        // Wait for account status to be determined
        var retryCount = 0
        while self.accountStatus == .couldNotDetermine && retryCount < 10 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            retryCount += 1
        }
        
        // Only start sync if account is available
        if self.accountStatus == .available {
            await startSync()
        } else {
            logger.info("ℹ️ SYNC: Skipping initial sync - account not available (status: \(String(describing: self.accountStatus)))")
        }
    }
}

// MARK: - Supporting Types

enum OverallSyncStatus: Equatable {
    case idle
    case syncing
    case error([SyncError])
    case offline
    case accountIssue
    case quotaExceeded
}

enum VideoSyncStatus: Equatable {
    case local              // Not uploaded to CloudKit
    case uploading(Double)  // Upload in progress (0.0 to 1.0)
    case synced            // Successfully synced
    case downloading(Double) // Download in progress (0.0 to 1.0)
    case conflict          // Sync conflict needs resolution
    case error(SyncError)  // Failed with error
    case retrying          // Automatic retry in progress
}

struct SyncError: Error, Equatable, Identifiable {
    let id = UUID()
    let type: SyncErrorType
    let message: String
    let timestamp = Date()
    
    enum SyncErrorType {
        case initializationFailed
        case uploadFailed
        case downloadFailed
        case syncFailed
        case networkError
        case accountError
        case quotaExceeded
        case invalidData
        case conflictResolutionFailed
        case missingVideoID
        case missingLibraryID
        case missingFolderID
    }
}
