import os
import Foundation
import CoreData

@MainActor
final class VideoLibraryOptimizationManager: ObservableObject {
    static let shared = VideoLibraryOptimizationManager()

    @Published private(set) var isOptimizing = false
    @Published private(set) var processedCount = 0
    @Published private(set) var totalCount = 0

    private let optimizer = VideoUploadOptimizer.shared
    private let videoFileManager = VideoFileManager.shared

    private init() {}

    func optimizeAllVideos(in library: Library, preset: VideoUploadOptimizationPreset) async {
        guard preset.isEnabled, !isOptimizing else { return }
        let videos = (library.videos as? Set<Video> ?? []).sorted {
            ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast)
        }
        isOptimizing = true
        processedCount = 0
        totalCount = videos.count
        defer { isOptimizing = false }

        for video in videos {
            defer { processedCount += 1 }
            guard preset.needsOptimization(
                fileSize: video.fileSize,
                duration: video.duration,
                resolution: video.resolution
            ) else { continue }

            do {
                let sourceURL = try await videoFileManager.getVideoFileURL(for: video)
                let result = try await optimizer.optimizeIfNeeded(sourceURL: sourceURL, preset: preset)
                guard result.didOptimize else { continue }
                let optimizedSize = Int64(
                    (try? result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        ?? Int(video.fileSize)
                )
                defer { Task { await optimizer.removeTemporaryOutput(at: result.url) } }

                try await videoFileManager.replaceCloudVideoFile(localURL: result.url, for: video)
                video.fileSize = optimizedSize
                try video.managedObjectContext?.save()
            } catch {
                Logger.files.warning("OPTIMIZE: Failed \(video.title ?? video.fileName ?? "video"): \(error.localizedDescription)")
            }
        }

        await StoragePolicyManager.shared.applyPolicy(for: library)
    }
}
