import AVFoundation
import Foundation

struct VideoUploadOptimizationResult {
    let url: URL
    let didOptimize: Bool
}

enum VideoUploadOptimizationError: LocalizedError {
    case noVideoTrack
    case unsupportedPreset(VideoUploadOptimizationPreset)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file does not contain a video track."
        case .unsupportedPreset(let preset): return "\(preset.title) is not available for this video."
        }
    }
}

actor VideoUploadOptimizer {
    static let shared = VideoUploadOptimizer()

    func optimizeIfNeeded(
        sourceURL: URL,
        preset: VideoUploadOptimizationPreset
    ) async throws -> VideoUploadOptimizationResult {
        guard preset.isEnabled,
              try await needsOptimization(sourceURL: sourceURL, preset: preset) else {
            return VideoUploadOptimizationResult(url: sourceURL, didOptimize: false)
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset.exportPresetName),
              exportSession.supportedFileTypes.contains(.mp4) else {
            throw VideoUploadOptimizationError.unsupportedPreset(preset)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinOptimized", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("mp4")

        try await exportSession.export(to: outputURL, as: .mp4)
        let inputBytes = fileSize(at: sourceURL)
        let outputBytes = fileSize(at: outputURL)
        guard outputBytes > 0, outputBytes < inputBytes else {
            try? FileManager.default.removeItem(at: directory)
            return VideoUploadOptimizationResult(url: sourceURL, didOptimize: false)
        }
        return VideoUploadOptimizationResult(url: outputURL, didOptimize: true)
    }

    func removeTemporaryOutput(at url: URL) {
        guard url.path.contains("/PangolinOptimized/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func needsOptimization(
        sourceURL: URL,
        preset: VideoUploadOptimizationPreset
    ) async throws -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VideoUploadOptimizationError.noVideoTrack }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let durationSeconds = max(CMTimeGetSeconds(duration), 1)
        let dimension = max(abs(Double(naturalSize.width)), abs(Double(naturalSize.height)))

        return preset.needsOptimization(
            fileSize: fileSize(at: sourceURL),
            duration: durationSeconds,
            resolution: "\(Int(dimension))x\(Int(dimension))"
        )
    }

    private func fileSize(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
