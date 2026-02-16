//
//  VideoFileManager.swift
//  Pangolin
//
//  Cloud-backed video file access and ubiquitous download/upload management.
//

import Foundation
import Combine
import CoreData

@MainActor
class VideoFileManager: ObservableObject {
    static let shared = VideoFileManager()

    @Published var downloadingVideos: Set<UUID> = []
    @Published var downloadProgress: [UUID: Double] = [:]
    @Published private(set) var transferSnapshots: [UUID: VideoCloudTransferSnapshot] = [:]

    private let fileManager = FileManager.default
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"
    private let retryDelays: [TimeInterval] = [5, 15, 45]

    private struct TransferFailureRecord {
        var operation: VideoCloudTransferOperation
        var message: String
        var retryCount: Int
    }

    private struct UbiquityMetadata {
        let isUbiquitous: Bool
        let downloadingStatus: URLUbiquitousItemDownloadingStatus?
        let isDownloading: Bool
        let isUploading: Bool
        let isUploaded: Bool?
    }

    private var transferFailures: [UUID: TransferFailureRecord] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var trackedVideoObjectIDs: [UUID: NSManagedObjectID] = [:]
    private var trackingPollTask: Task<Void, Never>?

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
            let cloudDir = destinationURL.deletingLastPathComponent()

