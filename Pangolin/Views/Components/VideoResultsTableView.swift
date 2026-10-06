import os
import SwiftUI
import CoreData
import CoreTransferable
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct VideoTableDragTransfer: Codable, Transferable {
    let videoIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pangolinVideoTableDrag)
    }
}

extension UTType {
    static let pangolinVideoTableDrag = UTType(exportedAs: "com.newindustries.pangolin.video-table-drag")
}

enum VideoTableDragPolicy {
    static func videoIDs(for videoID: UUID, selection: Set<UUID>) -> Set<UUID> {
        selection.contains(videoID) ? selection : [videoID]
    }
}

enum VideoTableInteractionPolicy {
    static func shouldOpen(selectionCount: Int) -> Bool {
        selectionCount == 1
    }
}

#if os(macOS)
private typealias VideoDescriptorMap = [UUID: VideoFileExportDescriptor]
#else
/// File-promise drags are macOS only; elsewhere the map stays empty.
private typealias VideoDescriptorMap = [UUID: Never]
#endif

struct VideoResultsTableView: View {
    @Environment(FolderNavigationStore.self) private var store
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
    let videos: [Video]
    @Binding var selectedVideoIDs: Set<UUID>
    let onSelectionChange: (Set<UUID>) -> Void
    let onOpenVideo: (Video) -> Void
    let acceptsExternalVideoImports: Bool

    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @State private var rowCache = RowCache()
    @State private var editingVideo: Video?
    @State private var videoPendingDeletion: Video?
    @State private var showingVideoDeletionConfirmation = false

    private struct Row: Identifiable {
        let id: UUID
        let video: Video
        let titleSort: String
        let durationSort: Double
        let watchSort: Int
        let favoriteSort: Int
        let cloudSort: Int
        let projectTitle: String
        let projectSort: String
    }

