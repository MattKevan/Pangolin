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
    @State private var fileStatus: VideoFileStatus = .local

    var body: some View {
        Image(systemName: state.systemImage)
            .foregroundColor(symbolColor)
            .font(.callout)
            .frame(width: 18)
            .help(state.displayName)
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

    private var state: PresentationState {
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

    private var symbolColor: Color {
        switch state {
        case .downloaded:
            return .green
        case .inCloud, .downloading:
            return .secondary
        }
    }

    @MainActor
    private func refreshStatus() async {
        fileStatus = await video.getVideoFileStatus()
    }

    private enum PresentationState {
        case inCloud
        case downloading
        case downloaded

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
    }
}