            try fileManager.createDirectory(at: cloudDir, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            if localURL.standardizedFileURL != destinationURL.standardizedFileURL {
                let sourceValues = try? localURL.resourceValues(forKeys: [.isUbiquitousItemKey])
                let sourceIsUbiquitous = sourceValues?.isUbiquitousItem == true

                if sourceIsUbiquitous {
                    try fileManager.moveItem(at: localURL, to: destinationURL)
                } else {
                    do {
                        _ = try fileManager.setUbiquitous(true, itemAt: localURL, destinationURL: destinationURL)
                    } catch {
                        try fileManager.moveItem(at: localURL, to: destinationURL)
                    }
                }
            }

            video.cloudRelativePath = relative
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            video.lastFileSyncDate = Date()

            clearFailure(for: videoID)
            _ = await refreshTransferState(for: video)
        } catch {
            markTransferFailure(for: video, operation: .upload, message: error.localizedDescription)
            throw VideoFileError.uploadFailed(error.localizedDescription)
        }
    }

    func evictLocalCopy(for video: Video) async throws {
        guard let url = cloudURL(for: video) else {
            let error = VideoFileError.invalidVideoPath
            markTransferFailure(for: video, operation: .offload, message: error.localizedDescription)
            throw error
        }

        let uploadConfirmed = await isUploadConfirmed(for: video)
        guard uploadConfirmed else {
            let error = VideoFileError.offloadFailed("Waiting for iCloud upload confirmation before offloading local copy.")
            markTransferFailure(for: video, operation: .offload, message: error.localizedDescription)
            throw error
        }

        do {
            try fileManager.evictUbiquitousItem(at: url)
            video.fileAvailabilityState = VideoFileStatus.cloudOnly.rawValue
            video.lastFileSyncDate = Date()

            if let id = video.id {
                clearFailure(for: id)
            }
            _ = await refreshTransferState(for: video)
        } catch {
            markTransferFailure(for: video, operation: .offload, message: error.localizedDescription)
            throw VideoFileError.offloadFailed(error.localizedDescription)
        }
    }

    func isVideoFileAccessible(_ video: Video) async -> VideoFileStatus {
        let snapshot = await refreshTransferState(for: video)
        let resolvedStatus = status(from: snapshot.state)
        video.fileAvailabilityState = resolvedStatus.rawValue
        return resolvedStatus
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
        video.fileAvailabilityState = status(from: state).rawValue
        return snapshot
    }

    func refreshTransferStates(for videos: [Video]) async {
        for video in videos {
            _ = await refreshTransferState(for: video)
        }
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
        clearFailure(for: videoID)
    }

    func isUploadConfirmed(for video: Video) async -> Bool {
        guard let url = cloudURL(for: video),
              let metadata = ubiquityMetadata(for: url),
              metadata.isUbiquitous else {
            return false
        }

        if metadata.isUploaded == true {
            return true
        }

        return false
    }

    func downloadAllVideos(in library: Library) async {
        guard let context = library.managedObjectContext else { return }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        let videos = (try? context.fetch(request)) ?? []

        for video in videos {
            _ = try? await ensureLocalAvailability(for: video, downloadIfNeeded: true)
        }
    }

    func cancelDownload(for video: Video) {
        guard let videoID = video.id else { return }
        downloadingVideos.remove(videoID)
        downloadProgress.removeValue(forKey: videoID)

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
            video.fileAvailabilityState = VideoFileStatus.downloading.rawValue
            setTransferState(.downloading(progress: nil), for: video)

            do {
                try fileManager.startDownloadingUbiquitousItem(at: url)
            } catch {
                downloadingVideos.remove(videoID)
                downloadProgress.removeValue(forKey: videoID)
                video.fileAvailabilityState = VideoFileStatus.error.rawValue
                markTransferFailure(for: video, operation: .download, message: error.localizedDescription)
                throw VideoFileError.downloadFailed(error.localizedDescription)
            }

            let timeout: TimeInterval = 300
            let start = Date()

            while Date().timeIntervalSince(start) < timeout {
                let refreshedMetadata = ubiquityMetadata(for: url)
                if let refreshedMetadata {
                    let isDownloaded = refreshedMetadata.downloadingStatus == .current || refreshedMetadata.downloadingStatus == .downloaded
                    if isDownloaded {
                        downloadingVideos.remove(videoID)
                        downloadProgress.removeValue(forKey: videoID)
                        clearFailure(for: videoID)
                        video.fileAvailabilityState = VideoFileStatus.local.rawValue
                        video.lastFileSyncDate = Date()
                        setTransferState(.downloaded, for: video)
                        return url
                    }
                }

                setTransferState(.downloading(progress: nil), for: video)
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            downloadingVideos.remove(videoID)
            downloadProgress.removeValue(forKey: videoID)
            video.fileAvailabilityState = VideoFileStatus.error.rawValue
            let error = VideoFileError.downloadFailed("Timed out waiting for iCloud file download.")
            markTransferFailure(for: video, operation: .download, message: error.localizedDescription)
            throw error
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
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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

            try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    private func ubiquityMetadata(for url: URL) -> UbiquityMetadata? {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsUploadedKey
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
            isUploaded: allValues[.ubiquitousItemIsUploadedKey] as? Bool
        )
    }

    private func clampProgress(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return min(max(value, 0), 1)
    }

    private func notifyStorageChange(videoID: UUID) {
        NotificationCenter.default.post(
            name: .videoStorageAvailabilityChanged,
            object: nil,
            userInfo: ["videoID": videoID]
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

enum VideoCloudTransferOperation: String, CaseIterable, Identifiable {
    case upload
    case download
    case offload

    var id: String { rawValue }

    var failedTitle: String {
        switch self {
        case .upload:
            return "Upload failed"
        case .download:
            return "Download failed"
        case .offload:
            return "Offload failed"
        }
    }
}

enum VideoCloudTransferState: Equatable {
    case queuedForUploading
    case uploading(progress: Double?)
    case inCloudOnly
    case downloading(progress: Double?)
    case downloaded
    case error(operation: VideoCloudTransferOperation, message: String, retryCount: Int, canRetry: Bool)

    var isTransient: Bool {
        switch self {
        case .queuedForUploading, .uploading, .downloading:
            return true
        case .inCloudOnly, .downloaded, .error:
            return false
        }
    }
}

struct VideoCloudTransferSnapshot: Identifiable, Equatable {
    let videoID: UUID
    let videoTitle: String
    let state: VideoCloudTransferState
    var updatedAt: Date

    var id: UUID { videoID }

    var isError: Bool {
        if case .error = state {
            return true
        }
        return false
    }

    var displayName: String {
        switch state {
        case .queuedForUploading:
            return "Queued for uploading"
        case .uploading(let progress):
            if let progress {
                return "Uploading \(Int((progress * 100).rounded()))%"
            }
            return "Uploading"
        case .inCloudOnly:
            return "In cloud only"
        case .downloading(let progress):
            if let progress {
                return "Downloading \(Int((progress * 100).rounded()))%"
            }
            return "Downloading"
        case .downloaded:
            return "Downloaded"
        case .error(let operation, _, _, _):
            return operation.failedTitle
        }
    }

    var detailMessage: String {
        switch state {
        case .error(_, let message, _, _):
            return message
        default:
            return displayName
        }
    }

    static func placeholder(title: String) -> VideoCloudTransferSnapshot {
        VideoCloudTransferSnapshot(
            videoID: UUID(),
            videoTitle: title,
            state: .downloaded,
            updatedAt: Date()
        )
    }

    static func == (lhs: VideoCloudTransferSnapshot, rhs: VideoCloudTransferSnapshot) -> Bool {
        lhs.videoID == rhs.videoID
            && lhs.videoTitle == rhs.videoTitle
            && lhs.state == rhs.state
    }
}

struct VideoTransferIssueCounts: Equatable {
    var upload: Int = 0
    var download: Int = 0
    var offload: Int = 0
    var total: Int = 0
}

// MARK: - Video File Status

enum VideoFileStatus: String {
    case local = "local"
    case cloudOnly = "cloud_only"
    case downloading = "downloading"
    case missing = "missing"
    case error = "error"

    var displayName: String {
        switch self {
        case .local: return "Available"
        case .cloudOnly: return "In iCloud"
        case .downloading: return "Downloading"
        case .missing: return "Missing"
        case .error: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .local: return "checkmark.circle.fill"
        case .cloudOnly: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle"
        case .missing: return "questionmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Video File Errors

enum VideoFileError: LocalizedError {
    case invalidVideoPath
    case cloudContainerUnavailable
    case fileNotFound(URL)
    case fileNotDownloaded(URL)
    case uploadFailed(String)
    case downloadFailed(String)
    case offloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVideoPath:
            return "Invalid video file path"
        case .cloudContainerUnavailable:
            return "iCloud container is unavailable. Ensure iCloud Drive is enabled."
        case .fileNotFound(let url):
            return "Video file not found at \(url.lastPathComponent)"
        case .fileNotDownloaded(let url):
            return "Video file \(url.lastPathComponent) is in iCloud but not downloaded"
        case .uploadFailed(let reason):
            return "Failed to upload to iCloud: \(reason)"
        case .downloadFailed(let reason):
            return "Failed to download from iCloud: \(reason)"
        case .offloadFailed(let reason):
            return "Failed to offload local file: \(reason)"
        }
    }
}

extension Notification.Name {
    static let videoStorageAvailabilityChanged = Notification.Name("videoStorageAvailabilityChanged")
}
