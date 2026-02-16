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
            VideoThumbnailView(video: video, size: CGSize(width: 34, height: 22))
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

    @StateObject private var videoFileManager = VideoFileManager.shared
    @State private var fallbackSnapshot: VideoCloudTransferSnapshot?

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
        .task {
            await refreshSnapshot()
        }
        .onAppear {
            videoFileManager.beginTracking(video: video)
        }
        .onDisappear {
            if let videoID = video.id {
                videoFileManager.endTracking(videoID: videoID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { notification in
            guard shouldRefresh(for: notification) else { return }
            Task {
                await refreshSnapshot()
            }
        }
    }

    private var effectiveSnapshot: VideoCloudTransferSnapshot {
        if let videoID = video.id,
           let snapshot = videoFileManager.transferSnapshots[videoID] {
            return snapshot
        }

        if let fallbackSnapshot {
            return fallbackSnapshot
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
        guard let videoID = video.id else { return true }
        guard let changedID = notification.userInfo?["videoID"] as? UUID else {
            return true
        }
        return changedID == videoID
    }

    @MainActor
    private func refreshSnapshot() async {
        fallbackSnapshot = await videoFileManager.refreshTransferState(for: video)
    }
}
