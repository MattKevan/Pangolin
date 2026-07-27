//
//  StoragePolicyManager.swift
//  Pangolin
//
//  Applies library storage preferences and local cache policy.
//

import Foundation
import CoreData

enum StoragePolicyWorkPolicy {
    static let evictionBatchSize = 8
    static let automaticApplyDelay: TimeInterval = 30

    static func shouldScheduleAutomatically(for preference: LibraryStoragePreference) -> Bool {
        preference == .optimizeStorage
    }
}

@MainActor
final class StoragePolicyManager: ObservableObject {
    struct StorageStatistics: Sendable {
        let localUsageBytes: Int64
        let cloudOnlyCount: Int
    }

    private struct StorageStatisticsInput: Sendable {
        let fileURL: URL?
        let fileSize: Int64
        let availabilityState: String?
    }

    static let shared = StoragePolicyManager()

    @Published private(set) var isApplyingPolicy = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastPolicySummary: StoragePolicySummary?

    private let fileManager = FileManager.default
    private let videoFileManager = VideoFileManager.shared

    private var protectedSelectedVideoID: UUID?
    private var deferredPolicyTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func setProtectedSelectedVideoID(_ videoID: UUID?) {
        protectedSelectedVideoID = videoID
    }

    func scheduleAutomaticPolicyApply(for library: Library) {
        guard StoragePolicyWorkPolicy.shouldScheduleAutomatically(for: library.storagePreference),
              let libraryID = library.id else {
            return
        }
        scheduleDeferredPolicyApply(
            for: libraryID,
            after: StoragePolicyWorkPolicy.automaticApplyDelay
        )
    }

    func applyPolicy(for library: Library) async {
        guard !isApplyingPolicy else { return }

        isApplyingPolicy = true
        defer { isApplyingPolicy = false }

        lastErrorMessage = nil

        switch library.storagePreference {
        case .keepAllDownloaded:
            await downloadAllIfNeeded(for: library)

            let usageBytes = await currentLocalVideoUsageBytes(for: library)
            let summary = StoragePolicySummary(
                libraryID: library.id,
                localUsageBytes: usageBytes,
                cacheLimitBytes: library.resolvedMaxLocalVideoCacheBytes,
                evictedCount: 0,
                blockedNotUploadedCount: 0,
                failedOffloadCount: 0,
                skippedProtectedCount: 0,
                skippedMissingCloudPathCount: 0,
                startedAt: Date(),
                completedAt: Date(),
                lastErrorText: nil
            )
            lastPolicySummary = summary

        case .optimizeStorage:
            let summary = await enforceCacheLimit(for: library)
            lastPolicySummary = summary
            lastErrorMessage = summary.lastErrorText

            if summary.shouldRetryLater,
               let libraryID = library.id {
                scheduleDeferredPolicyApply(
                    for: libraryID,
                    after: StoragePolicyWorkPolicy.automaticApplyDelay
                )
            }
        }
    }

    func downloadAllIfNeeded(for library: Library) async {
        let videos = fetchVideos(in: library)
        guard !videos.isEmpty else { return }

        var cloudOnlyVideos: [Video] = []
        for video in videos {
            let status = await videoFileManager.isVideoFileAccessible(video)
            if status == .cloudOnly {
                cloudOnlyVideos.append(video)
            }
        }

        guard !cloudOnlyVideos.isEmpty else { return }
        ProcessingQueueManager.shared.enqueueEnsureLocalAvailability(for: cloudOnlyVideos, force: false)
    }

