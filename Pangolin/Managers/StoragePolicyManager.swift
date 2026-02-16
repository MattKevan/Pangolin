//
//  StoragePolicyManager.swift
//  Pangolin
//
//  Applies library storage preferences and local cache policy.
//

import Foundation
import CoreData

@MainActor
final class StoragePolicyManager: ObservableObject {
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
                scheduleDeferredPolicyApply(for: libraryID, after: 30)
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
        var currentUsageBytes = await currentLocalVideoUsageBytes(for: library)

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

        for video in candidates {
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

            let uploadConfirmed = await videoFileManager.isUploadConfirmed(for: video)
            if !uploadConfirmed {
                summary.blockedNotUploadedCount += 1
                _ = await videoFileManager.refreshTransferState(for: video)
                continue
            }

            let status = await videoFileManager.isVideoFileAccessible(video)
            guard status == .local else { continue }

            let evictedBytes = localFileSize(for: video)

            do {
                try await videoFileManager.evictLocalCopy(for: video)
                currentUsageBytes = max(0, currentUsageBytes - evictedBytes)
                summary.evictedCount += 1
            } catch {
                summary.failedOffloadCount += 1
                summary.lastErrorText = error.localizedDescription
                videoFileManager.markTransferFailure(
                    for: video,
                    operation: .offload,
                    message: error.localizedDescription
                )
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
