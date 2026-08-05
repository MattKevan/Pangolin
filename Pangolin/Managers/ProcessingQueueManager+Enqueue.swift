import os
import Foundation
import CoreData
import Combine
// MARK: - Enqueue helpers

extension ProcessingQueueManager {
    // MARK: - Enqueue Helpers

    func enqueueImport(urls: [URL], library: Library, context: NSManagedObjectContext) async {
        if library.id == nil {
            library.id = UUID()
        }
        let plan = await importer.prepareImportPlan(
            from: urls,
            library: library,
            context: context,
            existingRecords: existingImportRecords(in: library, context: context)
        )
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
                Logger.queue.warning("QUEUE: Failed to save pending folder changes before enqueueing import tasks: \(error)")
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
            Logger.queue.warning("QUEUE: No importable video files discovered in dropped items.")
        }
        refreshStats()
        startProcessingIfNeeded()
    }

    func enqueueRemoteImport(url: URL, library: Library, context: NSManagedObjectContext) async throws {
        guard let provider = RemoteVideoProvider.detect(from: url) else {
            throw TaskFailure(message: RemoteVideoDownloadError.unsupportedProvider.localizedDescription)
        }
        Logger.queue.info("QUEUE: enqueueRemoteImport requested for \(url.absoluteString)")

        if library.id == nil {
            library.id = UUID()
        }

        if let existing = queue.first(where: { $0.type == .downloadRemoteVideo && $0.remoteURLString == url.absoluteString }) {
            switch existing.status {
            case .failed, .cancelled, .completed:
                Logger.queue.info("QUEUE: Removing previous \(existing.status.rawValue) remote download task for same URL")
                processingQueue.removeTask(existing)
            case .pending, .waitingForDependencies, .processing, .paused:
                throw TaskFailure(message: "This URL is already in the download queue.")
            }
        }

        let task = ProcessingTask(
            remoteURL: url,
            provider: provider,
            libraryID: library.id,
            destinationFolderID: nil,
            itemName: url.host ?? "Remote URL",
            followUpTypes: [.transcribe]
        )
        processingQueue.addTask(task)
        Logger.queue.info("QUEUE: Added remote download task \(task.id.uuidString) for \(url.absoluteString)")
        refreshStats()

        if context.hasChanges {
            try? context.save()
        }

        startProcessingIfNeeded()
    }

    func enqueueThumbnails(for videos: [Video], force: Bool = false) {
        let videoIDs = videos.compactMap { $0.id }
        for video in videos {
            enqueueThumbnailTask(for: video, force: force)
        }
        refreshStats()
        if !videoIDs.isEmpty {
            startProcessingIfNeeded()
        }
    }

    func requestThumbnailReconciliation(for libraryID: UUID) {
        guard !closingThumbnailLibraryIDs.contains(libraryID) else { return }
        if let readyLibraryID = thumbnailReconciliationGate.request(libraryID: libraryID) {
            startThumbnailReconciliationScan(for: readyLibraryID)
        }
    }

    func activateThumbnailWork(for libraryID: UUID, sourceID: UUID) {
        cloudEventSourceLifecycle.activate(sourceID, libraryID: libraryID)
        bindUnscopedCloudImports(from: sourceID, to: libraryID)
        thumbnailLibraryLifecycle.activate(libraryID)
    }

    func cancelThumbnailWork(for libraryID: UUID?, sourceID: UUID) async {
        cloudEventSourceLifecycle.abandon(sourceID)
        if let libraryID {
            thumbnailLibraryLifecycle.beginClosing(libraryID)
            bindUnscopedCloudImports(from: sourceID, to: libraryID)
            let readyLibraryIDs = [
                thumbnailReconciliationGate.abandon(sourceID: sourceID),
                thumbnailReconciliationGate.abandon(libraryID: libraryID),
            ].compactMap { $0 }
            for readyLibraryID in readyLibraryIDs
                where LibraryManager.shared.currentLibrary?.id == readyLibraryID {
                startThumbnailReconciliationScan(for: readyLibraryID)
            }
        } else if let readyLibraryID = thumbnailReconciliationGate.abandon(sourceID: sourceID),
                  LibraryManager.shared.currentLibrary?.id == readyLibraryID {
            startThumbnailReconciliationScan(for: readyLibraryID)
        }
        activeCloudSyncEvents = activeCloudSyncEvents.filter { $0.value.sourceID != sourceID }
        cloudSyncHideTask?.cancel()
        cloudSyncHideTask = nil
        recomputeCloudSyncQueueStatus()

        if thumbnailReconciliationRescanLibraryID == libraryID {
            thumbnailReconciliationRescanLibraryID = nil
        }

        var drainedVideoIDs: Set<UUID> = []
        while true {
            let scanTask: Task<Void, Never>?
            if thumbnailReconciliationScanLibraryID == libraryID {
                scanTask = thumbnailReconciliationScanTask
                thumbnailReconciliationScanTask?.cancel()
            } else {
                scanTask = nil
            }

            let thumbnailTasks = processingQueue.tasks.filter {
                $0.type == .generateThumbnail
                    && (libraryID == nil ? $0.libraryID == nil : ($0.libraryID == libraryID || $0.libraryID == nil))
            }
            drainedVideoIDs.formUnion(thumbnailTasks.compactMap(\.videoID))
            if let libraryID {
                drainedVideoIDs.formUnion(ThumbnailCoordinator.shared.activeVideoIDs(for: libraryID))
            }
            for task in thumbnailTasks {
                if task.status.isActive, let videoID = task.videoID {
                    ThumbnailCoordinator.shared.cancel(videoID: videoID)
                    processingQueue.cancelTask(task)
                }
                processingQueue.removeTask(task)
            }
            refreshStats()

            if let scanTask {
                await scanTask.value
            }
            for videoID in drainedVideoIDs {
                await ThumbnailCoordinator.shared.cancelAndWait(videoID: videoID)
            }

            let scanSurvives = thumbnailReconciliationScanLibraryID == libraryID
                && thumbnailReconciliationScanTask != nil
            let taskSurvives = processingQueue.tasks.contains {
                $0.type == .generateThumbnail
                    && (libraryID == nil ? $0.libraryID == nil : ($0.libraryID == libraryID || $0.libraryID == nil))
            }
            let operationSurvives = libraryID.map {
                !ThumbnailCoordinator.shared.activeVideoIDs(for: $0).isEmpty
            } ?? drainedVideoIDs.contains {
                ThumbnailCoordinator.shared.hasOperation(videoID: $0)
            }
            if !scanSurvives, !taskSurvives, !operationSurvives {
                break
            }
            await Task.yield()
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
        customPrompt: String? = nil
    ) {
        let trimmedPrompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        enqueueVideoTasks(
            for: videos,
            types: [.summarize],
            force: force,
            summaryCustomPrompt: normalizedPrompt
        )
    }

    func enqueueFlashcards(
        for videos: [Video],
        force: Bool = false,
        count: Int = 12,
        sourceMode: FlashcardsSourceMode = .autoSystemLanguage,
        customPrompt: String? = nil
    ) {
        if sourceMode == .autoSystemLanguage {
            let videosNeedingTranslation = videos.filter { shouldAutoTranslateToSystemLanguage(for: $0) && !hasSystemLanguageTranslation(for: $0) }
            if !videosNeedingTranslation.isEmpty {
                enqueueTranslation(for: videosNeedingTranslation, targetLocale: .autoupdatingCurrent, force: false)
            }
        }

        let trimmedPrompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        let normalizedCount = max(1, count)
        enqueueVideoTasks(
            for: videos,
            types: [.generateFlashcards],
            force: force,
            flashcardsCustomPrompt: normalizedPrompt,
            flashcardsCount: normalizedCount,
            flashcardsSourceMode: sourceMode
        )
    }

    func enqueueFullWorkflow(for videos: [Video]) {
        enqueueVideoTasks(for: videos, types: [.ensureLocalAvailability, .generateThumbnail, .transcribe, .translate, .summarize, .generateFlashcards], force: false)
    }

    func enqueueTranscriptionAndSummary(for videos: [Video]) {
        enqueueVideoTasks(for: videos, types: [.ensureLocalAvailability, .transcribe, .summarize], force: false)
    }

    func enqueueEnsureLocalAvailability(for videos: [Video], force: Bool = false) {
        enqueueVideoTasks(for: videos, types: [.ensureLocalAvailability], force: force)
    }

    func enqueueVideoTasks(
        for videos: [Video],
        types: [ProcessingTaskType],
        force: Bool,
        preferredLocale: Locale? = nil,
        targetLocale: Locale? = nil,
        summaryCustomPrompt: String? = nil,
        flashcardsCustomPrompt: String? = nil,
        flashcardsCount: Int? = nil,
        flashcardsSourceMode: FlashcardsSourceMode? = nil
    ) {
        let videoIDs = videos.compactMap { $0.id }
        for video in videos {
            guard let id = video.id else { continue }
            for type in types {
                if type == .generateThumbnail {
                    enqueueThumbnailTask(for: video, force: force)
                    continue
                }
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
                    summaryCustomPrompt: type == .summarize ? summaryCustomPrompt : nil,
                    flashcardsCustomPrompt: type == .generateFlashcards ? flashcardsCustomPrompt : nil,
                    flashcardsCount: type == .generateFlashcards ? flashcardsCount : nil,
                    flashcardsSourceModeRawValue: type == .generateFlashcards ? flashcardsSourceMode?.rawValue : nil
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
    func addFlashcardsOnly(for videos: [Video]) { enqueueFlashcards(for: videos) }
    func addFullProcessingWorkflow(for videos: [Video]) { enqueueFullWorkflow(for: videos) }
    func addTranscriptionAndSummary(for videos: [Video]) { enqueueTranscriptionAndSummary(for: videos) }
    func addThumbnailsOnly(for videos: [Video]) { enqueueThumbnails(for: videos) }
}
