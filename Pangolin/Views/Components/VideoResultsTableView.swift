import SwiftUI
import CoreData

struct VideoResultsTableView: View {
    let videos: [Video]
    @Binding var selectedVideoIDs: Set<UUID>
    let onSelectionChange: (Set<UUID>) -> Void

    @StateObject private var videoFileManager = VideoFileManager.shared
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @State private var trackedVideoIDs: Set<UUID> = []

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
            .width(min: 220, ideal: 380)

            TableColumn("Duration", value: \.durationSort) { row in
                Text(row.video.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 90, max: 110)

            TableColumn("Watch Status", value: \.watchSort) { row in
                VideoWatchStatusCell(status: row.video.watchStatus)
            }
            .width(min: 130, ideal: 150, max: 180)

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
            .width(min: 70, ideal: 80, max: 90)

            TableColumn("iCloud", value: \.cloudSort) { row in
                VideoICloudStatusCell(video: row.video)
            }
            .width(min: 180, ideal: 230, max: 300)
        }
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .onChange(of: selectedVideoIDs) { _, newSelection in
            onSelectionChange(newSelection)
        }
        .onAppear {
            updateTracking(for: videos)
            Task {
                await videoFileManager.refreshTransferStates(for: videos)
            }
        }
        .onChange(of: videos.compactMap(\.id)) { _, _ in
            updateTracking(for: videos)
            Task {
                await videoFileManager.refreshTransferStates(for: videos)
            }
        }
        .onDisappear {
            for id in trackedVideoIDs {
                videoFileManager.endTracking(videoID: id)
            }
            trackedVideoIDs.removeAll()
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
        switch transferState(for: video) {
        case .error:
            return 0
        case .queuedForUploading:
            return 1
        case .uploading:
            return 2
        case .inCloudOnly:
            return 3
        case .downloading:
            return 4
        case .downloaded:
            return 5
        }
    }

    private func transferState(for video: Video) -> VideoCloudTransferState {
        if let videoID = video.id,
           let snapshot = videoFileManager.transferSnapshots[videoID] {
            return snapshot.state
        }

        if let rawState = video.fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            switch status {
            case .local:
                return .downloaded
            case .downloading:
                return .downloading(progress: nil)
            case .cloudOnly, .missing:
                return .inCloudOnly
            case .error:
                return .error(
                    operation: .download,
                    message: "Transfer failed",
                    retryCount: 0,
                    canRetry: true
                )
            }
        }

        if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
            return .inCloudOnly
        }

        return .downloaded
    }

    private func updateTracking(for videos: [Video]) {
        let newIDs = Set(videos.compactMap(\.id))

        let removedIDs = trackedVideoIDs.subtracting(newIDs)
        for id in removedIDs {
            videoFileManager.endTracking(videoID: id)
        }

        let addedIDs = newIDs.subtracting(trackedVideoIDs)
        for video in videos {
            guard let videoID = video.id, addedIDs.contains(videoID) else { continue }
            videoFileManager.beginTracking(video: video)
        }

        trackedVideoIDs = newIDs
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
            VideoThumbnailView(video: video, size: CGSize(width: 40, height: 28))
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
            Text(status.displayName)
                .foregroundColor(.secondary)
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

    @StateObject private var videoFileManager = VideoFileManager.shared
    @State private var fallbackSnapshot: VideoCloudTransferSnapshot?

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

                Text("In cloud only")
                    .foregroundColor(.secondary)

            case .downloading(let progress):
                if let progress {
                    CloudTransferProgressIcon(progress: progress, operation: .download)
                    Text("Downloading \(Int((progress * 100).rounded()))%")
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading")
                        .foregroundColor(.secondary)
                }

                if video.id != nil {
                    Button {
                        videoFileManager.cancelDownload(for: video)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel Download")
                }

            case .downloaded:
                Image(systemName: "checkmark.icloud")
                    .foregroundColor(.green)
                Text("Downloaded")
                    .foregroundColor(.secondary)

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

    private var effectiveState: VideoCloudTransferState {
        effectiveSnapshot.state
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
            await refreshSnapshot()
        }
    }

    private func retryTransfer() {
        Task {
            await videoFileManager.retryTransfer(for: video)
            await refreshSnapshot()
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
