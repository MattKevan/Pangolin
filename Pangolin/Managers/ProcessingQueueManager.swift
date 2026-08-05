import os
// ProcessingQueueManager.swift
// Unified processing queue manager

import Foundation
import CoreData
import Combine

/// Resolves which library a queued import task may write into. Only the currently
/// open library is a valid target, so tasks queued for a different (now closed)
/// library fail instead of importing their files into the wrong store.
enum ImportLibraryResolution {
    static func resolve(taskLibraryID: UUID?, currentLibraryID: UUID?) -> UUID? {
        guard let currentLibraryID else { return nil }
        guard let taskLibraryID else { return currentLibraryID }
        return taskLibraryID == currentLibraryID ? taskLibraryID : nil
    }
}

@MainActor
class ProcessingQueueManager: ObservableObject {
    struct TaskFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct CloudSyncQueueStatus: Equatable {
        enum Phase: Equatable {
            case syncing
            case completed
            case failed
        }

        let phase: Phase
        let detail: String
        let activeOperationCount: Int
        let updatedAt: Date

        var isActive: Bool { phase == .syncing }

        var iconName: String {
            switch phase {
            case .syncing:
                return "icloud"
            case .completed:
                return "checkmark.icloud"
            case .failed:
                return "exclamationmark.icloud"
            }
        }

        var tintName: String {
            switch phase {
            case .syncing:
                return "blue"
            case .completed:
                return "green"
            case .failed:
                return "orange"
            }
        }
    }

    struct ActiveCloudSyncEvent {
        let id: UUID
        let sourceID: UUID
        let type: NSPersistentCloudKitContainer.EventType
        var libraryID: UUID?
    }

    static let shared = ProcessingQueueManager()

    let processingQueue = ProcessingQueue()
    var cancellables = Set<AnyCancellable>()
    var workerTask: Task<Void, Never>?
    var importFolderMaps: [UUID: [String: Folder]] = [:]
    var pendingImportSaveCounts: [UUID: Int] = [:]
    let importSaveBatchSize = 8
    var importStoragePolicyTask: Task<Void, Never>?
    var activeCloudSyncEvents: [UUID: ActiveCloudSyncEvent] = [:]
    var cloudEventSourceLifecycle = CloudEventSourceLifecycle()
    var cloudSyncHideTask: Task<Void, Never>?
    var thumbnailReconciliationGate = ThumbnailReconciliationGate()
    var thumbnailReconciliationScanTask: Task<Void, Never>?
    var thumbnailReconciliationScanLibraryID: UUID?
    var thumbnailReconciliationScanToken: UUID?
    var thumbnailReconciliationRescanLibraryID: UUID?
    var thumbnailLibraryLifecycle = ThumbnailLibraryLifecycle()
    var closingThumbnailLibraryIDs: Set<UUID> {
        thumbnailLibraryLifecycle.closingLibraryIDs
    }

    let transcriptionService = SpeechTranscriptionService()
    let videoFileManager = VideoFileManager.shared
    let videoUploadOptimizer = VideoUploadOptimizer.shared
    let importer = VideoImporter()
    let remoteDownloadService = RemoteVideoDownloadService()
    var videoPagePreferences: VideoPagePreferences {
        VideoPagePreferences()
    }

    @Published var queue: [ProcessingTask] = []
    @Published var isPaused: Bool = false
    @Published var overallProgress: Double = 0.0
    @Published var activeTaskCount: Int = 0
    @Published var totalTaskCount: Int = 0
    @Published var completedTasks: Int = 0
    @Published var failedTasks: Int = 0
    @Published var cloudSyncQueueStatus: CloudSyncQueueStatus?

    var totalTasks: Int { totalTaskCount }
    var activeTasks: Int { activeTaskCount }
    var visibleActiveTaskCount: Int { activeTaskCount + (isCloudSyncActive ? 1 : 0) }
    var visibleOverallIndicatorProgress: Double {
        if activeTaskCount > 0 {
            return overallProgress
        }
        return isCloudSyncActive ? 0.2 : 0.0
    }
    var isCloudSyncActive: Bool { cloudSyncQueueStatus?.isActive == true }
    var activeVideoIDs: Set<UUID> {
        Set(queue.filter { $0.status.isActive }.compactMap { $0.videoID })
    }