    var body: some View {
        let content = rowCache.content(for: contentKey, sortOrder: sortOrder) { buildRows() }
        #if os(macOS)
        let videoDescriptors = content.descriptors
        #endif

        Table(content.sortedRows, selection: $selectedVideoIDs, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.titleSort) { row in
                #if os(macOS)
                titleCell(for: row, videoDescriptors: videoDescriptors)
                #else
                titleCell(for: row)
                #endif
            }
            .width(min: 220, ideal: 440)

            TableColumn("Project", value: \.projectSort) { row in
                Text(row.projectTitle.isEmpty ? "—" : row.projectTitle)
                    .foregroundStyle(row.projectTitle.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 180)

            TableColumn("Duration", value: \.durationSort) { row in
                Text(row.video.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(row.video.isFavorite ? Color.red : Color.secondary)
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
        .contextMenu(forSelectionType: UUID.self) { selection in
            if let video = selectedVideo(from: selection) {
                Button("Edit Video") { editingVideo = video }
                Button("Delete Video", role: .destructive) { promptVideoDeletion(video) }
            }
        } primaryAction: { selection in
            openSelectedVideo(from: selection)
        }
        #endif
        .onChange(of: selectedVideoIDs) { _, newSelection in
            onSelectionChange(newSelection)
        }
        .allVideosImportDrop(
            isEnabled: acceptsExternalVideoImports,
            libraryManager: libraryManager
        )
        .sheet(item: $editingVideo) { video in
            VideoMetadataEditor(video: video)
        }
        .alert("Delete Video?", isPresented: $showingVideoDeletionConfirmation) {
            Button("Cancel", role: .cancel) { cancelVideoDeletion() }
            Button("Delete", role: .destructive) { Task { await deletePendingVideo() } }
        } message: {
            Text("This video will be permanently deleted from your library and removed from disk. This action cannot be undone.")
        }
    }

    /// What the table is built from. Rows are rebuilt only when this changes.
    private struct ContentKey: Equatable {
        let revision: Int
        let videoIDs: [NSManagedObjectID]
    }

    private var contentKey: ContentKey {
        ContentKey(revision: store.contentRevision, videoIDs: videos.map(\.objectID))
    }

    private struct TableContent {
        let rows: [Row]
        let descriptors: VideoDescriptorMap
    }

    /// Holds the built rows, their sorted order and the drag descriptors between renders, so
    /// building and sorting happen once per change instead of once per body pass.
    private final class RowCache {
        struct Content {
            let sortedRows: [Row]
            let descriptors: VideoDescriptorMap
        }

        private var key: ContentKey?
        private var built: TableContent?
        private var sortOrder: [KeyPathComparator<Row>] = []
        private var content: Content?

        func content(
            for key: ContentKey,
            sortOrder: [KeyPathComparator<Row>],
            build: () -> TableContent
        ) -> Content {
            if self.key != key || built == nil {
                self.key = key
                built = build()
                content = nil
            }
            if let content, self.sortOrder == sortOrder {
                return content
            }
            guard let built else { return Content(sortedRows: [], descriptors: [:]) }
            let sortedRows = sortOrder.isEmpty ? built.rows : built.rows.sorted(using: sortOrder)
            let newContent = Content(sortedRows: sortedRows, descriptors: built.descriptors)
            self.sortOrder = sortOrder
            content = newContent
            return newContent
        }
    }

    private func buildRows() -> TableContent {
        let rows: [Row] = videos.compactMap { video in
            guard let id = video.id else { return nil }
            let projectTitle = projectTitle(for: video)
            return Row(
                id: id,
                video: video,
                titleSort: video.title ?? video.fileName ?? "Untitled",
                durationSort: video.duration,
                watchSort: video.watchStatus.rawValue,
                favoriteSort: video.isFavorite ? 1 : 0,
                cloudSort: cloudSortRank(for: video),
                projectTitle: projectTitle,
                projectSort: projectTitle.localizedLowercase
            )
        }
        #if os(macOS)
        let descriptors = VideoTablePresentationPolicy.descriptorMap(videos.compactMap(VideoFileExportDescriptor.init))
        #else
        let descriptors = VideoDescriptorMap()
        #endif
        return TableContent(rows: rows, descriptors: descriptors)
    }

    private func selectedVideo(from selection: Set<UUID>) -> Video? {
        guard selection.count == 1,
              let videoID = selection.first else { return nil }
        return videos.first(where: { $0.id == videoID })
    }

    private func openSelectedVideo(from selection: Set<UUID>) {
        guard VideoTableInteractionPolicy.shouldOpen(
            selectionCount: selection.count
        ), let video = selectedVideo(from: selection) else {
            return
        }

        onOpenVideo(video)
    }

    private func projectTitle(for video: Video) -> String {
        guard var folder = video.folder else { return "" }
        while let parent = folder.parentFolder {
            folder = parent
        }
        return folder.isProject ? folder.resolvedProjectTitle : ""
    }

    private func dragTransfer(for row: Row) -> VideoTableDragTransfer {
        VideoTableDragTransfer(
            videoIDs: Array(VideoTableDragPolicy.videoIDs(
                for: row.id,
                selection: selectedVideoIDs
            ))
        )
    }

    #if os(macOS)
    private func titleCell(
        for row: Row,
        videoDescriptors: [UUID: VideoFileExportDescriptor]
    ) -> some View {
        VideoTableFileDragSource(
            video: row.video,
            videoDescriptors: videoDescriptors,
            selectedVideoIDs: $selectedVideoIDs,
            onOpenVideo: onOpenVideo
        )
    }
    #else
    private func titleCell(for row: Row) -> some View {
        VideoResultTitleCell(video: row.video)
            .draggable(dragTransfer(for: row))
    }
    #endif

    private func promptVideoDeletion(_ video: Video) {
        videoPendingDeletion = video
        showingVideoDeletionConfirmation = true
    }

    private func cancelVideoDeletion() {
        videoPendingDeletion = nil
        showingVideoDeletionConfirmation = false
    }

    private func deletePendingVideo() async {
        guard let videoID = videoPendingDeletion?.id else {
            cancelVideoDeletion()
            return
        }
        if await store.deleteItems([videoID]) {
            selectedVideoIDs.remove(videoID)
            cancelVideoDeletion()
        }
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
                Logger.app.info("Error toggling favorite: \(error)")
            }
        }
    }
}

struct VideoResultTitleCell: View {
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
                .foregroundStyle(statusColor)
            
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
                    .foregroundStyle(.secondary)
                Text("Queued for uploading")
                    .foregroundStyle(.secondary)

            case .uploading(let progress):
                if let progress {
                    CloudTransferProgressIcon(progress: progress, operation: .upload)
                    Text("Uploading \(Int((progress * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading")
                        .foregroundStyle(.secondary)
                }

            case .inCloudOnly:
                Button(action: startDownload) {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("In cloud only. Download")

                

            case .downloading(let progress):
                if let progress {
                    CloudTransferProgressIcon(progress: progress, operation: .download)
                    Text("Downloading \(Int((progress * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    
                }

                if video.id != nil {
                    Button {
                        videoFileManager.cancelDownload(for: video)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }

            case .downloaded:
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
                

            case .error(let operation, let message, _, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(operation.failedTitle)
                    .foregroundStyle(.secondary)

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
        }
        .onReceive(NotificationCenter.default.publisher(for: .videoStorageAvailabilityChanged)) { notification in
            guard shouldRefresh(for: notification) else { return }
            refreshSnapshotFromManager()
        }
    }

    private var effectiveSnapshot: VideoCloudTransferSnapshot {
        videoFileManager.effectiveSnapshot(for: video, cached: snapshot)
    }

    private var effectiveState: VideoCloudTransferState {
        effectiveSnapshot.state
    }

    private func shouldRefresh(for notification: Notification) -> Bool {
        VideoFileManager.transferNotification(notification, matches: video.id)
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
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 16, height: 16)
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}
