//
//  FolderContentView.swift
//  Pangolin
//
//  Coordinates smart-folder tables and normal folder outline content.
//

import SwiftUI

struct FolderContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager

    private enum FolderContentMode {
        case smartFolder(isAllVideos: Bool)
        case outline
    }

    private var contentMode: FolderContentMode {
        guard let folder = store.currentFolder,
              folder.isSmartFolder,
              let name = folder.name,
              ["All Videos", "Recent", "Favorites"].contains(name) else {
            return .outline
        }

        return .smartFolder(isAllVideos: name == "All Videos")
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
            switch contentMode {
            case .smartFolder(let isAllVideos):
                SmartFolderTablePane(
                    title: store.folderName(for: store.currentFolderID),
                    videos: smartFolderVideos,
                    selectedVideo: store.selectedVideo,
                    onSelectVideo: handleSmartFolderVideoSelection
                )
                .allVideosImportDrop(
                    isEnabled: isAllVideos,
                    libraryManager: libraryManager
                )
            case .outline:
                FolderOutlinePane()
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
