import SwiftUI
import CoreData

struct VideoResultsTableView: View {
    let videos: [Video]
    @Binding var selectedVideoIDs: Set<UUID>
    let onSelectionChange: (Set<UUID>) -> Void

    @StateObject private var videoFileManager = VideoFileManager.shared
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
            .width(min: 120, ideal: 140, max: 180)
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
        switch presentationState(for: video) {
        case .inCloud:
            return 0
        case .downloading:
            return 1
        case .downloaded:
            return 2
        }
    }

    private func presentationState(for video: Video) -> VideoICloudPresentationState {
        if let id = video.id, videoFileManager.downloadingVideos.contains(id) {
            return .downloading
        }

        if let rawState = video.fileAvailabilityState,
           let status = VideoFileStatus(rawValue: rawState) {
            switch status {
            case .local:
                return .downloaded
            case .downloading:
                return .downloading
            case .cloudOnly, .missing, .error:
                return .inCloud
            }
        }

        if let cloudRelativePath = video.cloudRelativePath, !cloudRelativePath.isEmpty {
            return .inCloud
        }

        return .downloaded
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

private enum VideoICloudPresentationState: Equatable {
    case inCloud
    case downloading
    case downloaded

    var displayName: String {
        switch self {
        case .inCloud:
            return "In Cloud"
        case .downloading:
            return "Downloading"
        case .downloaded:
            return "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .inCloud:
            return "icloud.and.arrow.down"
        case .downloading:
            return "icloud"
        case .downloaded:
            return "checkmark.icloud"
        }
    }
}

struct VideoICloudStatusCell: View {
    let video: Video
    @StateObject private var videoFileManager = VideoFileManager.shared

    @State private var fileStatus: VideoFileStatus = .local

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .inCloud:
                if video.id != nil {
                    Button(action: startDownload) {
                        Image(systemName: state.systemImage)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("In Cloud. Download")
                } else {
                    Image(systemName: state.systemImage)
                        .foregroundColor(.secondary)
                        .help(state.displayName)
                }

            case .downloading:
                CloudDownloadProgressIcon(progress: downloadProgress)
                Text("\(Int((downloadProgress * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
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
                Image(systemName: state.systemImage)
                    .foregroundColor(.green)
                    .help(state.displayName)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.displayName)
        .task {
            await refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { _ in
            Task {
                await refreshStatus()
            }
        }
        .onChange(of: videoFileManager.downloadingVideos) { _, _ in
            Task {
                await refreshStatus()
            }
        }
    }

    private var downloadProgress: Double {
        guard let videoID = video.id else { return 0 }
        return min(max(videoFileManager.downloadProgress[videoID] ?? 0, 0), 1)
    }

    private var state: VideoICloudPresentationState {
        if let videoID = video.id, videoFileManager.downloadingVideos.contains(videoID) {
            return .downloading
        }

        switch fileStatus {
        case .local:
            return .downloaded
        case .downloading:
            return .downloading
        case .cloudOnly, .missing, .error:
            return .inCloud
        }
    }

    @MainActor
    private func refreshStatus() async {
        fileStatus = await video.getVideoFileStatus()
    }

    private func startDownload() {
        Task {
            do {
                _ = try await video.getAccessibleFileURL(downloadIfNeeded: true)
                await refreshStatus()
            } catch {
                print("Failed to download video: \(error)")
            }
        }
    }
}

private struct CloudDownloadProgressIcon: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "icloud")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .frame(width: 16, height: 16)
        .help("Downloading")
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}
