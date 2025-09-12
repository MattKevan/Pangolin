import Foundation
import Combine
import CoreData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
class ProcessingQueueManager: ObservableObject {
    static let shared = ProcessingQueueManager()
    
    @Published private(set) var queue = ProcessingQueue()
    @Published private(set) var isInitialized = false
    
    private let transcriptionService = SpeechTranscriptionService()
    private var cancellables = Set<AnyCancellable>()
    private var processingTimer: Timer?
    
    private let persistenceKey = "ProcessingQueueData"
    private let processingInterval: TimeInterval = 1.0 // Check for new tasks every second
    
    init() {
        setupTimers()
        loadPersistedQueue()
        setupAppLifecycleNotifications()
        
        // Listen for queue changes to save state and trigger UI updates
        queue.objectWillChange.sink { [weak self] in
            self?.saveQueueState()
            // Use async dispatch to avoid "Publishing changes from within view updates"
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }.store(in: &cancellables)
    }
    
    deinit {
        processingTimer?.invalidate()
        cancellables.removeAll()
    }
    
    // MARK: - Queue Management
    
    func addTask(for video: Video, type: ProcessingTaskType) {
        guard let videoID = video.id else { return }
        
        // Check if video already has the required data
        if hasRequiredData(video: video, type: type) {
            return
        }
        
        let task = ProcessingTask(videoID: videoID, type: type)
        queue.addTask(task)
    }
    
    func addTasks(for video: Video, types: [ProcessingTaskType]) {
        for type in types {
            addTask(for: video, type: type)
        }
    }
    
    func addTasks(for videos: [Video], types: [ProcessingTaskType]) {
        for video in videos {
            addTasks(for: video, types: types)
        }
    }
    
    func removeTask(_ task: ProcessingTask) {
        queue.removeTask(task)
    }
    
    func cancelTask(_ task: ProcessingTask) {
        queue.cancelTask(task)
    }
    
    func retryTask(_ task: ProcessingTask) {
        queue.retryTask(task)
    }
    
    func pauseProcessing() {
        queue.pauseProcessing()
    }
    
    func resumeProcessing() {
        queue.resumeProcessing()
    }
    
    func clearCompleted() {
        queue.clearCompleted()
    }
    
    func clearFailed() {
        queue.clearFailed()
    }
    
    func clearAll() {
        queue.clearAll()
    }
    
    // MARK: - Processing Engine
    