    @discardableResult
    func enforceCacheLimit(for library: Library) async -> StoragePolicySummary {
        let startedAt = Date()
        let maxCacheBytes = library.resolvedMaxLocalVideoCacheBytes
        var currentUsageBytes = await currentStorageStatistics(for: library).localUsageBytes

        var summary = StoragePolicySummary(
            libraryID: library.id,
            localUsageBytes: currentUsageBytes,
            cacheLimitBytes: maxCacheBytes,
            evictedCount: 0,
            blockedNotUploadedCount: 0,
            failedOffloadCount: 0,
            skippedProtectedCount: 0,
            skippedMissingCloudPathCount: 0,
            startedAt: startedAt,
            completedAt: nil,
            lastErrorText: nil
        )

        guard currentUsageBytes > maxCacheBytes else {
            summary.completedAt = Date()
            return summary
        }

        let protectedVideoIDs = protectedVideoIDsForEviction()
        let candidates = evictionCandidates(in: library)

        for (index, video) in candidates.enumerated() {
            guard currentUsageBytes > maxCacheBytes else { break }

            guard let videoID = video.id else { continue }

            if protectedVideoIDs.contains(videoID) {
                summary.skippedProtectedCount += 1
                continue
            }

            guard let cloudRelativePath = video.cloudRelativePath,
                  !cloudRelativePath.isEmpty else {
                summary.skippedMissingCloudPathCount += 1
                continue
            }

            let evictedBytes = localFileSize(for: video)

            do {
                switch try await videoFileManager.offloadLocalCopy(for: video) {
                case .evicted:
                    currentUsageBytes = max(0, currentUsageBytes - evictedBytes)
                    summary.evictedCount += 1
                case .waitingForUpload:
                    summary.blockedNotUploadedCount += 1
                case .alreadyCloudOnly:
                    break
                }
            } catch {
                summary.failedOffloadCount += 1
                summary.lastErrorText = error.localizedDescription
                videoFileManager.markTransferFailure(
                    for: video,
                    operation: .offload,
                    message: error.localizedDescription
                )
            }

            if (index + 1).isMultiple(of: StoragePolicyWorkPolicy.evictionBatchSize) {
                await Task.yield()
            }
        }

        summary.localUsageBytes = currentUsageBytes
        summary.completedAt = Date()

        await LibraryManager.shared.save()
        return summary
    }

    func currentLocalVideoUsageBytes(for library: Library) async -> Int64 {
        let videos = fetchVideos(in: library)
        var totalBytes: Int64 = 0

        for video in videos {
            let status = await videoFileManager.isVideoFileAccessible(video)
            guard status == .local else { continue }
            totalBytes += localFileSize(for: video)
        }

        return totalBytes
    }

    func currentCloudOnlyVideoCount(for library: Library) async -> Int {
        let videos = fetchVideos(in: library)
        var count = 0

        for video in videos {
            let status = await videoFileManager.isVideoFileAccessible(video)
            if status == .cloudOnly {
                count += 1
            }
        }

        return count
    }

    /// Reads iCloud file attributes on a utility executor so opening settings does
    /// not block the window while a large import is also touching the same files.
    func currentStorageStatistics(for library: Library) async -> StorageStatistics {
        let cloudRoot = fileManager.url(forUbiquityContainerIdentifier: videoFileManager.cloudContainerIdentifier)
        let libraryURL = library.url
        let inputs = fetchVideos(in: library).map { video in
            let fileURL: URL?
            if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
                fileURL = cloudRoot?.appendingPathComponent(cloudRelativePath)
            } else if let relativePath = video.relativePath {
                fileURL = libraryURL?
                    .appendingPathComponent("Videos")
                    .appendingPathComponent(relativePath)
            } else {
                fileURL = nil
            }

            return StorageStatisticsInput(
                fileURL: fileURL,
                fileSize: video.fileSize,
                availabilityState: video.fileAvailabilityState
            )
        }

        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var localUsageBytes: Int64 = 0
            var cloudOnlyCount = 0

