//
//  VideoFileManager.swift
//  Pangolin
//
//  Cloud-backed video file access and ubiquitous download/upload management.
//

import Foundation
import Combine

@MainActor
class VideoFileManager: ObservableObject {
    static let shared = VideoFileManager()

    @Published var downloadingVideos: Set<UUID> = []
    @Published var downloadProgress: [UUID: Double] = [:]

    private let fileManager = FileManager.default
    private let cloudContainerIdentifier = "iCloud.com.newindustries.pangolin"

    private init() {}

    // MARK: - Public API

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
            throw VideoFileError.cloudContainerUnavailable
        }

        let ext = localURL.pathExtension.isEmpty ? "mp4" : localURL.pathExtension
        let relative = "Media/Videos/\(videoID.uuidString).\(ext)"
        let cloudURL = root.appendingPathComponent(relative)
        let cloudDir = cloudURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: cloudDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: cloudURL.path) {
            try fileManager.removeItem(at: cloudURL)
        }

        if localURL.standardizedFileURL != cloudURL.standardizedFileURL {
            let sourceValues = try? localURL.resourceValues(forKeys: [.isUbiquitousItemKey])
            let sourceIsUbiquitous = sourceValues?.isUbiquitousItem == true

            if sourceIsUbiquitous {
                // The item is already managed by iCloud; move it within the container.
                try fileManager.moveItem(at: localURL, to: cloudURL)
            } else {
                // Move the local file into iCloud-backed storage using the documented API.
                do {
                    _ = try fileManager.setUbiquitous(true, itemAt: localURL, destinationURL: cloudURL)
                } catch {
                    print("⚠️ VIDEO_FILE: setUbiquitous failed, falling back to moveItem: \(error)")
                    try fileManager.moveItem(at: localURL, to: cloudURL)
                }
            }
        }

        video.cloudRelativePath = relative
        video.fileAvailabilityState = VideoFileStatus.local.rawValue
        video.lastFileSyncDate = Date()
    }

    func evictLocalCopy(for video: Video) async throws {
        guard let url = cloudURL(for: video) else {
            throw VideoFileError.invalidVideoPath
        }
        try fileManager.evictUbiquitousItem(at: url)
        video.fileAvailabilityState = VideoFileStatus.cloudOnly.rawValue
        video.lastFileSyncDate = Date()
    }

    func isVideoFileAccessible(_ video: Video) async -> VideoFileStatus {
        if let localURL = localStagingURL(for: video),
           fileManager.fileExists(atPath: localURL.path) {
            return .local
        }
        
        guard let url = cloudURL(for: video) else {
            return .error
        }

        if fileManager.fileExists(atPath: url.path) {
            return .local
        }

        do {
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isUbiquitousItem == true {
                if values.ubiquitousItemDownloadingStatus == .current {
                    return .local
                }
                return .cloudOnly
            }
        } catch {
            return .error
        }

        return .missing
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
        guard let id = video.id else { return }
        // Ubiquity downloads are system-managed; we only clear UI tracking state.
        downloadingVideos.remove(id)
        downloadProgress.removeValue(forKey: id)
    }

    // MARK: - Internal

    private func ensureLocalAvailability(for video: Video, downloadIfNeeded: Bool) async throws -> URL {
        if let localURL = localStagingURL(for: video),
           fileManager.fileExists(atPath: localURL.path) {
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            return localURL
        }
        
        guard let url = cloudURL(for: video) else {
            throw VideoFileError.fileNotFound(localStagingURL(for: video) ?? URL(fileURLWithPath: "unknown"))
        }

        if fileManager.fileExists(atPath: url.path) {
            video.fileAvailabilityState = VideoFileStatus.local.rawValue
            return url
        }

        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let isUbiquitous = values?.isUbiquitousItem == true

        guard isUbiquitous else {
            video.fileAvailabilityState = VideoFileStatus.missing.rawValue
            throw VideoFileError.fileNotFound(url)
        }

        guard downloadIfNeeded else {
            video.fileAvailabilityState = VideoFileStatus.cloudOnly.rawValue
            throw VideoFileError.fileNotDownloaded(url)
        }

        guard let videoID = video.id else {
            throw VideoFileError.invalidVideoPath
        }

        downloadingVideos.insert(videoID)
        video.fileAvailabilityState = VideoFileStatus.downloading.rawValue

        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            downloadingVideos.remove(videoID)
            video.fileAvailabilityState = VideoFileStatus.error.rawValue
            throw VideoFileError.downloadFailed(error.localizedDescription)
        }

        let timeout: TimeInterval = 300
        let start = Date()

        while Date().timeIntervalSince(start) < timeout {
            if fileManager.fileExists(atPath: url.path) {
                downloadingVideos.remove(videoID)
                downloadProgress[videoID] = 1.0
                video.fileAvailabilityState = VideoFileStatus.local.rawValue
                video.lastFileSyncDate = Date()
                return url
            }

            let elapsed = Date().timeIntervalSince(start)
            downloadProgress[videoID] = min(0.95, elapsed / timeout)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        downloadingVideos.remove(videoID)
        downloadProgress.removeValue(forKey: videoID)
        video.fileAvailabilityState = VideoFileStatus.error.rawValue
        throw VideoFileError.downloadFailed("Timed out waiting for iCloud file download.")
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
    case downloadFailed(String)

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
        case .downloadFailed(let reason):
            return "Failed to download from iCloud: \(reason)"
        }
    }
}

extension Notification.Name {
    static let videoStorageAvailabilityChanged = Notification.Name("videoStorageAvailabilityChanged")
}
