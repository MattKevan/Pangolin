//
//  FolderContentView.swift
//  Pangolin
//
//  Coordinates smart-collection table content in the detail column.
//

import SwiftUI

struct FolderContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager

    private var currentSmartCollection: SmartCollectionKind? {
        store.currentSmartCollection
    }

    private var smartFolderVideos: [Video] {
        store.flatContent.compactMap { item in
            if case .video(let video) = item {
                return video
            }
            return nil
        }
    }

    var body: some View {
        Group {
            if let kind = currentSmartCollection {
                SmartFolderTablePane(
                    title: kind.title,
                    videos: smartFolderVideos,
                    selectedVideo: store.selectedVideo,
                    onSelectVideo: handleSmartFolderVideoSelection
                )
                .allVideosImportDrop(
                    isEnabled: kind == .allVideos,
                    libraryManager: libraryManager
                )
            } else {
                ContentUnavailableView(
                    "No video selected",
                    systemImage: "video",
                    description: Text("Select a video to view details.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSmartFolderVideoSelection(_ video: Video) {
        guard video.folder != nil else {
            // Fallback for orphaned videos: keep selection local and avoid navigation failure.
            store.selectVideo(video)
            return
        }

        store.revealVideoLocation(video)
    }
}