            for input in inputs {
                guard let url = input.fileURL,
                      fileManager.fileExists(atPath: url.path) else {
                    if input.availabilityState == VideoFileStatus.cloudOnly.rawValue {
                        cloudOnlyCount += 1
                    }
                    continue
                }

                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey
                ])
                let isCloudOnly = values?.isUbiquitousItem == true
                    && values?.ubiquitousItemDownloadingStatus != .current
                    && values?.ubiquitousItemDownloadingStatus != .downloaded

                if isCloudOnly {
                    cloudOnlyCount += 1
                } else {
                    localUsageBytes += Int64(values?.fileSize ?? Int(input.fileSize))
                }
            }

            return StorageStatistics(
                localUsageBytes: localUsageBytes,
                cloudOnlyCount: cloudOnlyCount
            )
        }.value
    }

    private func fetchVideos(in library: Library) -> [Video] {
        guard let context = LibraryManager.shared.viewContext else { return [] }

        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)

        do {
            return try context.fetch(request)
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    private func fetchLibrary(withID libraryID: UUID) -> Library? {
        guard let context = LibraryManager.shared.viewContext else {
            return nil
        }

        let request = Library.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
        request.fetchLimit = 1

        return (try? context.fetch(request))?.first
    }

    private func evictionCandidates(in library: Library) -> [Video] {
        fetchVideos(in: library).sorted { lhs, rhs in
            let lhsLastPlayed = lhs.lastPlayed ?? .distantPast
            let rhsLastPlayed = rhs.lastPlayed ?? .distantPast
            if lhsLastPlayed != rhsLastPlayed {
                return lhsLastPlayed < rhsLastPlayed
            }

            let lhsDateAdded = lhs.dateAdded ?? .distantPast
            let rhsDateAdded = rhs.dateAdded ?? .distantPast
            if lhsDateAdded != rhsDateAdded {
                return lhsDateAdded < rhsDateAdded
            }

            return lhs.fileSize > rhs.fileSize
        }
    }

    private func protectedVideoIDsForEviction() -> Set<UUID> {
        var protectedIDs = Set<UUID>()

        if let protectedSelectedVideoID {
            protectedIDs.insert(protectedSelectedVideoID)
        }

        protectedIDs.formUnion(videoFileManager.downloadingVideos)
        protectedIDs.formUnion(ProcessingQueueManager.shared.activeVideoIDs)

        return protectedIDs
    }

    private func localFileSize(for video: Video) -> Int64 {
        if let url = video.fileURL,
           fileManager.fileExists(atPath: url.path),
           let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            return Int64(fileSize)
        }

        return max(0, video.fileSize)
    }

    private func scheduleDeferredPolicyApply(for libraryID: UUID, after delay: TimeInterval) {
        deferredPolicyTasks[libraryID]?.cancel()

        deferredPolicyTasks[libraryID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let library = self.fetchLibrary(withID: libraryID) else { return }
            await self.applyPolicy(for: library)
        }
    }
}

struct StoragePolicySummary: Equatable {
    let libraryID: UUID?
    var localUsageBytes: Int64
    let cacheLimitBytes: Int64
    var evictedCount: Int
    var blockedNotUploadedCount: Int
    var failedOffloadCount: Int
    var skippedProtectedCount: Int
    var skippedMissingCloudPathCount: Int
    let startedAt: Date
    var completedAt: Date?
    var lastErrorText: String?

    var remainingOverageBytes: Int64 {
        max(0, localUsageBytes - cacheLimitBytes)
    }

    var shouldRetryLater: Bool {
        remainingOverageBytes > 0 && blockedNotUploadedCount > 0
    }

    var explanation: String {
        if remainingOverageBytes <= 0 {
            return "Local cache is within the configured limit."
        }

        if blockedNotUploadedCount > 0 {
            return "\(blockedNotUploadedCount) video\(blockedNotUploadedCount == 1 ? "" : "s") are waiting for upload confirmation before offload."
        }

        if failedOffloadCount > 0 {
            return "\(failedOffloadCount) offload action\(failedOffloadCount == 1 ? "" : "s") failed and can be retried."
        }

        return "Local cache is still above the limit."
    }
}
