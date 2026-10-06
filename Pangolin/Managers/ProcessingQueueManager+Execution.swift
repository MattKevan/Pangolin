import os
import Foundation
import CoreData
import Combine
// MARK: - Execution loop, task implementations, helpers

extension ProcessingQueueManager {
    // MARK: - Execution Loop

    func startProcessingIfNeeded() {
        guard workerTask == nil, !isPaused else { return }
        workerTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func runLoop() async {
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

    func execute(_ task: ProcessingTask) async {
        processingQueue.markTaskAsProcessing(task)
        refreshStats()
        Logger.queue.info("QUEUE: Starting task \(task.type.rawValue) [\(task.id.uuidString)] - \(task.itemName ?? "Unnamed")")

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
            case .generateFlashcards:
                try await executeFlashcardsGeneration(task)
            case .fileOperation:
                task.markAsCompleted()
            }
            if task.status != .failed && task.status != .cancelled && task.status != .paused {
                task.markAsCompleted()
            }
        } catch {
            if task.status != .cancelled {
                Logger.queue.error("QUEUE: Task failed \(task.type.rawValue) [\(task.id.uuidString)] - \(error.localizedDescription)")
                task.markAsFailed(error: error.localizedDescription)
            } else {
                Logger.queue.info("QUEUE: Task cancelled \(task.type.rawValue) [\(task.id.uuidString)]")
            }
        }

        processingQueue.markTaskAsFinished(task)
        refreshStats()
    }

    // MARK: - Task Implementations

