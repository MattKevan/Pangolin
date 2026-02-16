import SwiftUI

struct FolderOutlineRow: View {
    let item: HierarchicalContentItem
    let isActiveVideo: Bool

    var body: some View {
        HStack(spacing: 10) {
            rowIcon

            Text(rowTitle)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let video = item.video {
                VideoICloudStatusSymbol(video: video)
            }
        }
        .frame(height: 32)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowIcon: some View {
        switch item.contentType {
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 34, height: 22)
        case .video(let video):
            VideoThumbnailView(video: video, size: CGSize(width: 34, height: 22), showsDurationOverlay: false, showsCloudStatusOverlay: false)
                .frame(width: 34, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    private var rowTitle: String {
        switch item.contentType {
        case .folder(let folder):
            folder.name ?? "Untitled Folder"
        case .video(let video):
            video.title ?? video.fileName ?? "Untitled"
        }
    }
}

private struct VideoICloudStatusSymbol: View {
    let video: Video

    private let videoFileManager = VideoFileManager.shared
    @State private var snapshot: VideoCloudTransferSnapshot?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .foregroundColor(symbolColor)
                .font(.callout)

            if let progressText {
                Text(progressText)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 18, alignment: .trailing)
        .help(effectiveSnapshot.displayName)
        .onAppear {
            refreshSnapshotFromManager()
            videoFileManager.beginTracking(video: video)
        }
        .onDisappear {
            if let videoID = video.id {
                videoFileManager.endTracking(videoID: videoID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { notification in
            guard shouldRefresh(for: notification) else { return }
            refreshSnapshotFromManager()
        }
    }

    private var effectiveSnapshot: VideoCloudTransferSnapshot {
        if let snapshot {
            return snapshot
        }

        if let videoID = video.id,
           let snapshot = videoFileManager.transferSnapshots[videoID] {
            return snapshot
        }

        if let rawState = video.fileAvailabilityState,
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
                videoID: video.id ?? UUID(),
                videoTitle: video.title ?? video.fileName ?? "Untitled",
                state: state,
                updatedAt: Date()
            )
        }

        if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
            return VideoCloudTransferSnapshot(
                videoID: video.id ?? UUID(),
                videoTitle: video.title ?? video.fileName ?? "Untitled",
                state: .inCloudOnly,
                updatedAt: Date()
            )
        }

        return VideoCloudTransferSnapshot.placeholder(title: video.title ?? video.fileName ?? "Untitled")
    }

    private var symbolName: String {
        switch effectiveSnapshot.state {
        case .queuedForUploading:
            return "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
        case .uploading:
            return "icloud.and.arrow.up"
        case .inCloudOnly:
            return "icloud.and.arrow.down"
        case .downloading:
            return "icloud.and.arrow.down"
        case .downloaded:
            return "checkmark.icloud"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var symbolColor: Color {
        switch effectiveSnapshot.state {
        case .downloaded:
            return .green
        case .error:
            return .orange
        case .queuedForUploading, .uploading, .downloading, .inCloudOnly:
            return .secondary
        }
    }

    private var progressText: String? {
        switch effectiveSnapshot.state {
        case .uploading(let progress), .downloading(let progress):
            guard let progress else { return nil }
            return "\(Int((progress * 100).rounded()))%"
        default:
            return nil
        }
    }

    private func shouldRefresh(for notification: Notification) -> Bool {
        guard let videoID = video.id else { return false }
        guard let changedID = notification.userInfo?["videoID"] as? UUID else {
            return false
        }
        return changedID == videoID
    }

    private func refreshSnapshotFromManager() {
        guard let videoID = video.id else { return }
        snapshot = videoFileManager.transferSnapshots[videoID]
    }
}
