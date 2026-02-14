//
//  FolderContentView.swift
//  Pangolin
//
//  Grid view for child folders and videos in the current folder
//

import SwiftUI
import UniformTypeIdentifiers

struct FolderContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @StateObject private var importer = VideoImporter()
    @State private var isExternalDropTargeted = false
    @State private var selectedVideoIDs: Set<UUID> = []

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
    
    private var isAllVideosView: Bool {
        guard let folder = store.currentFolder else { return false }
        return folder.isSmartFolder && folder.name == "All Videos"
    }

    private var smartFolderVideos: [Video] {
        items.compactMap { item in
            if case .video(let video) = item {
                return video
            }
            return nil
        }
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
                        isSmartFolderView ? "No videos" : "No items",
                        systemImage: isSmartFolderView ? "video" : "folder",
                        description: Text(isSmartFolderView ? "No videos found in this collection." : "This folder is empty.")
                    )
                } else if isSmartFolderView {
                    VideoResultsTableView(
                        videos: smartFolderVideos,
                        selectedVideoIDs: $selectedVideoIDs,
                        onSelectionChange: handleSmartFolderSelection
                    )
                    .onAppear(perform: syncSelectedVideoForSmartTable)
                    .onChange(of: store.selectedVideo?.id) { _, _ in
                        syncSelectedVideoForSmartTable()
                    }
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
                                    // Keep the current browsing context (smart folder or normal folder)
                                    // and only update the active video selection for detail view.
                                    store.selectVideo(video)
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
        .onDrop(of: [.fileURL], isTargeted: $isExternalDropTargeted) { providers in
            handleExternalFileDrop(providers: providers)
        }
        .overlay(alignment: .top) {
            if isAllVideosView && isExternalDropTargeted {
                Text("Drop videos or folders to import")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
    }
    
    private func handleExternalFileDrop(providers: [NSItemProvider]) -> Bool {
        guard isAllVideosView,
              let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else {
            return false
        }
        
        let matchingProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !matchingProviders.isEmpty else { return false }
        
        let lock = NSLock()
        var droppedURLs: [URL] = []
        let group = DispatchGroup()
        
        for provider in matchingProviders {
            group.enter()
            let _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                lock.lock()
                droppedURLs.append(url)
                lock.unlock()
            }
        }
        
        group.notify(queue: .main) {
            guard !droppedURLs.isEmpty else { return }
            Task {
                await importer.importFiles(droppedURLs, to: library, context: context)
            }
        }
        
        return true
    }

    private func handleSmartFolderSelection(_ selection: Set<UUID>) {
        guard let selectedID = selection.first else { return }
        if let selectedVideo = smartFolderVideos.first(where: { $0.id == selectedID }) {
            store.selectVideo(selectedVideo)
        }
    }

    private func syncSelectedVideoForSmartTable() {
        let availableIDs = Set(smartFolderVideos.compactMap(\.id))
        if let selectedID = store.selectedVideo?.id, availableIDs.contains(selectedID) {
            selectedVideoIDs = [selectedID]
        } else {
            selectedVideoIDs = []
        }
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
