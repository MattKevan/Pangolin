// ProcessingQueueManager.swift
// Background processing queue manager integrated with task queues

import Foundation
import SwiftUI
import CoreData

@MainActor
class ProcessingQueueManager: ObservableObject {
    static let shared = ProcessingQueueManager()

    @Published var processingQueue = ProcessingQueue()
    @Published var isProcessingActive = false

    // Delegate properties to ProcessingQueue
    var activeTaskCount: Int { processingQueue.activeTasks }
    var totalTaskCount: Int { processingQueue.totalTasks }
    var overallProgress: Double { processingQueue.overallProgress }
    var queue: [ProcessingTask] { processingQueue.tasks }
    var isPaused: Bool { processingQueue.isPaused }

    // Additional computed properties for compatibility
    var totalTasks: Int { processingQueue.totalTasks }
    var activeTasks: Int { processingQueue.activeTasks }
    var completedTasks: Int { processingQueue.completedTasks }
    var failedTasks: Int { processingQueue.failedTasks }

    private var processingTimer: Timer?
    private let coordinator = BackgroundProcessingCoordinator()

    private init() {
        startProcessingLoop()
    }

    // MARK: - Public Interface

    func addProcessingTasks(for videos: [Video], types: [ProcessingTaskType]) {
        for video in videos {
            for type in types {
                guard let videoID = video.id else { continue }
                let task = ProcessingTask(videoID: videoID, type: type)
                processingQueue.addTask(task)
            }
        }
        resumeProcessing()
    }

    func addAutoProcessingTasks(for videos: [Video], library: Library) {
        guard !videos.isEmpty else { return }

        var taskTypes: [ProcessingTaskType] = []

        if library.autoTranscribeOnImport {
            taskTypes.append(.transcribe)
        }

        if library.autoTranslateOnImport {
            taskTypes.append(.translate)
        }

        addProcessingTasks(for: videos, types: taskTypes)
        print("📋 PROCESSING: Added \(taskTypes.count * videos.count) auto-processing tasks for \(videos.count) videos")
    }

    // Legacy compatibility methods
    func addTranscriptionOnly(for videos: [Video]) {
        addProcessingTasks(for: videos, types: [.transcribe])
    }

    func addTranslationOnly(for videos: [Video]) {
        addProcessingTasks(for: videos, types: [.translate])
    }

    func addSummaryOnly(for videos: [Video]) {
        addProcessingTasks(for: videos, types: [.summarize])
    }

    func addFullProcessingWorkflow(for videos: [Video]) {
        addProcessingTasks(for: videos, types: [.transcribe, .translate, .summarize])
    }

    func addTranscriptionAndSummary(for videos: [Video]) {
        addProcessingTasks(for: videos, types: [.transcribe, .summarize])
    }

    // MARK: - Queue Control

    func resumeProcessing() {
        processingQueue.resumeProcessing()
    }

    func pauseProcessing() {
        processingQueue.pauseProcessing()
    }

    func togglePause() {
        processingQueue.togglePause()
    }

    func removeTask(_ task: ProcessingTask) {
        processingQueue.removeTask(task)
    }

    func removeTask(id: UUID) {
        if let task = processingQueue.tasks.first(where: { $0.id == id }) {
            removeTask(task)
        }
    }

    func retryTask(_ task: ProcessingTask) {
        processingQueue.retryTask(task)
    }

    func retryTask(id: UUID) {
        if let task = processingQueue.tasks.first(where: { $0.id == id }) {
            retryTask(task)
        }
    }

    func cancelTask(_ task: ProcessingTask) {
        processingQueue.cancelTask(task)
    }

    func cancelTask(id: UUID) {
        if let task = processingQueue.tasks.first(where: { $0.id == id }) {
            cancelTask(task)
        }
    }

    func clearCompleted() {
        processingQueue.clearCompleted()
    }

    func clearFailed() {
        processingQueue.clearFailed()
    }

    func clearAll() {
        processingQueue.clearAll()
    }

    func clearAllTasks() {
        clearAll()
    }

    // MARK: - Processing Loop

    private func startProcessingLoop() {
        processingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                await self.processNextTasks()
            }
        }
    }

    private func processNextTasks() async {
        guard !processingQueue.isPaused else { return }

        let readyTasks = processingQueue.getReadyTasks()

        for task in readyTasks {
            processingQueue.markTaskAsProcessing(task)

            // Dispatch to background processing coordinator
            Task.detached {
                await self.coordinator.executeTask(task)
            }
        }

        isProcessingActive = processingQueue.hasActiveTasks
    }
}

// MARK: - Background Processing Coordinator

@MainActor
class BackgroundProcessingCoordinator: ObservableObject {
    private let transcriptionService = SpeechTranscriptionService()
    private let summaryService = SummaryService()

    func executeTask(_ task: ProcessingTask) async {
        await MainActor.run { task.markAsStarted() }

        // Get video from Core Data
        guard let video = await getVideo(for: task.videoID) else {
            await MainActor.run {
                task.markAsFailed(error: "Video not found")
                ProcessingQueueManager.shared.processingQueue.markTaskAsFinished(task)
            }
            return
        }

        switch task.type {
        case .transcribe:
            await executeTranscription(task: task, video: video)
        case .translate:
            await executeTranslation(task: task, video: video)
        case .summarize:
            await executeSummarization(task: task, video: video)
        case .iCloudDownload:
            await executeDownload(task: task, video: video)
        }
    }

    private func executeTranscription(task: ProcessingTask, video: Video) async {
        do {
            // Progress callback for UI updates
            let progressCallback: (Double, String) -> Void = { progress, message in
                Task { @MainActor in
                    task.updateProgress(progress, message: message)
                }
            }

            // Perform transcription
            try await transcriptionService.transcribeVideo(video, progressCallback: progressCallback)

            await MainActor.run {
                task.markAsCompleted()
                ProcessingQueueManager.shared.processingQueue.markTaskAsFinished(task)
            }

        } catch {
            await MainActor.run {
                task.markAsFailed(error: error.localizedDescription)
                ProcessingQueueManager.shared.processingQueue.markTaskAsFinished(task)
            }
        }
    }

    private func executeTranslation(task: ProcessingTask, video: Video) async {
        // Translation logic will be implemented when translation service is available
        await MainActor.run {
            task.updateProgress(0.5, message: "Translation not yet implemented")
            task.markAsCompleted()
            ProcessingQueueManager.shared.processingQueue.markTaskAsFinished(task)
        }
    }

    private func executeSummarization(task: ProcessingTask, video: Video) async {
        await summaryService.generateSummary(for: video, libraryManager: LibraryManager.shared)

        await MainActor.run {
            if let error = summaryService.errorMessage, !error.isEmpty {
                task.markAsFailed(error: error)
            } else {
                task.markAsCompleted()
            }
            ProcessingQueueManager.shared.processingQueue.markTaskAsFinished(task)
        }
    }

    private func executeDownload(task: ProcessingTask, video: Video) async {
        // iCloud download logic (placeholder for now)
        await MainActor.run {
            task.updateProgress(1.0, message: "Download completed")
            task.markAsCompleted()
            ProcessingQueueManager.shared.processingQueue.markTaskAsFinished(task)
        }
    }

    // Helper method to get video from Core Data context
    private func getVideo(for videoID: UUID) async -> Video? {
        await MainActor.run {
            guard let context = LibraryManager.shared.viewContext else { return nil }

            let request: NSFetchRequest<Video> = Video.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }
}

// Legacy compatibility enum
enum TaskType {
    case iCloudDownload
    case thumbnailGeneration
    case transcription
    case constant
}
