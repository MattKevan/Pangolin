//
//  VideoFileManager.swift
//  Pangolin
//
//  Cloud-backed video file access and ubiquitous download/upload management.
//

import Foundation
import Combine
import CoreData
import os


@MainActor
@Observable
class VideoFileManager {
    static let shared = VideoFileManager()

    var downloadingVideos: Set<UUID> = []
    var downloadProgress: [UUID: Double] = [:]
    private(set) var transferSnapshots: [UUID: VideoCloudTransferSnapshot] = [:]

    /// Monotonic per-video generation counter that lets `cancelDownload(for:)`
    /// invalidate any in-flight polling loop so it stops instead of re-publishing
    /// progress or timing out after the user cancelled.
    @ObservationIgnored private var downloadGenerations: [UUID: UInt] = [:]

    private let fileManager = FileManager.default
    let cloudContainerIdentifier = PangolinCloudContainer.identifier
    private let retryDelays: [TimeInterval] = [5, 15, 45]

    @ObservationIgnored private var transferFailures: [UUID: TransferFailureRecord] = [:]
    @ObservationIgnored private var retryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var trackedVideoObjectIDs: [UUID: NSManagedObjectID] = [:]
    @ObservationIgnored private var trackingPollTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    var failedTransferSnapshots: [VideoCloudTransferSnapshot] {
        transferSnapshots.values
            .filter(\.isError)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.videoTitle.localizedCaseInsensitiveCompare(rhs.videoTitle) == .orderedAscending
            }
    }

    var failedTransferCount: Int {
        failedTransferSnapshots.count
    }

    var activeTransferSnapshots: [VideoCloudTransferSnapshot] {
        transferSnapshots.values
            .filter { $0.state.isTransient }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.videoTitle.localizedCaseInsensitiveCompare(rhs.videoTitle) == .orderedAscending
            }
    }

    var activeTransferCount: Int {
        activeTransferSnapshots.count
    }

    /// A best-effort progress value for the toolbar. iCloud doesn't always expose
    /// a byte fraction, so queued transfers use a small visible starting value.
    var activeTransferProgress: Double? {
        let snapshots = activeTransferSnapshots
        guard !snapshots.isEmpty else { return nil }

        let progress = snapshots.map { snapshot -> Double in
            switch snapshot.state {
            case .queuedForUploading:
                return 0.02
            case .uploading(let progress), .downloading(let progress):
                return max(0.02, progress ?? 0.05)
            case .inCloudOnly, .downloaded, .error:
                return 0
            }
        }
        return progress.reduce(0, +) / Double(progress.count)
    }

    var hasTransferIssues: Bool {
        failedTransferCount > 0
    }

    func cloudURL(for video: Video) -> URL? {
        guard let relative = canonicalRelativePath(for: video),
              let root = ubiquitousRootURL() else {
            return nil
        }
        return root.appendingPathComponent(relative)
    }

    /// Canonical entrypoint for consumers that need a usable local URL.
    func getVideoFileURL(for video: Video, downloadIfNeeded: Bool = true) async throws -> URL {
        try await ensureLocalAvailability(for: video, downloadIfNeeded: downloadIfNeeded)
    }

    /// Resolves a video for external file promises. If its local copy has been
    /// offloaded, this starts the normal tracked iCloud download before export.
    func getVideoFileURL(forID videoID: UUID, downloadIfNeeded: Bool = true) async throws -> URL {
        guard let video = fetchVideo(withID: videoID) else {
            throw VideoFileError.invalidVideoPath
        }
        return try await getVideoFileURL(for: video, downloadIfNeeded: downloadIfNeeded)
    }

    func ensureLocalAvailability(for video: Video) async throws -> URL {
        try await ensureLocalAvailability(for: video, downloadIfNeeded: true)
    }

    func uploadImportedVideoToCloud(localURL: URL, for video: Video) async throws {
        guard let videoID = video.id else {
            throw VideoFileError.invalidVideoPath
        }
        guard let root = ubiquitousRootURL() else {
            let error = VideoFileError.cloudContainerUnavailable
            markTransferFailure(for: video, operation: .upload, message: error.localizedDescription)
            throw error
        }

        setTransferState(.queuedForUploading, for: video)

        do {
            let ext = localURL.pathExtension.isEmpty ? "mp4" : localURL.pathExtension
            let relative = "Media/Videos/\(videoID.uuidString).\(ext)"
            let destinationURL = root.appendingPathComponent(relative)
            try await Self.moveImportedFileToCloud(
                localURL: localURL,
                destinationURL: destinationURL
            )

            video.cloudRelativePath = relative
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            video.lastFileSyncDate = Date()

            clearFailure(for: videoID)
            _ = await refreshTransferState(for: video)
            beginTracking(video: video)
        } catch {
            markTransferFailure(for: video, operation: .upload, message: error.localizedDescription)
            throw VideoFileError.uploadFailed(error.localizedDescription)
        }
    }

    /// Uploads an optimised replacement under a new cloud path, confirms that
    /// upload, then removes the old cloud object. This never deletes the old
    /// version before the replacement is safely in iCloud.
    func replaceCloudVideoFile(localURL: URL, for video: Video) async throws {
        guard let videoID = video.id,
              let root = ubiquitousRootURL() else {
            throw VideoFileError.invalidVideoPath
        }
        let oldURL = cloudURL(for: video)
        let oldRelativePath = video.cloudRelativePath
        let relative = "Media/Videos/\(videoID.uuidString)-optimized-\(UUID().uuidString).mp4"
        let destinationURL = root.appendingPathComponent(relative)
        do {
            try await Self.moveImportedFileToCloud(localURL: localURL, destinationURL: destinationURL)
            video.cloudRelativePath = relative
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            _ = await refreshTransferState(for: video)
            beginTracking(video: video)

            let timeout = Date().addingTimeInterval(300)
            while Date() < timeout {
                if await Self.isUbiquitousFileUploaded(at: destinationURL) {
                    if let oldURL, oldURL != destinationURL {
                        await Self.removeIfExists(at: oldURL)
                    }
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw VideoFileError.uploadFailed("Timed out waiting for the optimised replacement to upload.")
        } catch {
            video.cloudRelativePath = oldRelativePath
            // Drop the abandoned replacement, but only while the old version is still there to fall back on.
            if let oldURL, oldURL != destinationURL, FileManager.default.fileExists(atPath: oldURL.path) {
                await Self.removeIfExists(at: destinationURL)
            }
            throw error
        }
    }

    private nonisolated static func removeIfExists(at url: URL) async {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Logger.files.warning("FILES: Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }.value
    }

    /// Performs potentially blocking iCloud filesystem work away from the UI actor.
    private nonisolated static func moveImportedFileToCloud(
        localURL: URL,
        destinationURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            guard localURL.standardizedFileURL != destinationURL.standardizedFileURL else {
                return
            }

            let sourceValues = try? localURL.resourceValues(forKeys: [.isUbiquitousItemKey])
            if sourceValues?.isUbiquitousItem == true {
                try fileManager.moveItem(at: localURL, to: destinationURL)
                return
            }

            do {
                _ = try fileManager.setUbiquitous(true, itemAt: localURL, destinationURL: destinationURL)
            } catch {
                try fileManager.moveItem(at: localURL, to: destinationURL)
            }
        }.value
    }

    func evictLocalCopy(for video: Video) async throws {
        let result = try await offloadLocalCopy(for: video)
        if case .waitingForUpload = result {
            let error = VideoFileError.offloadFailed("Waiting for iCloud upload confirmation before offloading local copy.")
            markTransferFailure(for: video, operation: .offload, message: error.localizedDescription)
            throw error
        }
    }

    func offloadLocalCopy(for video: Video) async throws -> LocalCopyOffloadResult {
        guard let url = cloudURL(for: video) else {
            let error = VideoFileError.invalidVideoPath
            markTransferFailure(for: video, operation: .offload, message: error.localizedDescription)
            throw error
        }

        do {
            let result = try await Self.offloadUbiquitousFile(at: url)
            guard result == .evicted else { return result }

            video.fileAvailabilityState = VideoFileStatus.cloudOnly.rawValue
            video.lastFileSyncDate = Date()

            if let id = video.id {
                clearFailure(for: id)
            }
            setTransferState(.inCloudOnly, for: video)
            return result
        } catch {
            markTransferFailure(for: video, operation: .offload, message: error.localizedDescription)
            throw VideoFileError.offloadFailed(error.localizedDescription)
        }
    }

    func isVideoFileAccessible(_ video: Video) async -> VideoFileStatus {
        let snapshot = await refreshTransferState(for: video)
        return status(from: snapshot.state)
    }

    func refreshTransferState(for video: Video) async -> VideoCloudTransferSnapshot {
        var state = resolveTransferState(for: video, includeFailures: true)

        if case .error = state,
           let videoID = video.id {
            let resolvedState = resolveTransferState(for: video, includeFailures: false)
            if case .error = resolvedState {
                // Keep explicit error state until underlying transfer recovers.
            } else {
                clearFailure(for: videoID)
                state = resolvedState
            }
        }

        let snapshot = setTransferState(state, for: video)
        let resolvedStatus = status(from: state).rawValue
        if video.fileAvailabilityState != resolvedStatus {
            video.fileAvailabilityState = resolvedStatus
        }
        return snapshot
    }

func beginTracking(video: Video) {
        guard let videoID = video.id else { return }
        trackedVideoObjectIDs[videoID] = video.objectID
        ensureTrackingPollTask()
    }

    func endTracking(video: Video) {
        guard let videoID = video.id else { return }
        endTracking(videoID: videoID)
    }

    func endTracking(videoID: UUID) {
        trackedVideoObjectIDs.removeValue(forKey: videoID)
        stopTrackingPollTaskIfIdle()
    }

    func retryTransfer(for video: Video) async {
        guard let videoID = video.id else { return }

        guard var failure = transferFailures[videoID] else {
            let snapshot = await refreshTransferState(for: video)
            switch snapshot.state {
            case .inCloudOnly:
                await retryOperation(.download, for: video)
            case .queuedForUploading, .uploading:
                await retryOperation(.upload, for: video)
            case .downloading, .downloaded, .error:
                break
            }
            return
        }

        cancelRetryTask(for: videoID)
        failure.retryCount = 0
        transferFailures[videoID] = failure

        await retryOperation(failure.operation, for: video)
    }

    func retryTransfer(videoID: UUID) async {
        guard let video = fetchVideo(withID: videoID) else { return }
        await retryTransfer(for: video)
    }

    func retryOffload(for video: Video) async {
        guard let videoID = video.id else { return }

        cancelRetryTask(for: videoID)
        transferFailures[videoID] = TransferFailureRecord(
            operation: .offload,
            message: "Retrying offload",
            retryCount: 0
        )

        await retryOperation(.offload, for: video)
    }

    func retryAllFailedTransfers(in library: Library) async {
        let failures = await failedTransferSnapshots(in: library)
        for snapshot in failures {
            await retryTransfer(videoID: snapshot.videoID)
        }
    }

    func failedTransferSnapshots(in library: Library) async -> [VideoCloudTransferSnapshot] {
        let libraryObjectID = library.objectID

        return failedTransferSnapshots.filter { snapshot in
            guard let video = fetchVideo(withID: snapshot.videoID) else {
                return false
            }
            return video.library?.objectID == libraryObjectID
        }
    }

    func failedTransferCounts(in library: Library) async -> VideoTransferIssueCounts {
        let snapshots = await failedTransferSnapshots(in: library)
        var counts = VideoTransferIssueCounts()

        for snapshot in snapshots {
            guard case .error(let operation, _, _, _) = snapshot.state else { continue }
            counts.total += 1
            switch operation {
            case .upload:
                counts.upload += 1
            case .download:
                counts.download += 1
            case .offload:
                counts.offload += 1
            }
        }

        return counts
    }

    func markTransferFailure(for video: Video, operation: VideoCloudTransferOperation, message: String) {
        guard let videoID = video.id else { return }

        let currentRetryCount = transferFailures[videoID]?.retryCount ?? 0
        transferFailures[videoID] = TransferFailureRecord(
            operation: operation,
            message: message,
            retryCount: currentRetryCount
        )

        let canRetry = currentRetryCount < retryDelays.count
        setTransferState(
            .error(
                operation: operation,
                message: message,
                retryCount: currentRetryCount,
                canRetry: canRetry
            ),
            for: video
        )

        if canRetry {
            scheduleAutoRetry(for: videoID, after: retryDelays[currentRetryCount])
        }
    }

    func clearTransferFailure(for video: Video) {
        guard let videoID = video.id else { return }
        dismissTransferIssue(for: videoID)
    }

    func clearAllTransferIssues() {
        for videoID in Array(transferFailures.keys) {
            clearFailure(for: videoID)
        }

        transferSnapshots = transferSnapshots.filter { !$0.value.isError }
    }

    func isUploadConfirmed(for video: Video) async -> Bool {
        guard let url = cloudURL(for: video) else {
            return false
        }

        return await Self.isUbiquitousFileUploaded(at: url)
    }

func cancelDownload(for video: Video) {
        guard let videoID = video.id else { return }
        downloadingVideos.remove(videoID)
        downloadProgress.removeValue(forKey: videoID)
        // Invalidate any in-flight polling loop so it exits on its next tick
        // instead of re-publishing progress and flipping back to .downloading.
        downloadGenerations[videoID] = VideoDownloadSessionPolicy.invalidate(
            downloadGenerations[videoID]
        )
        transferFailures.removeValue(forKey: videoID)
        setTransferState(.inCloudOnly, for: video)
    }

    // MARK: - Internal

    private func ensureLocalAvailability(for video: Video, downloadIfNeeded: Bool) async throws -> URL {
        if let localURL = localStagingURL(for: video),
           fileManager.fileExists(atPath: localURL.path) {
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            if let videoID = video.id {
                clearFailure(for: videoID)
            }
            setTransferState(.downloaded, for: video)
            return localURL
        }

        guard let url = cloudURL(for: video) else {
            let fallbackURL = localStagingURL(for: video) ?? URL(fileURLWithPath: "unknown")
            let error = VideoFileError.fileNotFound(fallbackURL)
            markTransferFailure(for: video, operation: .download, message: error.localizedDescription)
            throw error
        }

        if let metadata = ubiquityMetadata(for: url), metadata.isUbiquitous {
            let downloadedStatus = metadata.downloadingStatus == .current || metadata.downloadingStatus == .downloaded

            if downloadedStatus {
                video.fileAvailabilityState = VideoFileStatus.local.rawValue
                if let videoID = video.id {
                    clearFailure(for: videoID)
                }
                setTransferState(.downloaded, for: video)
                return url
            }

            guard downloadIfNeeded else {
                video.fileAvailabilityState = VideoFileStatus.cloudOnly.rawValue
                setTransferState(.inCloudOnly, for: video)
                throw VideoFileError.fileNotDownloaded(url)
            }

            guard let videoID = video.id else {
                throw VideoFileError.invalidVideoPath
            }

            downloadingVideos.insert(videoID)
            downloadProgress[videoID] = 0.0
            video.fileAvailabilityState = VideoFileStatus.downloading.rawValue
            setTransferState(.downloading(progress: 0.0), for: video)

            do {
                try fileManager.startDownloadingUbiquitousItem(at: url)
            } catch {
                downloadingVideos.remove(videoID)
                downloadProgress.removeValue(forKey: videoID)
                video.fileAvailabilityState = VideoFileStatus.error.rawValue
                markTransferFailure(for: video, operation: .download, message: error.localizedDescription)
                throw VideoFileError.downloadFailed(error.localizedDescription)
            }

            let downloadGeneration = VideoDownloadSessionPolicy.begin(
                storedGeneration: downloadGenerations[videoID]
            )
            downloadGenerations[videoID] = downloadGeneration

            return try await pollForDownloadCompletion(
                for: video,
                url: url,
                videoID: videoID,
                generation: downloadGeneration
            )
        }

        if fileManager.fileExists(atPath: url.path) {
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            if let videoID = video.id {
                clearFailure(for: videoID)
            }
            setTransferState(.downloaded, for: video)
            return url
        }

        let error = VideoFileError.fileNotFound(url)
        markTransferFailure(for: video, operation: .download, message: error.localizedDescription)
        throw error
    }

    /// Polls iCloud for download completion, honoring both an explicit user
    /// cancellation (via a session-generation bump in `cancelDownload(for:)`) and
    /// task cancellation. A cancelled session exits immediately instead of
    /// re-publishing progress or timing out.
    private func pollForDownloadCompletion(
        for video: Video,
        url: URL,
        videoID: UUID,
        generation: UInt
    ) async throws -> URL {
        let timeout: TimeInterval = 300
        let start = Date()

        while Date().timeIntervalSince(start) < timeout {
            guard VideoDownloadSessionPolicy.isCurrent(
                generation: generation,
                storedGeneration: downloadGenerations[videoID]
            ) else {
                downloadingVideos.remove(videoID)
                downloadProgress.removeValue(forKey: videoID)
                throw VideoFileError.downloadCancelled(url)
            }
            try Task.checkCancellation()

            let refreshedMetadata = ubiquityMetadata(for: url)
            if let refreshedMetadata {
                if let percentDownloaded = refreshedMetadata.percentDownloaded {
                    let normalizedProgress = clampProgress(percentDownloaded) ?? 0.0
                    downloadProgress[videoID] = normalizedProgress
                    setTransferState(.downloading(progress: normalizedProgress), for: video)
                }

                let isDownloaded = refreshedMetadata.downloadingStatus == .current || refreshedMetadata.downloadingStatus == .downloaded
                if isDownloaded {
                    downloadingVideos.remove(videoID)
                    downloadProgress.removeValue(forKey: videoID)
                    downloadGenerations[videoID] = VideoDownloadSessionPolicy.complete(
                        generation: generation,
                        storedGeneration: downloadGenerations[videoID]
                    )
                    clearFailure(for: videoID)
                    video.fileAvailabilityState = VideoFileStatus.local.rawValue
                    video.lastFileSyncDate = Date()
                    setTransferState(.downloaded, for: video)
                    return url
                }
            }

            if downloadProgress[videoID] == nil {
                setTransferState(.downloading(progress: nil), for: video)
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        downloadingVideos.remove(videoID)
        downloadProgress.removeValue(forKey: videoID)
        downloadGenerations[videoID] = VideoDownloadSessionPolicy.complete(
            generation: generation,
            storedGeneration: downloadGenerations[videoID]
        )
        video.fileAvailabilityState = VideoFileStatus.error.rawValue
        let error = VideoFileError.downloadFailed("Timed out waiting for iCloud file download.")
        markTransferFailure(for: video, operation: .download, message: error.localizedDescription)
        throw error
    }

    private func resolveTransferState(for video: Video, includeFailures: Bool) -> VideoCloudTransferState {
        guard let videoID = video.id else {
            return .error(
                operation: .download,
                message: "Video identifier is missing.",
                retryCount: 0,
                canRetry: true
            )
        }

        if includeFailures, let failure = transferFailures[videoID] {
            return .error(
                operation: failure.operation,
                message: failure.message,
                retryCount: failure.retryCount,
                canRetry: failure.retryCount < retryDelays.count
            )
        }

        if downloadingVideos.contains(videoID) {
            let progress = clampProgress(downloadProgress[videoID])
            return .downloading(progress: progress)
        }

        if let localURL = localStagingURL(for: video),
           fileManager.fileExists(atPath: localURL.path),
           (video.cloudRelativePath?.isEmpty ?? true) {
            return .downloaded
        }

        guard let url = cloudURL(for: video) else {
            if let localURL = localStagingURL(for: video),
               fileManager.fileExists(atPath: localURL.path) {
                return .downloaded
            }

            return .error(
                operation: .download,
                message: "Video file is missing from local storage and iCloud.",
                retryCount: 0,
                canRetry: true
            )
        }

        if let metadata = ubiquityMetadata(for: url), metadata.isUbiquitous {
            if metadata.isDownloading {
                return .downloading(progress: nil)
            }

            if metadata.isUploading {
                return .uploading(progress: nil)
            }

            if metadata.isUploaded == false {
                return .queuedForUploading
            }

            if metadata.downloadingStatus == .current || metadata.downloadingStatus == .downloaded {
                return .downloaded
            }

            return .inCloudOnly
        }

        if fileManager.fileExists(atPath: url.path) {
            return .downloaded
        }

        if let relative = video.cloudRelativePath, !relative.isEmpty {
            return .inCloudOnly
        }

        return .error(
            operation: .download,
            message: "Video file is missing from local storage and iCloud.",
            retryCount: 0,
            canRetry: true
        )
    }

    private func retryOperation(_ operation: VideoCloudTransferOperation, for video: Video) async {
        do {
            switch operation {
            case .upload:
                try await retryUpload(for: video)
            case .download:
                _ = try await ensureLocalAvailability(for: video, downloadIfNeeded: true)
            case .offload:
                try await evictLocalCopy(for: video)
            }

            if let videoID = video.id {
                clearFailure(for: videoID)
            }
            _ = await refreshTransferState(for: video)
        } catch {
            markTransferFailure(for: video, operation: operation, message: error.localizedDescription)
        }
    }

    private func retryUpload(for video: Video) async throws {
        guard let localURL = localStagingURL(for: video),
              fileManager.fileExists(atPath: localURL.path) else {
            throw VideoFileError.uploadFailed("Local file is unavailable for upload retry.")
        }

        try await uploadImportedVideoToCloud(localURL: localURL, for: video)
    }

    private func scheduleAutoRetry(for videoID: UUID, after delay: TimeInterval) {
        cancelRetryTask(for: videoID)

        retryTasks[videoID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.performAutoRetry(videoID: videoID)
        }
    }

    private func performAutoRetry(videoID: UUID) async {
        guard var failure = transferFailures[videoID],
              let video = fetchVideo(withID: videoID) else {
            return
        }

        guard failure.retryCount < retryDelays.count else {
            setTransferState(
                .error(
                    operation: failure.operation,
                    message: failure.message,
                    retryCount: failure.retryCount,
                    canRetry: false
                ),
                for: video
            )
            return
        }

        failure.retryCount += 1
        transferFailures[videoID] = failure

        await retryOperation(failure.operation, for: video)
    }

    private func clearFailure(for videoID: UUID) {
        transferFailures.removeValue(forKey: videoID)
        cancelRetryTask(for: videoID)
    }

    private func dismissTransferIssue(for videoID: UUID) {
        clearFailure(for: videoID)
        transferSnapshots.removeValue(forKey: videoID)
    }

    private func cancelRetryTask(for videoID: UUID) {
        retryTasks[videoID]?.cancel()
        retryTasks.removeValue(forKey: videoID)
    }

    private func ensureTrackingPollTask() {
        guard trackingPollTask == nil else { return }

        trackingPollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollTrackedVideos()
        }
    }

    private func stopTrackingPollTaskIfIdle() {
        if trackedVideoObjectIDs.isEmpty {
            trackingPollTask?.cancel()
            trackingPollTask = nil
            return
        }

        let hasActiveTrackedState = trackedVideoObjectIDs.keys.contains { videoID in
            guard let snapshot = transferSnapshots[videoID] else {
                return true
            }
            return snapshot.state.isTransient || snapshot.isError
        }

        if !hasActiveTrackedState {
            trackingPollTask?.cancel()
            trackingPollTask = nil
        }
    }

    private func pollTrackedVideos() async {
        while !Task.isCancelled {
            guard !trackedVideoObjectIDs.isEmpty else { break }

            for objectID in trackedVideoObjectIDs.values {
                guard let video = video(for: objectID) else { continue }
                _ = await refreshTransferState(for: video)
            }

            let shouldContinue = trackedVideoObjectIDs.keys.contains { videoID in
                guard let snapshot = transferSnapshots[videoID] else {
                    return true
                }
                return snapshot.state.isTransient || snapshot.isError
            }

            if !shouldContinue {
                break
            }

            try? await Task.sleep(for: .seconds(2))
        }

        trackingPollTask = nil
    }

    private func fetchVideo(withID videoID: UUID) -> Video? {
        guard let context = LibraryManager.shared.viewContext else {
            return nil
        }

        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", videoID as CVarArg)
        request.fetchLimit = 1

        return (try? context.fetch(request))?.first
    }

    private func video(for objectID: NSManagedObjectID) -> Video? {
        guard let context = LibraryManager.shared.viewContext else {
            return nil
        }

        return try? context.existingObject(with: objectID) as? Video
    }

    @discardableResult
    private func setTransferState(_ state: VideoCloudTransferState, for video: Video) -> VideoCloudTransferSnapshot {
        guard let videoID = video.id else {
            return VideoCloudTransferSnapshot.placeholder(title: video.title ?? video.fileName ?? "Untitled")
        }

        let snapshot = VideoCloudTransferSnapshot(
            videoID: videoID,
            videoTitle: video.title ?? video.fileName ?? "Untitled",
            state: state,
            updatedAt: Date()
        )

        if transferSnapshots[videoID] != snapshot {
            transferSnapshots[videoID] = snapshot
            notifyStorageChange(videoID: videoID)
        } else {
            transferSnapshots[videoID]?.updatedAt = Date()
        }

        return snapshot
    }

    private func status(from state: VideoCloudTransferState) -> VideoFileStatus {
        switch state {
        case .queuedForUploading, .uploading, .downloaded:
            return .local
        case .inCloudOnly:
            return .cloudOnly
        case .downloading:
            return .downloading
        case .error:
            return .error
        }
    }

    private nonisolated static func isUbiquitousFileUploaded(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey
            ]
            guard let values = try? url.resourceValues(forKeys: keys) else {
                return false
            }

            let allValues = values.allValues
            return (allValues[.isUbiquitousItemKey] as? Bool) == true
                && (allValues[.ubiquitousItemIsUploadedKey] as? Bool) == true
        }.value
    }

    private nonisolated static func offloadUbiquitousFile(
        at url: URL
    ) async throws -> LocalCopyOffloadResult {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else {
                return .alreadyCloudOnly
            }

            let keys: Set<URLResourceKey> = [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemDownloadingStatusKey
            ]
            let values = try url.resourceValues(forKeys: keys)
            let allValues = values.allValues
            guard (allValues[.isUbiquitousItemKey] as? Bool) == true,
                  (allValues[.ubiquitousItemIsUploadedKey] as? Bool) == true else {
                return .waitingForUpload
            }

            let status = allValues[.ubiquitousItemDownloadingStatusKey]
                as? URLUbiquitousItemDownloadingStatus
            guard status == .current || status == .downloaded else {
                return .alreadyCloudOnly
            }

            try fileManager.evictUbiquitousItem(at: url)
            return .evicted
        }.value
    }

    private func ubiquityMetadata(for url: URL) -> UbiquityMetadata? {
        let percentDownloadedKey = URLResourceKey(rawValue: "NSURLUbiquitousItemPercentDownloadedKey")
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey,
            percentDownloadedKey
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }

        let allValues = values.allValues

        return UbiquityMetadata(
            isUbiquitous: (allValues[.isUbiquitousItemKey] as? Bool) ?? false,
            downloadingStatus: allValues[.ubiquitousItemDownloadingStatusKey] as? URLUbiquitousItemDownloadingStatus,
            isDownloading: (allValues[.ubiquitousItemIsDownloadingKey] as? Bool) ?? false,
            isUploading: (allValues[.ubiquitousItemIsUploadingKey] as? Bool) ?? false,
            isUploaded: allValues[.ubiquitousItemIsUploadedKey] as? Bool,
            percentDownloaded: normalizedPercentDownloaded(allValues[percentDownloadedKey])
        )
    }

    private func clampProgress(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return min(max(value, 0), 1)
    }

    private func normalizedPercentDownloaded(_ rawValue: Any?) -> Double? {
        let numericValue: Double? = {
            if let number = rawValue as? NSNumber {
                return number.doubleValue
            }
            if let value = rawValue as? Double {
                return value
            }
            if let value = rawValue as? Float {
                return Double(value)
            }
            return nil
        }()

        guard let numericValue else { return nil }
        if numericValue > 1.0 {
            return min(max(numericValue / 100.0, 0.0), 1.0)
        }
        return min(max(numericValue, 0.0), 1.0)
    }

    private func notifyStorageChange(videoID: UUID) {
        NotificationCenter.default.post(
            name: .videoStorageAvailabilityChanged,
            object: nil,
            userInfo: [VideoStorageChangeKey.videoID: videoID]
        )
    }

    private func canonicalRelativePath(for video: Video) -> String? {
        if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
            return cloudRelativePath
        }
        return nil
    }

    private func ubiquitousRootURL() -> URL? {
        fileManager.url(forUbiquityContainerIdentifier: cloudContainerIdentifier)
            ?? fileManager.url(forUbiquityContainerIdentifier: nil)
    }

    private func localStagingURL(for video: Video) -> URL? {
        guard let library = video.library,
              let libraryURL = library.url,
              let relativePath = video.relativePath,
              !relativePath.isEmpty else {
            return nil
        }
        return libraryURL.appendingPathComponent("Videos").appendingPathComponent(relativePath)
    }
}

// MARK: - Cloud Transfer Models
