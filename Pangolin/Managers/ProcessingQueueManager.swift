// ProcessingQueueManager.swift
// Unified processing queue manager

import Foundation
import CoreData
import Combine

@MainActor
class ProcessingQueueManager: ObservableObject {
    private struct TaskFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = ProcessingQueueManager()

    private let processingQueue = ProcessingQueue()
    private var cancellables = Set<AnyCancellable>()
    private var workerTask: Task<Void, Never>?
    private var importFolderMaps: [UUID: [String: Folder]] = [:]

    let transcriptionService = SpeechTranscriptionService()
    private let fileSystemManager = FileSystemManager.shared
    private let videoFileManager = VideoFileManager.shared
    private let importer = VideoImporter()
    private let remoteDownloadService = RemoteVideoDownloadService()

    @Published var queue: [ProcessingTask] = []
    @Published var isPaused: Bool = false
    @Published var overallProgress: Double = 0.0
    @Published var activeTaskCount: Int = 0
    @Published var totalTaskCount: Int = 0
    @Published var completedTasks: Int = 0
    @Published var failedTasks: Int = 0

    var totalTasks: Int { totalTaskCount }
    var activeTasks: Int { activeTaskCount }
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

    // MARK: - Enqueue Helpers

    func enqueueImport(urls: [URL], library: Library, context: NSManagedObjectContext) async {
        if library.id == nil {
            library.id = UUID()
        }
        let plan = await importer.prepareImportPlan(from: urls, library: library, context: context)
        let libraryID = library.id
        if let libraryID {
            var mergedFolderMap = importFolderMaps[libraryID] ?? [:]
            mergedFolderMap.merge(plan.createdFolders) { _, new in new }
            importFolderMaps[libraryID] = mergedFolderMap
        }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print("⚠️ QUEUE: Failed to save pending folder changes before enqueueing import tasks: \(error)")
            }
        }

        for fileURL in plan.videoFiles {
            let task = ProcessingTask(
                sourceURL: fileURL,
                libraryID: libraryID,
                type: .importVideo,
                itemName: fileURL.lastPathComponent
            )
            processingQueue.addTask(task)
        }

        if plan.videoFiles.isEmpty {
            print("⚠️ QUEUE: No importable video files discovered in dropped items.")
        }
        refreshStats()
        startProcessingIfNeeded()
    }

    func enqueueRemoteImport(url: URL, library: Library, context: NSManagedObjectContext) async throws {
        guard let provider = RemoteVideoProvider.detect(from: url) else {
            throw TaskFailure(message: RemoteVideoDownloadError.unsupportedProvider.localizedDescription)
        }
        print("🌐 QUEUE: enqueueRemoteImport requested for \(url.absoluteString)")

        if library.id == nil {
            library.id = UUID()
        }

        if let existing = queue.first(where: { $0.type == .downloadRemoteVideo && $0.remoteURLString == url.absoluteString }) {
            switch existing.status {
            case .failed, .cancelled, .completed:
                print("🌐 QUEUE: Removing previous \(existing.status.rawValue) remote download task for same URL")
                processingQueue.removeTask(existing)
            case .pending, .waitingForDependencies, .processing, .paused:
                throw TaskFailure(message: "This URL is already in the download queue.")
            }
        }

        let downloadsFolder = await LibraryManager.shared.ensureTopLevelFolder(named: "Downloads")
        let task = ProcessingTask(
            remoteURL: url,
            provider: provider,
            libraryID: library.id,
            destinationFolderID: downloadsFolder?.id,
            itemName: url.host ?? "Remote URL",
            followUpTypes: [.transcribe]
        )
        processingQueue.addTask(task)
        print("🌐 QUEUE: Added remote download task \(task.id.uuidString) for \(url.absoluteString)")
        refreshStats()

        if context.hasChanges {
            try? context.save()
        }

        startProcessingIfNeeded()
    }

    func enqueueThumbnails(for videos: [Video], force: Bool = false) {
        let videoIDs = videos.compactMap { $0.id }
        for video in videos {
            guard let id = video.id else { continue }
            ensureDependencies(for: video, type: .generateThumbnail)
            if let existing = processingQueue.taskForVideo(id, type: .generateThumbnail) {
                if force {
                    processingQueue.removeTask(existing)
                } else {
                    continue
                }
            }
            let task = ProcessingTask(videoID: id, type: .generateThumbnail, itemName: video.title ?? video.fileName, force: force)
            processingQueue.addTask(task)
        }
        refreshStats()
        if !videoIDs.isEmpty {
            startProcessingIfNeeded()
        }
    }

    func enqueueTranscription(for videos: [Video], preferredLocale: Locale? = nil, force: Bool = false) {
        enqueueVideoTasks(for: videos, types: [.transcribe], force: force, preferredLocale: preferredLocale)
    }

    func enqueueTranslation(for videos: [Video], targetLocale: Locale? = nil, force: Bool = false) {
        enqueueVideoTasks(for: videos, types: [.translate], force: force, targetLocale: targetLocale)
    }

    func enqueueSummarization(
        for videos: [Video],
        force: Bool = false,
        preset: SpeechTranscriptionService.SummaryPreset = .detailed,
        customPrompt: String? = nil
    ) {
        let trimmedPrompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        enqueueVideoTasks(
            for: videos,
            types: [.summarize],
            force: force,
            summaryPreset: preset,
            summaryCustomPrompt: normalizedPrompt
        )
    }

    func enqueueFullWorkflow(for videos: [Video]) {
        enqueueVideoTasks(for: videos, types: [.ensureLocalAvailability, .generateThumbnail, .transcribe, .translate, .summarize], force: false)
    }

    func enqueueTranscriptionAndSummary(for videos: [Video]) {
        enqueueVideoTasks(for: videos, types: [.ensureLocalAvailability, .transcribe, .summarize], force: false)
    }

    func enqueueEnsureLocalAvailability(for videos: [Video], force: Bool = false) {
        enqueueVideoTasks(for: videos, types: [.ensureLocalAvailability], force: force)
    }

    private func enqueueVideoTasks(
        for videos: [Video],
        types: [ProcessingTaskType],
        force: Bool,
        preferredLocale: Locale? = nil,
        targetLocale: Locale? = nil,
        summaryPreset: SpeechTranscriptionService.SummaryPreset? = nil,
        summaryCustomPrompt: String? = nil
    ) {
        let videoIDs = videos.compactMap { $0.id }
        for video in videos {
            guard let id = video.id else { continue }
            for type in types {
                ensureDependencies(for: video, type: type)
                if let existing = processingQueue.taskForVideo(id, type: type) {
                    if force {
                        processingQueue.removeTask(existing)
                    } else if shouldKeepExistingTask(existing, videoID: id, type: type) {
                        continue
                    } else {
                        // Remove stale/non-blocking historical task and enqueue a fresh one.
                        processingQueue.removeTask(existing)
                    }
                }
                let task = ProcessingTask(
                    videoID: id,
                    type: type,
                    itemName: video.title ?? video.fileName,
                    force: force,
                    preferredLocaleIdentifier: preferredLocale?.identifier,
                    targetLocaleIdentifier: targetLocale?.identifier,
                    summaryPresetRawValue: type == .summarize ? summaryPreset?.rawValue : nil,
                    summaryCustomPrompt: type == .summarize ? summaryCustomPrompt : nil
                )
                processingQueue.addTask(task)
            }
        }
        refreshStats()
        if !videoIDs.isEmpty {
            startProcessingIfNeeded()
        }
    }

    // Backwards-compatible aliases used by views
    func addTranscriptionOnly(for videos: [Video]) { enqueueTranscription(for: videos) }
    func addTranslationOnly(for videos: [Video]) { enqueueTranslation(for: videos) }
    func addSummaryOnly(for videos: [Video]) { enqueueSummarization(for: videos) }
    func addFullProcessingWorkflow(for videos: [Video]) { enqueueFullWorkflow(for: videos) }
    func addTranscriptionAndSummary(for videos: [Video]) { enqueueTranscriptionAndSummary(for: videos) }
    func addThumbnailsOnly(for videos: [Video]) { enqueueThumbnails(for: videos) }

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

    // MARK: - Execution Loop

    private func startProcessingIfNeeded() {
        guard workerTask == nil, !isPaused else { return }
        workerTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if isPaused {
                workerTask = nil
                return
            }

            let readyTasks = processingQueue.getReadyTasks()
            guard let task = readyTasks.first else {
                workerTask = nil
                return
            }

            await execute(task)
        }
        workerTask = nil
    }

    private func execute(_ task: ProcessingTask) async {
        processingQueue.markTaskAsProcessing(task)
        refreshStats()
        print("⚙️ QUEUE: Starting task \(task.type.rawValue) [\(task.id.uuidString)] - \(task.itemName ?? "Unnamed")")

        if shouldSkip(task) {
            task.markAsCompleted()
            task.statusMessage = "Skipped (already generated)"
            processingQueue.markTaskAsFinished(task)
            refreshStats()
            return
        }

        do {
            switch task.type {
            case .downloadRemoteVideo:
                try await executeRemoteDownload(task)
            case .importVideo:
                try await executeImport(task)
            case .ensureLocalAvailability:
                try await executeEnsureLocalAvailability(task)
            case .generateThumbnail:
                try await executeThumbnail(task)
            case .transcribe:
                try await executeTranscription(task)
            case .translate:
                try await executeTranslation(task)
            case .summarize:
                try await executeSummarization(task)
            case .fileOperation:
                task.markAsCompleted()
            }
            if task.status != .failed && task.status != .cancelled && task.status != .paused {
                task.markAsCompleted()
            }
        } catch {
            if task.status != .cancelled {
                print("💥 QUEUE: Task failed \(task.type.rawValue) [\(task.id.uuidString)] - \(error.localizedDescription)")
                task.markAsFailed(error: error.localizedDescription)
            } else {
                print("⏹️ QUEUE: Task cancelled \(task.type.rawValue) [\(task.id.uuidString)]")
            }
        }

        processingQueue.markTaskAsFinished(task)
        refreshStats()
    }

    // MARK: - Task Implementations

    private func executeRemoteDownload(_ task: ProcessingTask) async throws {
        guard let remoteURLString = task.remoteURLString,
              let remoteURL = URL(string: remoteURLString) else {
            throw RemoteVideoDownloadError.invalidURL
        }
        guard RemoteVideoProvider.detect(from: remoteURL) != nil else {
            throw RemoteVideoDownloadError.unsupportedProvider
        }

        task.statusMessage = "Preparing download..."
        task.updateProgress(0.02, message: "Probing remote video...")
        print("🌐 DOWNLOAD: Probing URL \(remoteURL.absoluteString)")

        let result = try await remoteDownloadService.downloadVideo(from: remoteURL) { [weak task] update in
            guard let task else { return }
            Task { @MainActor in
                let progress = update.fractionCompleted.map { min(0.98, max(0.02, $0)) } ?? task.progress
                task.updateProgress(progress, message: update.message)
            }
        }

        let libraryID = task.libraryID
        let importTask = ProcessingTask(
            sourceURL: result.localFileURL,
            libraryID: libraryID,
            type: .importVideo,
            itemName: result.title ?? result.localFileURL.lastPathComponent,
            followUpTypes: task.followUpTypes,
            destinationFolderID: task.destinationFolderID
        )
        processingQueue.addTask(importTask)
        print("🌐 DOWNLOAD: Completed to staging file \(result.localFileURL.path)")
        refreshStats()
    }

    private func executeImport(_ task: ProcessingTask) async throws {
        guard let sourcePath = task.sourceURLPath else {
            throw FileSystemError.importFailed("Missing source path.")
        }
        guard let library = LibraryManager.shared.currentLibrary,
              let context = LibraryManager.shared.viewContext else {
            throw FileSystemError.invalidLibraryPath
        }
        if library.id == nil {
            library.id = UUID()
        }

        let fileURL = URL(fileURLWithPath: sourcePath)
        let folderMap = importFolderMaps[library.id ?? UUID()] ?? [:]

        task.statusMessage = "Importing \(fileURL.lastPathComponent)..."
        task.updateProgress(0.1, message: task.statusMessage)

        let video = try await importer.importSingleFile(fileURL, library: library, context: context, createdFolders: folderMap)

        if let destinationFolderID = task.destinationFolderID {
            assignImportedVideo(video, toFolderID: destinationFolderID, in: context, library: library)
        }

        try context.save()

        remoteDownloadService.cleanupStagingArtifacts(for: fileURL)

        await StoragePolicyManager.shared.applyPolicy(for: library)

        // Enqueue thumbnail if missing
        if video.thumbnailPath == nil, let id = video.id {
            let thumbTask = ProcessingTask(videoID: id, type: .generateThumbnail, itemName: video.title ?? video.fileName)
            processingQueue.addTask(thumbTask)
        }

        // Enqueue follow-ups if requested
        if !task.followUpTypes.isEmpty, let id = video.id {
            for type in task.followUpTypes {
                let followUp = ProcessingTask(videoID: id, type: type, itemName: video.title ?? video.fileName)
                processingQueue.addTask(followUp)
            }
        }
        refreshStats()
    }

    private func executeEnsureLocalAvailability(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }
        _ = try await videoFileManager.ensureLocalAvailability(for: video)
    }

    private func executeThumbnail(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task),
              let library = video.library else {
            throw FileSystemError.fileNotFound
        }

        let thumbnailPath = try await fileSystemManager.generateThumbnail(for: video, in: library)
        video.thumbnailPath = thumbnailPath
        if let context = LibraryManager.shared.viewContext {
            try context.save()
        }
    }

    private func executeTranscription(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }
        let preferredLocale: Locale? = {
            if let id = task.preferredLocaleIdentifier {
                return Locale(identifier: id)
            }
            return nil
        }()
        await transcriptionService.transcribeVideo(video, libraryManager: LibraryManager.shared, preferredLocale: preferredLocale)
        if let error = transcriptionService.errorMessage {
            throw TaskFailure(message: error)
        }

        enqueueAutoTranslationIfNeeded(afterTranscriptionFor: video)
    }

    private func executeTranslation(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }
        let targetLanguage: Locale.Language? = {
            if let id = task.targetLocaleIdentifier {
                return Locale(identifier: id).language
            }
            return nil
        }()
        await transcriptionService.translateVideo(video, libraryManager: LibraryManager.shared, targetLanguage: targetLanguage)
        if let error = transcriptionService.errorMessage {
            throw TranscriptionError.translationFailed(error)
        }
    }

    private func executeSummarization(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }
        let preset = task.summaryPresetRawValue.flatMap(SpeechTranscriptionService.SummaryPreset.init(rawValue:)) ?? .detailed
        await transcriptionService.summarizeVideo(
            video,
            libraryManager: LibraryManager.shared,
            preset: preset,
            customPrompt: task.summaryCustomPrompt
        )
        if let error = transcriptionService.errorMessage {
            throw TranscriptionError.summarizationFailed(error)
        }
    }

    // MARK: - Helpers

    private func ensureDependencies(for video: Video, type: ProcessingTaskType) {
        guard let id = video.id else { return }
        for dependency in type.dependencies {
            if let existingDependencyTask = processingQueue.taskForVideo(id, type: dependency) {
                switch existingDependencyTask.status {
                case .pending, .waitingForDependencies, .processing, .paused:
                    continue
                case .completed:
                    if hasRequiredData(videoID: id, type: dependency) {
                        continue
                    }
                    processingQueue.removeTask(existingDependencyTask)
                case .failed, .cancelled:
                    processingQueue.removeTask(existingDependencyTask)
                }
            }

            if !hasRequiredData(videoID: id, type: dependency) {
                let depTask = ProcessingTask(videoID: id, type: dependency, itemName: video.title ?? video.fileName)
                processingQueue.addTask(depTask)
            }
        }
    }

    private func refreshStats() {
        let tasks = processingQueue.tasks
        totalTaskCount = tasks.count
        completedTasks = tasks.filter { $0.status == .completed }.count
        failedTasks = tasks.filter { $0.status == .failed }.count
        activeTaskCount = tasks.filter { $0.status.isActive }.count
        overallProgress = processingQueue.overallProgress
    }

    private func fetchVideo(for task: ProcessingTask) -> Video? {
        guard let videoID = task.videoID,
              let context = LibraryManager.shared.viewContext else { return nil }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func shouldSkip(_ task: ProcessingTask) -> Bool {
        if task.force { return false }
        guard let videoID = task.videoID else { return false }
        if task.type == .translate, let target = task.targetLocaleIdentifier, let video = fetchVideo(for: task) {
            let targetLanguageCode = normalizedLanguageCode(from: Locale(identifier: target))
            let translatedLanguageCode = video.translatedLanguage.map { normalizedLanguageCode(from: Locale(identifier: $0)) } ?? nil
            if targetLanguageCode == translatedLanguageCode,
               let translatedLanguage = video.translatedLanguage,
               let text = video.translatedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               hasTimedTranslationArtifact(for: video, languageCode: translatedLanguage) {
                return true
            }
            return false
        }
        return hasRequiredData(videoID: videoID, type: task.type)
    }

    private func hasRequiredData(videoID: UUID, type: ProcessingTaskType) -> Bool {
        guard let context = LibraryManager.shared.viewContext else { return false }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
        request.fetchLimit = 1
        guard let video = (try? context.fetch(request))?.first else { return false }

        switch type {
        case .downloadRemoteVideo:
            return false
        case .importVideo:
            return false
        case .ensureLocalAvailability:
            if let url = video.fileURL {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return false
        case .generateThumbnail:
            return video.thumbnailPath != nil
        case .transcribe:
            if let text = video.transcriptText { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        case .translate:
            guard let text = video.translatedText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let translatedLanguage = video.translatedLanguage,
                  !translatedLanguage.isEmpty else {
                return false
            }
            return hasTimedTranslationArtifact(for: video, languageCode: translatedLanguage)
        case .summarize:
            if let text = video.transcriptSummary { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        case .fileOperation:
            return false
        }
    }

    private func hasTimedTranslationArtifact(for video: Video, languageCode: String) -> Bool {
        guard let url = LibraryManager.shared.timedTranslationURL(for: video, languageCode: languageCode) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func assignImportedVideo(_ video: Video, toFolderID folderID: UUID, in context: NSManagedObjectContext, library: Library) {
        let request = Folder.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        do {
            if let folder = try context.fetch(request).first, !folder.isSmartFolder {
                video.folder = folder
            } else {
                print("⚠️ QUEUE: Destination folder missing or invalid; importing without folder assignment")
            }
        } catch {
            print("⚠️ QUEUE: Failed to assign imported video to folder: \(error)")
        }
    }

    private func shouldKeepExistingTask(_ task: ProcessingTask, videoID: UUID, type: ProcessingTaskType) -> Bool {
        switch task.status {
        case .pending, .waitingForDependencies, .processing, .paused:
            return true
        case .completed:
            return hasRequiredData(videoID: videoID, type: type)
        case .failed, .cancelled:
            return false
        }
    }

    private func enqueueAutoTranslationIfNeeded(afterTranscriptionFor video: Video) {
        guard shouldAutoTranslateToSystemLanguage(for: video) else {
            return
        }
        enqueueTranslation(for: [video], targetLocale: .autoupdatingCurrent, force: true)
    }

    private func shouldAutoTranslateToSystemLanguage(for video: Video) -> Bool {
        guard let transcriptText = video.transcriptText,
              !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let transcriptLocale = resolvedTranscriptLocale(for: video)
        let transcriptLanguageCode = transcriptLocale.flatMap(normalizedLanguageCode)
        let systemLanguageCode = normalizedLanguageCode(from: .autoupdatingCurrent)

        guard let transcriptLanguageCode, let systemLanguageCode else {
            return false
        }

        return transcriptLanguageCode != systemLanguageCode
    }

    private func resolvedTranscriptLocale(for video: Video) -> Locale? {
        if let transcriptLanguageIdentifier = video.transcriptLanguage,
           !transcriptLanguageIdentifier.isEmpty {
            return Locale(identifier: transcriptLanguageIdentifier)
        }

        guard let timedURL = LibraryManager.shared.timedTranscriptURL(for: video),
              FileManager.default.fileExists(atPath: timedURL.path),
              let transcript = try? LibraryManager.shared.readTimedTranscript(from: timedURL),
              !transcript.localeIdentifier.isEmpty else {
            return nil
        }

        return Locale(identifier: transcript.localeIdentifier)
    }

    private func normalizedLanguageCode(from locale: Locale) -> String? {
        let code = locale.language.languageCode?.identifier
            ?? locale.identifier.split(separator: "-").first.map(String.init)
            ?? locale.identifier.split(separator: "_").first.map(String.init)
        return code?.lowercased()
    }
}
