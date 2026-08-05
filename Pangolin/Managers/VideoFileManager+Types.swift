import Foundation
import CoreData

// MARK: - Cloud transfer model types

enum PangolinCloudContainer {
    static let identifier = "iCloud.com.newindustries.pangolin"
}

enum LocalCopyOffloadResult: Sendable, Equatable {
    case evicted
    case waitingForUpload
    case alreadyCloudOnly
}

/// Pure session-token logic for iCloud downloads: each download attempt begins a
/// new generation, and cancelling bumps the stored generation so any in-flight
/// polling loop is orphaned and stops on its next tick.
enum VideoDownloadSessionPolicy {
    static func begin(storedGeneration: UInt?) -> UInt {
        (storedGeneration ?? 0) + 1
    }

    static func isCurrent(generation: UInt, storedGeneration: UInt?) -> Bool {
        storedGeneration == generation
    }

    static func invalidate(_ storedGeneration: UInt?) -> UInt {
        (storedGeneration ?? 0) + 1
    }

    static func complete(generation: UInt, storedGeneration: UInt?) -> UInt? {
        isCurrent(generation: generation, storedGeneration: storedGeneration) ? nil : storedGeneration
    }
}

struct TransferFailureRecord {
        var operation: VideoCloudTransferOperation
        var message: String
        var retryCount: Int
    }

    struct UbiquityMetadata {
        let isUbiquitous: Bool
        let downloadingStatus: URLUbiquitousItemDownloadingStatus?
        let isDownloading: Bool
        let isUploading: Bool
        let isUploaded: Bool?
        let percentDownloaded: Double?
    }


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
    case downloadCancelled(URL)
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
        case .downloadCancelled(let url):
            return "Video download was cancelled."
        case .uploadFailed(let reason):
            return "Failed to upload to iCloud: \(reason)"
        case .downloadFailed(let reason):
            return "Failed to download from iCloud: \(reason)"
        case .offloadFailed(let reason):
            return "Failed to offload local file: \(reason)"
        }
    }
}

/// UserInfo key for `videoStorageAvailabilityChanged` notifications.
enum VideoStorageChangeKey {
    static let videoID = "videoID"
}

extension VideoFileManager {
    /// Resolves the transfer snapshot a row should display: the view's cached
    /// snapshot wins, then the live manager snapshot, then the video's stored
    /// file state, then a cloud-only/placeholder fallback. Pure — no Core Data
    /// access — so the fallback chain is unit-testable.
    nonisolated static func resolvedSnapshot(
        cached: VideoCloudTransferSnapshot?,
        managerSnapshot: VideoCloudTransferSnapshot?,
        fileAvailabilityState: String?,
        cloudRelativePath: String?,
        videoID: UUID?,
        videoTitle: String
    ) -> VideoCloudTransferSnapshot {
        if let cached {
            return cached
        }

        if let managerSnapshot {
            return managerSnapshot
        }

        if let rawState = fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            let state: VideoCloudTransferState
            switch status {
            case .local:
                state = .downloaded
            case .downloading:
                state = .downloading(progress: nil)
            case .cloudOnly, .missing:
                state = .inCloudOnly
            case .error:
                state = .error(
                    operation: .download,
                    message: "Transfer failed",
                    retryCount: 0,
                    canRetry: true
                )
            }

            return VideoCloudTransferSnapshot(
                videoID: videoID ?? UUID(),
                videoTitle: videoTitle,
                state: state,
                updatedAt: Date()
            )
        }

        if let cloudRelativePath, !cloudRelativePath.isEmpty {
            return VideoCloudTransferSnapshot(
                videoID: videoID ?? UUID(),
                videoTitle: videoTitle,
                state: .inCloudOnly,
                updatedAt: Date()
            )
        }

        return VideoCloudTransferSnapshot.placeholder(title: videoTitle)
    }

    /// Whether a `videoStorageAvailabilityChanged` notification targets the
    /// given video (shared by every row that renders transfer status).
    nonisolated static func transferNotification(_ notification: Notification, matches videoID: UUID?) -> Bool {
        guard let videoID else { return false }
        guard let changedID = notification.userInfo?[VideoStorageChangeKey.videoID] as? UUID else {
            return false
        }
        return changedID == videoID
    }

    func effectiveSnapshot(for video: Video, cached: VideoCloudTransferSnapshot?) -> VideoCloudTransferSnapshot {
        Self.resolvedSnapshot(
            cached: cached,
            managerSnapshot: video.id.flatMap { transferSnapshots[$0] },
            fileAvailabilityState: video.fileAvailabilityState,
            cloudRelativePath: video.cloudRelativePath,
            videoID: video.id,
            videoTitle: video.title ?? video.fileName ?? "Untitled"
        )
    }
}

extension Notification.Name {
    static let videoStorageAvailabilityChanged = Notification.Name("videoStorageAvailabilityChanged")
}
