import SwiftUI
import CoreData

struct VideoResultsTableView: View {
    let videos: [Video]
    @Binding var selectedVideoIDs: Set<UUID>
    let onSelectionChange: (Set<UUID>) -> Void

    @State private var sortOrder: [KeyPathComparator<Row>] = []

    private struct Row: Identifiable {
        let id: UUID
        let video: Video
        let titleSort: String
        let durationSort: Double
        let watchSort: Int
        let favoriteSort: Int
        let cloudSort: Int
    }

    var body: some View {
        Table(sortedRows, selection: $selectedVideoIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.titleSort) { row in
                VideoResultTitleCell(video: row.video)
            }
            .width(min: 220, ideal: 440)

            TableColumn("Duration", value: \.durationSort) { row in
                Text(row.video.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 90, max: 90)

            TableColumn("Watched", value: \.watchSort) { row in
                VideoWatchStatusCell(status: row.video.watchStatus)
            }
            .width(min: 50, ideal: 60, max: 70)

            TableColumn("Favorite", value: \.favoriteSort) { row in
                Button {
                    toggleFavorite(row.video)
                } label: {
                    Image(systemName: row.video.isFavorite ? "heart.fill" : "heart")
                        .foregroundColor(row.video.isFavorite ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(row.video.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            .width(min: 50, ideal: 60, max: 70)

            TableColumn("Status", value: \.cloudSort) { row in
                VideoICloudStatusCell(video: row.video)
            }
            .width(min: 50, ideal: 60, max: 70)
        }
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .onChange(of: selectedVideoIDs) { _, newSelection in
            onSelectionChange(newSelection)
        }
    }

    private var rows: [Row] {
        videos.compactMap { video in
            guard let id = video.id else { return nil }
            return Row(
                id: id,
                video: video,
                titleSort: video.title ?? video.fileName ?? "Untitled",
                durationSort: video.duration,
                watchSort: video.watchStatus.rawValue,
                favoriteSort: video.isFavorite ? 1 : 0,
                cloudSort: cloudSortRank(for: video)
            )
        }
    }

    private var sortedRows: [Row] {
        if sortOrder.isEmpty {
            return rows
        }
        return rows.sorted(using: sortOrder)
    }

    private func cloudSortRank(for video: Video) -> Int {
        if let rawState = video.fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            switch status {
            case .error:
                return 0
            case .missing:
                return 1
            case .cloudOnly:
                return 2
            case .downloading:
                return 3
            case .local:
                return 4
            }
        }

        if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
            return 2
        }

        return 4
    }

    private func toggleFavorite(_ video: Video) {
        guard let context = video.managedObjectContext else { return }
        context.perform {
            video.isFavorite.toggle()
            do {
                try context.save()
            } catch {
                print("Error toggling favorite: \(error)")
            }
        }
    }
}

private struct VideoResultTitleCell: View {
    let video: Video

    var body: some View {
        HStack(spacing: 8) {
            VideoThumbnailView(video: video, size: CGSize(width: 40, height: 28), showsDurationOverlay: false, showsCloudStatusOverlay: false)
                .frame(width: 40, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(video.title ?? video.fileName ?? "Untitled")
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

private struct VideoWatchStatusCell: View {
    let status: VideoWatchStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.systemImage)
                .foregroundColor(statusColor)
            
        }
        .font(.caption)
        .help(status.displayName)
    }

    private var statusColor: Color {
        switch status {
        case .unwatched:
            return .secondary
        case .inProgress:
            return .orange
        case .watched:
            return .green
        }
    }
}

struct VideoICloudStatusCell: View {
    let video: Video

    private let videoFileManager = VideoFileManager.shared
    @State private var snapshot: VideoCloudTransferSnapshot?

    var body: some View {
        HStack(spacing: 6) {
            switch effectiveState {
            case .queuedForUploading:
                Image(systemName: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                    .foregroundColor(.secondary)
                Text("Queued for uploading")
                    .foregroundColor(.secondary)

            case .uploading(let progress):
                if let progress {
                    CloudTransferProgressIcon(progress: progress, operation: .upload)
                    Text("Uploading \(Int((progress * 100).rounded()))%")
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading")
                        .foregroundColor(.secondary)
                }

            case .inCloudOnly:
                Button(action: startDownload) {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("In cloud only. Download")

                

            case .downloading(let progress):
                if let progress {
                    CloudTransferProgressIcon(progress: progress, operation: .download)
                    Text("Downloading \(Int((progress * 100).rounded()))%")
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    
                }

                if video.id != nil {
                    Button {
                        videoFileManager.cancelDownload(for: video)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }

            case .downloaded:
                Image(systemName: "checkmark.icloud")
                    .foregroundColor(.green)
                

            case .error(let operation, let message, _, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(operation.failedTitle)
                    .foregroundColor(.secondary)

                Button("Retry") {
                    retryTransfer()
                }
                .buttonStyle(.borderless)
                .help(message)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(effectiveSnapshot.detailMessage)
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

    private var effectiveState: VideoCloudTransferState {
        effectiveSnapshot.state
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

    private func startDownload() {
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
            refreshSnapshotFromManager()
        }
    }

    private func retryTransfer() {
        Task {
            await videoFileManager.retryTransfer(for: video)
            refreshSnapshotFromManager()
        }
    }
}

private struct CloudTransferProgressIcon: View {
    let progress: Double
    let operation: VideoCloudTransferOperation

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: operation == .upload ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .frame(width: 16, height: 16)
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}
