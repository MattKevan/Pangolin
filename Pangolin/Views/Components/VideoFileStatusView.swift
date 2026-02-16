//
//  VideoFileStatusView.swift
//  Pangolin
//
//  Shows video file availability status and handles transfer recovery.
//

import SwiftUI

struct VideoFileStatusView: View {
    let video: Video

    @EnvironmentObject var videoFileManager: VideoFileManager
    @State private var snapshot: VideoCloudTransferSnapshot?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.caption)

            Text(effectiveSnapshot.displayName)
                .font(.caption)
                .foregroundColor(.secondary)

            actionContent
        }
        .help(effectiveSnapshot.detailMessage)
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
           let liveSnapshot = videoFileManager.transferSnapshots[videoID] {
            return liveSnapshot
        }

        if let snapshot {
            return snapshot
        }

        return VideoCloudTransferSnapshot.placeholder(title: video.title ?? video.fileName ?? "Untitled")
    }

    @ViewBuilder
    private var actionContent: some View {
        switch effectiveSnapshot.state {
        case .queuedForUploading:
            EmptyView()

        case .uploading(let progress):
            transferProgressView(label: "Uploading", progress: progress)

        case .inCloudOnly:
            Button("Download") {
                downloadVideo()
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)

        case .downloading(let progress):
            transferProgressView(label: "Downloading", progress: progress)

            Button("Cancel") {
                videoFileManager.cancelDownload(for: video)
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundColor(.red)

        case .downloaded:
            EmptyView()

        case .error(_, _, _, _):
            Button("Retry") {
                retryTransfer()
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button("Recheck iCloud Status") {
                recheckStatus()
            }
            .font(.caption2)
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func transferProgressView(label: String, progress: Double?) -> some View {
        if let progress {
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle())
                .frame(width: 40)
                .scaleEffect(0.8)

            Text("\(Int((progress * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var statusIcon: String {
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

    private var statusColor: Color {
        switch effectiveSnapshot.state {
        case .downloaded:
            return .green
        case .error:
            return .orange
        case .queuedForUploading, .uploading, .downloading, .inCloudOnly:
            return .secondary
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
        snapshot = await videoFileManager.refreshTransferState(for: video)
    }

    private func retryTransfer() {
        Task {
            await videoFileManager.retryTransfer(for: video)
            await refreshSnapshot()
        }
    }

    private func recheckStatus() {
        Task {
            await refreshSnapshot()
        }
    }

    private func downloadVideo() {
        Task {
            do {
                _ = try await video.getAccessibleFileURL(downloadIfNeeded: true)
            } catch {
                videoFileManager.markTransferFailure(
                    for: video,
                    operation: .download,
                    message: error.localizedDescription
                )
            }
            await refreshSnapshot()
        }
    }
}

// MARK: - Video Row with Status

struct VideoRowWithStatusView: View {
    let video: Video
    @EnvironmentObject var videoFileManager: VideoFileManager

    var body: some View {
        HStack {
            AsyncImage(url: video.thumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(.tertiary)
                    .overlay {
                        Image(systemName: "video")
                            .foregroundColor(.secondary)
                    }
            }
            .frame(width: 60, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title ?? "Unknown")
                    .font(.body)
                    .lineLimit(1)

                HStack {
                    Text(video.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    VideoFileStatusView(video: video)
                }
            }
        }
        .environmentObject(videoFileManager)
    }
}

#Preview {
    Text("VideoFileStatusView Preview")
}