    private init() {
        processingQueue.hasRequiredDataProvider = { [weak self] videoID, type in
            guard let self else { return false }
            return self.hasRequiredData(videoID: videoID, type: type)
        }

        processingQueue.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self else { return }
                self.queue = tasks
                self.refreshStats()
            }
            .store(in: &cancellables)
    }

    func handleCloudKitEvent(_ event: NSPersistentCloudKitContainer.Event, sourceID: UUID) {
        let sourceLibraryID: UUID?
        switch cloudEventSourceLifecycle.scope(for: sourceID) {
        case .closed:
            return
        case .unbound:
            sourceLibraryID = nil
        case .library(let libraryID):
            guard !closingThumbnailLibraryIDs.contains(libraryID) else { return }
            sourceLibraryID = libraryID
        }
        cloudSyncHideTask?.cancel()
        let now = Date()
        let eventID = event.identifier

        if event.endDate == nil {
            activeCloudSyncEvents[eventID] = ActiveCloudSyncEvent(
                id: eventID,
                sourceID: sourceID,
                type: event.type,
                libraryID: sourceLibraryID
            )
            thumbnailReconciliationGate.eventStarted(
                id: eventID,
                sourceID: sourceID,
                isImport: event.type == .import,
                libraryID: sourceLibraryID
            )
            cloudSyncQueueStatus = CloudSyncQueueStatus(
                phase: .syncing,
                detail: cloudSyncActiveDetail(),
                activeOperationCount: activeCloudSyncEvents.count,
                updatedAt: now
            )
            return
        }

        guard activeCloudSyncEvents[eventID]?.sourceID == sourceID,
              let completedEvent = activeCloudSyncEvents.removeValue(forKey: eventID) else { return }
        let eventLibraryID = completedEvent.libraryID

        if let libraryID = thumbnailReconciliationGate.eventCompleted(
            id: eventID,
            sourceID: sourceID,
            isImport: event.type == .import,
            succeeded: event.error == nil,
            libraryID: eventLibraryID
        ), LibraryManager.shared.currentLibrary?.id == libraryID {
            startThumbnailReconciliationScan(for: libraryID)
        }

        if !activeCloudSyncEvents.isEmpty {
            cloudSyncQueueStatus = CloudSyncQueueStatus(
                phase: .syncing,
                detail: cloudSyncActiveDetail(),
                activeOperationCount: activeCloudSyncEvents.count,
                updatedAt: now
            )
            return
        }

        if let error = event.error {
            cloudSyncQueueStatus = CloudSyncQueueStatus(
                phase: .failed,
                detail: "Sync failed during \(cloudSyncOperationLabel(for: event.type)): \(error.localizedDescription)",
                activeOperationCount: 0,
                updatedAt: now
            )
            scheduleCloudSyncStatusHide(after: 12)
        } else {
            cloudSyncQueueStatus = CloudSyncQueueStatus(
                phase: .completed,
                detail: "iCloud sync complete (\(cloudSyncOperationLabel(for: event.type)))",
                activeOperationCount: 0,
                updatedAt: now
            )
            scheduleCloudSyncStatusHide(after: 4)
        }
    }

    // MARK: - Queue Controls

    func pause() {
        isPaused = true
        processingQueue.pauseProcessing()
    }

    func resume() {
        isPaused = false
        processingQueue.resumeProcessing()
        startProcessingIfNeeded()
    }

    func pauseProcessing() { pause() }
    func resumeProcessing() { resume() }

    func togglePause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }


    // MARK: - Task Management

    func retryTask(_ task: ProcessingTask) {
        processingQueue.retryTask(task)
        refreshStats()
        startProcessingIfNeeded()
    }

    func retryTask(id: UUID) {
        if let task = queue.first(where: { $0.id == id }) {
            retryTask(task)
        }
    }

    func cancelTask(_ task: ProcessingTask) {
        if task.type == .generateThumbnail, let videoID = task.videoID {
            ThumbnailCoordinator.shared.cancel(videoID: videoID)
        }
        processingQueue.cancelTask(task)
        refreshStats()
        if task.type == .transcribe {
            Task {
                await transcriptionService.cancelCurrentTranscription()
            }
        }
        if task.type == .downloadRemoteVideo {
            remoteDownloadService.stopCurrentDownload()
        }
    }

    func pauseDownloadTask(_ task: ProcessingTask) {
        guard task.type == .downloadRemoteVideo, task.status == .processing else { return }
        do {
            try remoteDownloadService.pauseCurrentDownload()
            task.markAsPaused(message: "Download paused")
            refreshStats()
        } catch {
            task.errorMessage = error.localizedDescription
        }
    }

    func resumeDownloadTask(_ task: ProcessingTask) {
        guard task.type == .downloadRemoteVideo, task.status == .paused else { return }
        do {
            try remoteDownloadService.resumeCurrentDownload()
            task.markAsResumed(message: "Download resumed")
            refreshStats()
        } catch {
            task.errorMessage = error.localizedDescription
        }
    }

    func stopDownloadTask(_ task: ProcessingTask) {
        guard task.type == .downloadRemoteVideo, task.status == .processing || task.status == .paused else { return }
        task.markAsCancelled()
        task.statusMessage = "Download stopped"
        remoteDownloadService.stopCurrentDownload()
        refreshStats()
    }

    func cancelTask(id: UUID) {
        if let task = queue.first(where: { $0.id == id }) {
            cancelTask(task)
        }
    }

    func removeTask(_ task: ProcessingTask) {
        if task.type == .generateThumbnail,
           task.status.isActive,
           let videoID = task.videoID {
            ThumbnailCoordinator.shared.cancel(videoID: videoID)
        }
        processingQueue.removeTask(task)
        refreshStats()
    }

    func removeTask(id: UUID) {
        if let task = queue.first(where: { $0.id == id }) {
            removeTask(task)
        }
    }

    func clearCompleted() {
        processingQueue.clearCompleted()
        refreshStats()
    }

    func clearFailed() {
        processingQueue.clearFailed()
        refreshStats()
    }

    func clearAll() {
        for task in processingQueue.tasks where task.type == .generateThumbnail && task.status.isActive {
            if let videoID = task.videoID {
                ThumbnailCoordinator.shared.cancel(videoID: videoID)
            }
        }
        processingQueue.clearAll()
        refreshStats()
    }

    // MARK: - Lookup Helpers

    func task(for video: Video, type: ProcessingTaskType) -> ProcessingTask? {
        guard let id = video.id else { return nil }
        return processingQueue.taskForVideo(id, type: type)
    }

    func isProcessing(video: Video, type: ProcessingTaskType) -> Bool {
        guard let task = task(for: video, type: type) else { return false }
        return task.status == .processing
    }

}
