//
//  FolderContentView.swift
//  Pangolin
//
//  Grid view for child folders and videos in the current folder
//

import SwiftUI

struct FolderContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager

    private var items: [ContentType] {
        store.flatContent
    }
    
    private var isSmartFolderView: Bool {
        guard let folder = store.currentFolder else { return false }
        if folder.isSmartFolder,
           let name = folder.name,
           ["All Videos", "Recent", "Favorites"].contains(name) {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSmartFolderView {
                SmartFolderHeader(title: store.folderName(for: store.currentFolderID))
            } else {
                FolderNavigationHeader(
                    onCreateSubfolder: {
                        Task {
                            await store.createFolder(name: "New Folder", in: store.currentFolderID)
                        }
                    },
                    onDeleteSelected: {
                        // No multi-select in list view.
                    },
                    hasSelectedItems: false
                )
            }

            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "folder",
                        description: Text("This folder is empty.")
                    )
                } else {
                    List {
                        ForEach(items, id: \.id) { item in
                            switch item {
                            case .folder(let folder):
                                FolderListRow(folder: folder) {
                                    if let id = folder.id {
                                        store.navigateToFolder(id)
                                    }
                                }
                            case .video(let video):
                                VideoListRow(
                                    video: video,
                                    isSelected: store.selectedVideo?.objectID == video.objectID
                                ) {
                                    if isSmartFolderView {
                                        store.revealVideoLocation(video)
                                    } else {
                                        store.selectedSidebarItem = .video(video)
                                        store.selectVideo(video)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderListRow: View {
    let folder: Folder
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name ?? "Untitled Folder")
                        .font(.body)
                        .lineLimit(1)
                    
                    if let dateModified = folder.dateModified {
                        Text(dateModified, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

private struct VideoListRow: View {
    let video: Video
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VideoThumbnailView(video: video, size: CGSize(width: 48, height: 34))
                    .frame(width: 48, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title ?? video.fileName ?? "Untitled")
                        .font(.body)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Text(video.formattedDuration)
                        if let dateAdded = video.dateAdded {
                            Text(dateAdded, style: .date)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

private struct SmartFolderHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(backgroundMaterial)
        .overlay(
            Rectangle()
                .fill(separatorColor)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var backgroundMaterial: some View {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }

    private var separatorColor: Color {
        #if os(macOS)
        Color(NSColor.separatorColor)
        #else
        Color(.separator)
        #endif
    }
}
