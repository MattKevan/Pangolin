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

    private let fileManager = FileManager.default
    private let videoFileManager = VideoFileManager.shared

    private var protectedSelectedVideoID: UUID?

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
        case .optimizeStorage:
            await enforceCacheLimit(for: library)
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

    func enforceCacheLimit(for library: Library) async {
        let maxCacheBytes = library.resolvedMaxLocalVideoCacheBytes
        var currentUsageBytes = await currentLocalVideoUsageBytes(for: library)

        guard currentUsageBytes > maxCacheBytes else { return }

        let protectedVideoIDs = protectedVideoIDsForEviction()
        let candidates = evictionCandidates(in: library)

        for video in candidates {
            guard currentUsageBytes > maxCacheBytes else { break }

            guard let videoID = video.id,
                  !protectedVideoIDs.contains(videoID) else {
                continue
            }

            guard let cloudRelativePath = video.cloudRelativePath,
                  !cloudRelativePath.isEmpty else {
                continue
            }

            let status = await videoFileManager.isVideoFileAccessible(video)
            guard status == .local else { continue }

            let evictedBytes = localFileSize(for: video)

            do {
                try await videoFileManager.evictLocalCopy(for: video)
                currentUsageBytes = max(0, currentUsageBytes - evictedBytes)
            } catch {
                print("⚠️ STORAGE_POLICY: Failed to evict '\(video.title ?? video.fileName ?? "Unknown")': \(error)")
                lastErrorMessage = error.localizedDescription
            }
        }

        await LibraryManager.shared.save()
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
            print("⚠️ STORAGE_POLICY: Failed to fetch videos: \(error)")
            return []
        }
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
}