    private func setupTimers() {
        processingTimer = Timer.scheduledTimer(withTimeInterval: processingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.processNextTasks()
            }
        }
    }
    
    private func setupAppLifecycleNotifications() {
        #if os(macOS)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.handleAppWillTerminate()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.saveQueueState()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.resumeProcessingIfNeeded()
                }
            }
            .store(in: &cancellables)
        #else
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.handleAppWillTerminate()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.saveQueueState()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.resumeProcessingIfNeeded()
                }
            }
            .store(in: &cancellables)
        #endif
    }
    
    private func processNextTasks() async {
        guard queue.isProcessing else { return }
        
        let readyTasks = queue.getReadyTasks()
        
        for task in readyTasks {
            queue.markTaskAsProcessing(task)
            
            // Process task asynchronously
            Task {
                await processTask(task)
            }
        }
    }
    
    private func processTask(_ task: ProcessingTask) async {
        do {
            guard let video = await getVideo(for: task.videoID) else {
                await MainActor.run {
                    task.markAsFailed(error: "Video not found")
                    queue.markTaskAsFinished(task)
                }
                return
            }
            
            switch task.type {
            case .transcribe:
                await processTranscription(task: task, video: video)
            case .translate:
                await processTranslation(task: task, video: video)
            case .summarize:
                await processSummarization(task: task, video: video)
            case .iCloudDownload:
                await processICloudDownload(task: task, video: video)
            }
            
        } catch {
            await MainActor.run {
                task.markAsFailed(error: error.localizedDescription)
                queue.markTaskAsFinished(task)
            }
        }
    }
    
    // MARK: - Task Processing Methods
    
    private func processTranscription(task: ProcessingTask, video: Video) async {
        // Set up progress monitoring
        let progressCancellable = transcriptionService.$progress.sink { progress in
            Task { @MainActor in
                task.updateProgress(progress, message: "Transcribing audio...")
            }
        }
        
        let statusCancellable = transcriptionService.$statusMessage.sink { message in
            Task { @MainActor in
                if !message.isEmpty {
                    task.updateProgress(task.progress, message: message)
                }
            }
        }
        
        defer {
            progressCancellable.cancel()
            statusCancellable.cancel()
        }
        
        // Get library manager from the video
        guard let libraryManager = await getLibraryManager(for: video) else {
            await MainActor.run {
                task.markAsFailed(error: "Library manager not available")
                queue.markTaskAsFinished(task)
            }
            return
        }
        
        do {
            await transcriptionService.transcribeVideo(video, libraryManager: libraryManager)
            
            await MainActor.run {
                if let errorMessage = transcriptionService.errorMessage {
                    task.markAsFailed(error: errorMessage)
                } else {
                    task.markAsCompleted()
                }
                queue.markTaskAsFinished(task)
            }
        } catch {
            await MainActor.run {
                task.markAsFailed(error: error.localizedDescription)
                queue.markTaskAsFinished(task)
            }
        }
    }
    
    private func processTranslation(task: ProcessingTask, video: Video) async {
        let progressCancellable = transcriptionService.$progress.sink { progress in
            Task { @MainActor in
                task.updateProgress(progress, message: "Translating text...")
            }
        }
        
        let statusCancellable = transcriptionService.$statusMessage.sink { message in
            Task { @MainActor in
                if !message.isEmpty {
                    task.updateProgress(task.progress, message: message)
                }
            }
        }
        
        defer {
            progressCancellable.cancel()
            statusCancellable.cancel()
        }
        
        guard let libraryManager = await getLibraryManager(for: video) else {
            await MainActor.run {
                task.markAsFailed(error: "Library manager not available")
                queue.markTaskAsFinished(task)
            }
            return
        }
        
        do {
            await transcriptionService.translateVideo(video, libraryManager: libraryManager)
            
            await MainActor.run {
                if let errorMessage = transcriptionService.errorMessage {
                    task.markAsFailed(error: errorMessage)
                } else {
                    task.markAsCompleted()
                }
                queue.markTaskAsFinished(task)
            }
        } catch {
            await MainActor.run {
                task.markAsFailed(error: error.localizedDescription)
                queue.markTaskAsFinished(task)
            }
        }
    }
    
    private func processSummarization(task: ProcessingTask, video: Video) async {
        let summarizingCancellable = transcriptionService.$isSummarizing.sink { isSummarizing in
            Task { @MainActor in
                if isSummarizing {
                    task.updateProgress(0.5, message: "Generating summary with Apple Intelligence...")
                }
            }
        }
        
        let statusCancellable = transcriptionService.$statusMessage.sink { message in
            Task { @MainActor in
                if !message.isEmpty {
                    task.updateProgress(task.progress, message: message)
                }
            }
        }
        
        defer {
            summarizingCancellable.cancel()
            statusCancellable.cancel()
        }
        
        guard let libraryManager = await getLibraryManager(for: video) else {
            await MainActor.run {
                task.markAsFailed(error: "Library manager not available")
                queue.markTaskAsFinished(task)
            }
            return
        }
        
        do {
            await transcriptionService.summarizeVideo(video, libraryManager: libraryManager)
            
            await MainActor.run {
                if let errorMessage = transcriptionService.errorMessage {
                    task.markAsFailed(error: errorMessage)
                } else {
                    task.markAsCompleted()
                }
                queue.markTaskAsFinished(task)
            }
        } catch {
            await MainActor.run {
                task.markAsFailed(error: error.localizedDescription)
                queue.markTaskAsFinished(task)
            }
        }
    }
    
    private func processICloudDownload(task: ProcessingTask, video: Video) async {
        do {
            await MainActor.run {
                task.updateProgress(0.1, message: "Starting iCloud download...")
            }
            
            // Use VideoFileManager to handle the download
            let videoFileManager = VideoFileManager.shared
            let fileURL = try await videoFileManager.getVideoFileURL(for: video, downloadIfNeeded: true)
            
            await MainActor.run {
                task.updateProgress(1.0, message: "Download complete")
                task.markAsCompleted()
                queue.markTaskAsFinished(task)
            }
            
            print("✅ Successfully downloaded video from iCloud: \(fileURL)")
            
        } catch {
            await MainActor.run {
                task.markAsFailed(error: "iCloud download failed: \(error.localizedDescription)")
                queue.markTaskAsFinished(task)
            }
            print("❌ iCloud download failed: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func hasRequiredData(video: Video, type: ProcessingTaskType) -> Bool {
        switch type {
        case .transcribe:
            return video.transcriptText != nil && !video.transcriptText!.isEmpty
        case .translate:
            return video.translatedText != nil && !video.translatedText!.isEmpty
        case .summarize:
            return video.transcriptSummary != nil && !video.transcriptSummary!.isEmpty
        case .iCloudDownload:
            return false // Always allow iCloud download tasks to be processed
        }
    }
    
    private func getVideo(for videoID: UUID) async -> Video? {
        guard let context = LibraryManager.shared.viewContext else { return nil }
        
        return await context.perform {
            let request = Video.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
            request.fetchLimit = 1
            
            return try? context.fetch(request).first
        }
    }
    
    private func getLibraryManager(for video: Video) async -> LibraryManager? {
        return LibraryManager.shared.isLibraryOpen ? LibraryManager.shared : nil
    }
    
    // MARK: - Persistence
    
    private func loadPersistedQueue() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else {
            isInitialized = true
            return
        }
        
        queue.loadTasksData(data)
        isInitialized = true
    }
    
    private func saveQueueState() {
        guard isInitialized else { return }
        
        if let data = queue.getTasksData() {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
    
    private func handleAppWillTerminate() {
        // Cancel any actively processing tasks and save state
        for task in queue.currentlyProcessing {
            task.reset() // Reset to pending state for restart
        }
        saveQueueState()
    }
    
    private func resumeProcessingIfNeeded() async {
        // Check if there are tasks that should be processing
        if !queue.isPaused && queue.hasActiveTasks {
            queue.resumeProcessing()
        }
    }
    
    // MARK: - Queue Statistics
    
    var hasActiveTasks: Bool {
        queue.hasActiveTasks
    }
    
    var overallProgress: Double {
        queue.overallProgress
    }
    
    var totalTasks: Int {
        queue.totalTasks
    }
    
    var completedTasks: Int {
        queue.completedTasks
    }
    
    var failedTasks: Int {
        queue.failedTasks
    }
    
    var activeTasks: Int {
        queue.activeTasks
    }
    
    // MARK: - Convenience Methods
    
    func addFullProcessingWorkflow(for videos: [Video]) {
        let types: [ProcessingTaskType] = [.transcribe, .translate, .summarize]
        addTasks(for: videos, types: types)
    }
    
    func addTranscriptionAndSummary(for videos: [Video]) {
        let types: [ProcessingTaskType] = [.transcribe, .summarize]
        addTasks(for: videos, types: types)
    }
    
    func addTranscriptionOnly(for videos: [Video]) {
        addTasks(for: videos, types: [.transcribe])
    }
    
    func addTranslationOnly(for videos: [Video]) {
        addTasks(for: videos, types: [.translate])
    }
    
    func addSummaryOnly(for videos: [Video]) {
        addTasks(for: videos, types: [.summarize])
    }
}

// MARK: - Notification Support

extension ProcessingQueueManager {
    func postTaskCompletedNotification(for task: ProcessingTask) {
        // Could post local notifications when tasks complete
        // Especially useful for long-running operations
    }
    
    func postQueueCompletedNotification() {
        // Notify when entire queue is finished
        if !queue.hasActiveTasks && queue.totalTasks > 0 {
            // All tasks completed
        }
    }
}