    func executeRemoteDownload(_ task: ProcessingTask) async throws {
        guard let remoteURLString = task.remoteURLString,
              let remoteURL = URL(string: remoteURLString) else {
            throw RemoteVideoDownloadError.invalidURL
        }
        guard RemoteVideoProvider.detect(from: remoteURL) != nil else {
            throw RemoteVideoDownloadError.unsupportedProvider
        }

        task.statusMessage = "Preparing download..."
        task.updateProgress(0.02, message: "Probing remote video...")
        Logger.queue.info("DOWNLOAD: Probing URL \(remoteURL.absoluteString)")

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
            destinationFolderID: task.destinationFolderID,
            originalRemoteURLString: result.originalURL.absoluteString,
            remoteVideoIdentifier: result.videoIdentifier
        )
        processingQueue.addTask(importTask)
        Logger.queue.info("DOWNLOAD: Completed to staging file \(result.localFileURL.path)")
        refreshStats()
    }

    func executeImport(_ task: ProcessingTask) async throws {
        let currentLibrary = LibraryManager.shared.currentLibrary
        guard let libraryID = ImportLibraryResolution.resolve(
            taskLibraryID: task.libraryID,
            currentLibraryID: currentLibrary?.id
        ),
        let library = library(withID: libraryID) ?? currentLibrary,
        let context = LibraryManager.shared.viewContext else {
            throw FileSystemError.importFailed(
                "The library this import was queued for is no longer open. Reopen it and try again."
            )
        }
        if library.id == nil {
            library.id = libraryID
        }

        let resolvedSource = try resolveImportSourceURL(for: task)
        let fileURL = resolvedSource.url
        var bookmarkAccessing = resolvedSource.isAccessingBookmark

        #if os(macOS)
        defer {
            if bookmarkAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        #endif
        let folderMap = importFolderMaps[libraryID] ?? [:]

        let optimizationPreset = library.uploadOptimizationPreset
        task.statusMessage = optimizationPreset.isEnabled
            ? "Optimising \(fileURL.lastPathComponent)..."
            : "Importing \(fileURL.lastPathComponent)..."
        task.updateProgress(0.1, message: task.statusMessage)

        let optimization = try await videoUploadOptimizer.optimizeIfNeeded(
            sourceURL: fileURL,
            preset: optimizationPreset
        )
        defer {
            if optimization.didOptimize {
                Task { await videoUploadOptimizer.removeTemporaryOutput(at: optimization.url) }
            }
        }
        task.statusMessage = optimization.didOptimize
            ? "Importing optimised \(fileURL.lastPathComponent)..."
            : "Importing \(fileURL.lastPathComponent)..."
        task.updateProgress(0.35, message: task.statusMessage)

        let video = try await importer.importSingleFile(
            optimization.url,
            library: library,
            context: context,
            createdFolders: folderMap,
            originalSourceURL: fileURL
        )

        if let originalRemoteURLString = task.originalRemoteURLString, !originalRemoteURLString.isEmpty {
            video.originalURL = originalRemoteURLString
        }
        if let remoteVideoIdentifier = task.remoteVideoIdentifier, !remoteVideoIdentifier.isEmpty {
            video.remoteVideoID = remoteVideoIdentifier
        }

        if let destinationFolderID = task.destinationFolderID {
            assignImportedVideo(video, toFolderID: destinationFolderID, in: context, library: library)
        }

        if shouldSaveImportedVideos(for: task, libraryID: library.id) {
            try context.save()
        }

        remoteDownloadService.cleanupStagingArtifacts(for: fileURL)

        // Enqueue follow-ups if requested
        if !task.followUpTypes.isEmpty, let id = video.id {
            for type in task.followUpTypes {
                if type == .generateThumbnail {
                    enqueueThumbnails(for: [video])
                    continue
                }
                let followUp = ProcessingTask(
                    videoID: id,
                    libraryID: video.library?.id,
                    type: type,
                    itemName: video.title ?? video.fileName
                )
                processingQueue.addTask(followUp)
            }
        }
        refreshStats()
    }

    /// Resolves the source URL for an import task, starting a security-scoped
    /// bookmark access when one is available (macOS only).
    func resolveImportSourceURL(for task: ProcessingTask) throws -> (url: URL, isAccessingBookmark: Bool) {
        #if os(macOS)
        if let bookmark = task.sourceBookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let accessing = resolved.startAccessingSecurityScopedResource()
                Logger.queue.info("QUEUE: Resolved bookmark, accessing=\(accessing) for \(resolved.lastPathComponent)")
                return (resolved, accessing)
            } else if let sourcePath = task.sourceURLPath {
                Logger.queue.warning("QUEUE: Bookmark resolution failed, falling back to plain path")
                return (URL(fileURLWithPath: sourcePath), false)
            } else {
                throw FileSystemError.importFailed("Missing source path.")
            }
        } else if let sourcePath = task.sourceURLPath {
            Logger.queue.warning("QUEUE: No bookmark, using plain path")
            return (URL(fileURLWithPath: sourcePath), false)
        } else {
            throw FileSystemError.importFailed("Missing source path.")
        }
        #else
        guard let sourcePath = task.sourceURLPath else {
            throw FileSystemError.importFailed("Missing source path.")
        }
        return (URL(fileURLWithPath: sourcePath), false)
        #endif
    }

    func executeEnsureLocalAvailability(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }
        task.updateProgress(0.02, message: "Checking local availability...")

        let progressMonitorTask = makeEnsureLocalAvailabilityProgressMonitor(task: task, videoID: video.id)
        defer { progressMonitorTask?.cancel() }

        do {
            _ = try await videoFileManager.ensureLocalAvailability(for: video)
            task.updateProgress(1.0, message: "Available locally")
        } catch VideoFileError.downloadCancelled {
            // The user cancelled the download; finish the task as completed so it
            // doesn't surface as a failure in the task indicator.
            task.updateProgress(1.0, message: "Download cancelled")
        }
    }

    func executeThumbnail(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }

        try await ThumbnailCoordinator.shared.generateThumbnail(
            for: video,
            force: task.force
        ) { stage in
            let update = ThumbnailTaskPresentation.update(for: stage)
            task.updateProgress(update.progress, message: update.message)
        }
        guard video.hasCurrentThumbnail else {
            throw TaskFailure(message: "Thumbnail generation completed without valid current thumbnail data.")
        }
        task.updateProgress(1.0, message: "Thumbnail ready")
    }

    func executeTranscription(_ task: ProcessingTask) async throws {
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

    func executeTranslation(_ task: ProcessingTask) async throws {
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

    func executeSummarization(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }
        await transcriptionService.summarizeVideo(
            video,
            libraryManager: LibraryManager.shared,
            customPrompt: task.summaryCustomPrompt
        )
        if let error = transcriptionService.errorMessage {
            throw TranscriptionError.summarizationFailed(error)
        }
    }

    func executeFlashcardsGeneration(_ task: ProcessingTask) async throws {
        guard let video = fetchVideo(for: task) else {
            throw FileSystemError.fileNotFound
        }

        let sourceMode = FlashcardsSourceMode(rawValue: task.flashcardsSourceModeRawValue ?? "")
            ?? .autoSystemLanguage
        let count = max(1, task.flashcardsCount ?? 12)
        await transcriptionService.generateFlashcards(
            for: video,
            libraryManager: LibraryManager.shared,
            sourceMode: sourceMode,
            targetCount: count,
            customPrompt: task.flashcardsCustomPrompt
        )
        if let error = transcriptionService.errorMessage {
            throw TranscriptionError.flashcardsGenerationFailed(error)
        }
    }

    // MARK: - Helpers

    func enqueueThumbnailTask(for video: Video, force: Bool) {
        guard let id = video.id,
              let libraryID = video.library?.id,
              !closingThumbnailLibraryIDs.contains(libraryID),
              ThumbnailWorkPolicy.needsGeneration(
                  data: video.thumbnailData,
                  version: video.thumbnailGenerationVersion,
                  force: force
              ) else { return }

        enqueueValidatedThumbnailTask(
            videoID: id,
            libraryID: libraryID,
            itemName: video.title ?? video.fileName,
            force: force
        )
    }

    func enqueueValidatedThumbnailTask(
        videoID: UUID,
        libraryID: UUID,
        itemName: String?,
        force: Bool
    ) {
        guard !closingThumbnailLibraryIDs.contains(libraryID) else { return }
        let existingTasks = thumbnailTasks(for: videoID, libraryID: libraryID)
        let existing = existingTasks.first(where: { $0.status.isActive }) ?? existingTasks.first
        switch ThumbnailTaskEnqueuePolicy.action(existingStatus: existing?.status, force: force) {
        case .coalesce:
            return
        case .replace:
            if existingTasks.contains(where: { $0.status.isActive }) {
                ThumbnailCoordinator.shared.cancel(videoID: videoID)
            }
            for existingTask in existingTasks {
                if existingTask.status.isActive {
                    processingQueue.cancelTask(existingTask)
                }
                processingQueue.removeTask(existingTask)
            }
        case .enqueue:
            break
        }

        let task = ProcessingTask(
            videoID: videoID,
            libraryID: libraryID,
            type: .generateThumbnail,
            itemName: itemName,
            force: force
        )
        processingQueue.addTask(task)
    }

    func thumbnailTasks(for videoID: UUID, libraryID: UUID) -> [ProcessingTask] {
        processingQueue.tasks.filter {
            $0.videoID == videoID
                && $0.type == .generateThumbnail
                && ($0.libraryID == libraryID || $0.libraryID == nil)
        }
    }

    func startThumbnailReconciliationScan(for libraryID: UUID) {
        guard !closingThumbnailLibraryIDs.contains(libraryID),
              LibraryManager.shared.isLibraryOpen,
              LibraryManager.shared.currentLibrary?.id == libraryID,
              let persistentStoreCoordinator = LibraryManager.shared.viewContext?.persistentStoreCoordinator else { return }

        if thumbnailReconciliationScanTask != nil {
            thumbnailReconciliationRescanLibraryID = libraryID
            if thumbnailReconciliationScanLibraryID != libraryID {
                thumbnailReconciliationScanTask?.cancel()
            }
            return
        }

        let token = UUID()
        thumbnailReconciliationScanLibraryID = libraryID
        thumbnailReconciliationScanToken = token
        thumbnailReconciliationScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ids = (try? await ThumbnailReconciliationScanner().videoIDsNeedingGeneration(
                libraryID: libraryID,
                persistentStoreCoordinator: persistentStoreCoordinator
            )) ?? []
            guard !Task.isCancelled,
                  !self.closingThumbnailLibraryIDs.contains(libraryID),
                  LibraryManager.shared.isLibraryOpen,
                  LibraryManager.shared.currentLibrary?.id == libraryID else {
                self.finishThumbnailReconciliationScan(libraryID: libraryID, token: token)
                return
            }
            self.enqueueValidatedThumbnailIDs(ids, libraryID: libraryID)
            self.finishThumbnailReconciliationScan(libraryID: libraryID, token: token)
        }
    }

    func enqueueValidatedThumbnailIDs(_ videoIDs: [UUID], libraryID: UUID) {
        guard !closingThumbnailLibraryIDs.contains(libraryID),
              !videoIDs.isEmpty,
              let context = LibraryManager.shared.viewContext else { return }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(
            format: "id IN %@ AND library.id == %@",
            videoIDs,
            libraryID as CVarArg
        )
        let videos = (try? context.fetch(request)) ?? []
        for video in videos {
            guard let videoID = video.id else { continue }
            enqueueValidatedThumbnailTask(
                videoID: videoID,
                libraryID: libraryID,
                itemName: video.title ?? video.fileName,
                force: false
            )
        }
        refreshStats()
        startProcessingIfNeeded()
    }

    func finishThumbnailReconciliationScan(libraryID: UUID, token: UUID) {
        guard thumbnailReconciliationScanToken == token else { return }
        thumbnailReconciliationScanTask = nil
        thumbnailReconciliationScanLibraryID = nil
        thumbnailReconciliationScanToken = nil
        let pendingLibraryID = thumbnailReconciliationRescanLibraryID
        thumbnailReconciliationRescanLibraryID = nil
        if let pendingLibraryID {
            startThumbnailReconciliationScan(for: pendingLibraryID)
        }
    }

    func ensureDependencies(for video: Video, type: ProcessingTaskType) {
        guard type != .generateThumbnail else { return }
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

    func existingImportRecords(
        in library: Library,
        context: NSManagedObjectContext
    ) -> [ImportedVideoRecord] {
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)

        return ((try? context.fetch(request)) ?? []).map { video in
            ImportedVideoRecord(
                sourcePath: video.sourcePath,
                fileName: video.fileName,
                fileSize: video.fileSize
            )
        }
    }

    func shouldSaveImportedVideos(for task: ProcessingTask, libraryID: UUID?) -> Bool {
        guard let libraryID else { return true }

        let completedImports = (pendingImportSaveCounts[libraryID] ?? 0) + 1
        pendingImportSaveCounts[libraryID] = completedImports

        let hasMoreImports = hasPendingImportTasks(for: libraryID, excluding: task.id)
        guard completedImports >= importSaveBatchSize || !hasMoreImports else { return false }

        pendingImportSaveCounts[libraryID] = 0
        return true
    }

    func hasPendingImportTasks(for libraryID: UUID, excluding taskID: UUID? = nil) -> Bool {
        processingQueue.tasks.contains { task in
            task.id != taskID
                && task.libraryID == libraryID
                && task.type == .importVideo
                && (task.status == .pending || task.status == .processing)
        }
    }

    func library(withID libraryID: UUID) -> Library? {
        guard let context = LibraryManager.shared.viewContext else { return nil }
        let request = Library.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    func refreshStats() {
        let tasks = processingQueue.tasks
        totalTaskCount = tasks.count
        completedTasks = tasks.filter { $0.status == .completed }.count
        failedTasks = tasks.filter { $0.status == .failed }.count
        activeTaskCount = tasks.filter { $0.status.isActive }.count
        overallProgress = processingQueue.overallProgress
    }

    func makeEnsureLocalAvailabilityProgressMonitor(task: ProcessingTask, videoID: UUID?) -> Task<Void, Never>? {
        guard let videoID else { return nil }

        return Task { @MainActor [weak self, weak task] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let task else { return }

                if task.status != .processing && task.status != .paused {
                    return
                }

                if let snapshot = self.videoFileManager.transferSnapshots[videoID] {
                    switch snapshot.state {
                    case .downloading(let progress):
                        let resolved = progress ?? max(task.progress, 0.02)
                        task.updateProgress(resolved, message: snapshot.displayName)
                    case .downloaded:
                        task.updateProgress(1.0, message: "Available locally")
                    case .inCloudOnly:
                        task.updateProgress(max(task.progress, 0.02), message: "Waiting for iCloud download...")
                    case .queuedForUploading, .uploading:
                        break
                    case .error(_, let message, _, _):
                        task.statusMessage = message
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func cloudSyncActiveDetail() -> String {
        let labels = Array(Set(activeCloudSyncEvents.values.map { cloudSyncOperationLabel(for: $0.type) })).sorted()
        if labels.isEmpty {
            return "Syncing iCloud metadata"
        }
        if labels.count == 1 {
            return "\(labels[0]) in progress"
        }
        return "Syncing iCloud metadata (\(activeCloudSyncEvents.count) operations)"
    }

    func bindUnscopedCloudImports(from sourceID: UUID, to libraryID: UUID) {
        let unboundEventIDs = activeCloudSyncEvents.compactMap { eventID, event in
            event.sourceID == sourceID && event.libraryID == nil ? eventID : nil
        }
        for eventID in unboundEventIDs {
            activeCloudSyncEvents[eventID]?.libraryID = libraryID
        }
        thumbnailReconciliationGate.bindUnscopedImports(from: sourceID, to: libraryID)
    }

    func recomputeCloudSyncQueueStatus() {
        guard !activeCloudSyncEvents.isEmpty else {
            cloudSyncQueueStatus = nil
            return
        }
        cloudSyncQueueStatus = CloudSyncQueueStatus(
            phase: .syncing,
            detail: cloudSyncActiveDetail(),
            activeOperationCount: activeCloudSyncEvents.count,
            updatedAt: Date()
        )
    }

    func cloudSyncOperationLabel(for type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup:
            return "Preparing iCloud sync"
        case .import:
            return "Downloading changes from iCloud"
        case .export:
            return "Uploading changes to iCloud"
        @unknown default:
            return "Syncing iCloud"
        }
    }

    func scheduleCloudSyncStatusHide(after delaySeconds: TimeInterval) {
        cloudSyncHideTask?.cancel()
        cloudSyncHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delaySeconds)))
            await MainActor.run {
                guard let self else { return }
                if self.activeCloudSyncEvents.isEmpty {
                    self.cloudSyncQueueStatus = nil
                }
            }
        }
    }

    func fetchVideo(for task: ProcessingTask) -> Video? {
        guard let videoID = task.videoID,
              ThumbnailTaskScope.canRun(
                  taskLibraryID: task.libraryID,
                  currentLibraryID: LibraryManager.shared.currentLibrary?.id
              ),
              let context = LibraryManager.shared.viewContext else { return nil }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    func shouldSkip(_ task: ProcessingTask) -> Bool {
        if task.force { return false }
        guard let videoID = task.videoID else { return false }
        if task.type == .generateThumbnail {
            return fetchVideo(for: task)?.hasCurrentThumbnail == true
        }
        if task.type == .generateFlashcards, let video = fetchVideo(for: task) {
            return hasFlashcardsArtifact(for: video)
        }
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

    func hasRequiredData(videoID: UUID, type: ProcessingTaskType) -> Bool {
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
            return video.hasCurrentThumbnail
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
        case .generateFlashcards:
            return hasFlashcardsArtifact(for: video)
        case .fileOperation:
            return false
        }
    }

    func hasTimedTranslationArtifact(for video: Video, languageCode: String) -> Bool {
        guard let url = LibraryManager.shared.textArtifacts.existingTimedTranslationURL(for: video, languageCode: languageCode) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func hasFlashcardsArtifact(for video: Video) -> Bool {
        guard let url = LibraryManager.shared.textArtifacts.existingFlashcardsURL(for: video) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func hasSystemLanguageTranslation(for video: Video) -> Bool {
        guard let translatedLanguage = video.translatedLanguage,
              !translatedLanguage.isEmpty,
              let translatedLanguageCode = normalizedLanguageCode(from: Locale(identifier: translatedLanguage)),
              let systemLanguageCode = normalizedLanguageCode(from: .autoupdatingCurrent),
              translatedLanguageCode == systemLanguageCode,
              let translatedText = video.translatedText,
              !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return hasTimedTranslationArtifact(for: video, languageCode: translatedLanguage)
    }

    func assignImportedVideo(_ video: Video, toFolderID folderID: UUID, in context: NSManagedObjectContext, library: Library) {
        let request = Folder.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, folderID as CVarArg)
        do {
            if let folder = try context.fetch(request).first, !folder.isSmartFolder {
                video.folder = folder
            } else {
                Logger.queue.warning("QUEUE: Destination folder missing or invalid; importing without folder assignment")
            }
        } catch {
            Logger.queue.warning("QUEUE: Failed to assign imported video to folder: \(error)")
        }
    }

    func shouldKeepExistingTask(_ task: ProcessingTask, videoID: UUID, type: ProcessingTaskType) -> Bool {
        switch task.status {
        case .pending, .waitingForDependencies, .processing, .paused:
            return true
        case .completed:
            return hasRequiredData(videoID: videoID, type: type)
        case .failed, .cancelled:
            return false
        }
    }

    func enqueueAutoTranslationIfNeeded(afterTranscriptionFor video: Video) {
        guard videoPagePreferences.isAutoTranslateEnabled,
              shouldAutoTranslateToSystemLanguage(for: video) else {
            return
        }
        let targetLocale = preferredAutoTranslationLocale()
        enqueueTranslation(for: [video], targetLocale: targetLocale, force: true)
    }

    func shouldAutoTranslateToSystemLanguage(for video: Video) -> Bool {
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

    func resolvedTranscriptLocale(for video: Video) -> Locale? {
        if let transcriptLanguageIdentifier = video.transcriptLanguage,
           !transcriptLanguageIdentifier.isEmpty {
            return Locale(identifier: transcriptLanguageIdentifier)
        }

        guard let timedURL = LibraryManager.shared.textArtifacts.existingTimedTranscriptURL(for: video),
              FileManager.default.fileExists(atPath: timedURL.path),
              let transcript = try? LibraryManager.shared.textArtifacts.readTimedTranscript(from: timedURL),
              !transcript.localeIdentifier.isEmpty else {
            return nil
        }

        return Locale(identifier: transcript.localeIdentifier)
    }

    func normalizedLanguageCode(from locale: Locale) -> String? {
        let code = locale.language.languageCode?.identifier
            ?? locale.identifier.split(separator: "-").first.map(String.init)
            ?? locale.identifier.split(separator: "_").first.map(String.init)
        return code?.lowercased()
    }

    func preferredAutoTranslationLocale() -> Locale? {
        if let storedIdentifier = videoPagePreferences.preferredTranslationLocaleIdentifier,
           !storedIdentifier.isEmpty {
            return Locale(identifier: storedIdentifier)
        }

        return .autoupdatingCurrent
    }
}
