//
//  ContentListView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/ContentListView.swift
import SwiftUI
import CoreData

extension Notification.Name {
    static let playlistsUpdated = Notification.Name("playlistsUpdated")
}

struct ContentListView: View {
    let playlist: Playlist?
    @Binding var selectedVideo: Video?
    let searchText: String
    @AppStorage("contentViewMode") private var viewMode = ViewMode.grid
    @State private var sortOrder = SortOrder.dateAdded
    @State private var showingImportPicker = false
    @State private var showingImportProgress = false
    @StateObject private var videoImporter = VideoImporter()
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var allVideos: [Video] = []
    @State private var isSelectionMode = false
    @State private var selectedVideos: Set<Video.ID> = []
    @State private var showingCreatePlaylist = false
    @State private var isGeneratingThumbnails = false
    
    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case list = "List"
    }
    
    enum SortOrder: String, CaseIterable {
        case dateAdded = "Date Added"
        case name = "Name"
        case duration = "Duration"
    }
    
    var videos: [Video] {
        var filteredVideos: [Video]
        
        // Get videos from playlist or all videos
        if let playlist = playlist {
            filteredVideos = playlist.allVideos
        } else {
            filteredVideos = allVideos
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            filteredVideos = filteredVideos.filter { video in
                video.title.localizedCaseInsensitiveContains(searchText) ||
                video.fileName.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Apply sorting
        switch sortOrder {
        case .dateAdded:
            return filteredVideos.sorted { $0.dateAdded > $1.dateAdded }
        case .name:
            return filteredVideos.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .duration:
            return filteredVideos.sorted { $0.duration > $1.duration }
        }
    }
    
    var videosWithoutThumbnails: [Video] {
        return videos.filter { $0.thumbnailPath == nil }
    }
    
    var body: some View {
        VStack {
            contentView
        }
        .toolbar {
            toolbarContent
        }
        .navigationTitle(playlist?.name ?? "All Videos")
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.movie, .video, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if let library = libraryManager.currentLibrary,
                   let context = libraryManager.viewContext {
                    showingImportProgress = true
                    Task {
                        await videoImporter.importFiles(urls, to: library, context: context)
                    }
                }
            case .failure(let error):
                print("Error importing files: \(error)")
            }
        }
        .sheet(isPresented: $showingImportProgress) {
            ImportProgressView(importer: videoImporter)
        }
        .onChange(of: videoImporter.isImporting) { isImporting in
            if !isImporting && showingImportProgress {
                // Keep the progress sheet open until user dismisses it
                // so they can see the results
                fetchVideos() // Refresh videos after import
                
                // Notify that playlists may have been created
                NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
            }
        }
        .onAppear {
            fetchVideos()
        }
        .onChange(of: libraryManager.currentLibrary) { library in
            fetchVideos()
        }
        .sheet(isPresented: $showingCreatePlaylist) {
            CreatePlaylistFromSelectionView(
                selectedVideos: Array(getSelectedVideos()),
                library: libraryManager.currentLibrary!,
                onPlaylistCreated: {
                    isSelectionMode = false
                    selectedVideos.removeAll()
                    NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
                }
            )
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if videos.isEmpty {
            ContentUnavailableView(
                "No Videos",
                systemImage: "video.slash",
                description: Text(playlist == nil ? "Import videos to get started" : "This playlist is empty")
            )
        } else {
            switch viewMode {
            case .grid:
                gridView
            case .list:
                listView
            }
        }
    }
    
    @ViewBuilder
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                ForEach(videos, id: \.id) { video in
                    VideoGridItem(
                        video: video, 
                        isSelected: selectedVideos.contains(video.id) || selectedVideo?.id == video.id,
                        showCheckbox: isSelectionMode || selectedVideos.count > 1,
                        sourcePlaylist: playlist,
                        selectedVideos: getSelectedVideos()
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { 
                        handleVideoSelection(video: video)
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var listView: some View {
        if playlist?.type == PlaylistType.user.rawValue && !isSelectionMode && selectedVideos.isEmpty {
            // Enable reordering for user playlists when no multi-selection
            List {
                ForEach(videos, id: \.id) { video in
                    VideoListRow(
                        video: video, 
                        isSelected: selectedVideo?.id == video.id,
                        showCheckbox: false,
                        sourcePlaylist: playlist,
                        selectedVideos: getSelectedVideos()
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { 
                        handleVideoSelection(video: video)
                    }
                }
                .onMove(perform: moveVideos)
            }
        } else {
            // Use native List selection for multi-selection support
            List(videos, id: \.id, selection: $selectedVideos) { video in
                VideoListRow(
                    video: video, 
                    isSelected: selectedVideos.contains(video.id) || selectedVideo?.id == video.id,
                    showCheckbox: selectedVideos.count > 1,
                    sourcePlaylist: playlist,
                    selectedVideos: getSelectedVideos()
                )
            }
            .onChange(of: selectedVideos) { _, _ in
                updateSingleSelectionFromMulti()
            }
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            if isSelectionMode {
                selectionModeButtons
            } else {
                normalModeButtons
            }
        }
        #else
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelectionMode {
                selectionModeButtons
            } else {
                Menu {
                    iOSMenuContent
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var selectionModeButtons: some View {
        Button("Create Playlist") {
            showingCreatePlaylist = true
        }
        .disabled(selectedVideos.isEmpty)
        
        Button("Cancel") {
            isSelectionMode = false
            selectedVideos.removeAll()
        }
    }
    
    @ViewBuilder
    private var normalModeButtons: some View {
        Button("Import Videos") {
            showingImportPicker = true
        }
        .disabled(libraryManager.currentLibrary == nil)
        
        if !videosWithoutThumbnails.isEmpty {
            Button(isGeneratingThumbnails ? "Generating..." : "Generate Thumbnails") {
                generateThumbnailsForVideos()
            }
            .disabled(isGeneratingThumbnails)
        }
        
        Button("Select") {
            isSelectionMode = true
        }
        .disabled(videos.isEmpty)
        
        #if os(iOS)
        if playlist?.type == PlaylistType.user.rawValue {
            EditButton()
        }
        #endif
        
        Picker("View Mode", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.2x2" : "list.bullet")
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        
        Menu {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
    
    @ViewBuilder
    private var iOSMenuContent: some View {
        Button("Import Videos") {
            showingImportPicker = true
        }
        .disabled(libraryManager.currentLibrary == nil)
        
        Button("Select") {
            isSelectionMode = true
        }
        .disabled(videos.isEmpty)
        
        #if os(iOS)
        if playlist?.type == PlaylistType.user.rawValue {
            EditButton()
        }
        #endif
        
        Picker("View Mode", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.2x2" : "list.bullet")
                    .tag(mode)
            }
        }
        
        Picker("Sort By", selection: $sortOrder) {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Text(order.rawValue).tag(order)
            }
        }
    }
    
    private func handleVideoSelection(video: Video) {
        // Simple selection for grid view and non-multi-selection list view
        selectedVideo = video
        selectedVideos.removeAll()
    }
    
    private func getSelectedVideos() -> Set<Video> {
        let videoSet = Set(videos.filter { selectedVideos.contains($0.id) })
        return videoSet
    }
    
    private func updateSingleSelectionFromMulti() {
        // Update selectedVideo when multi-selection changes
        if selectedVideos.count == 1, let videoId = selectedVideos.first {
            selectedVideo = videos.first { $0.id == videoId }
        } else if selectedVideos.isEmpty {
            // Keep current selectedVideo if no multi-selection
        } else {
            // Multiple selected, keep selectedVideo as is for context
        }
    }
    
    private func toggleVideoSelection(_ video: Video) {
        if selectedVideos.contains(video.id) {
            selectedVideos.remove(video.id)
        } else {
            selectedVideos.insert(video.id)
        }
    }
    
    private func moveVideos(from source: IndexSet, to destination: Int) {
        guard let playlist = playlist,
              playlist.type == PlaylistType.user.rawValue,
              let context = libraryManager.viewContext else { return }
        
        var reorderedVideos = videos
        reorderedVideos.move(fromOffsets: source, toOffset: destination)
        
        // Update the playlist's video order by removing and re-adding videos in new order
        let mutableVideos = playlist.mutableSetValue(forKey: "videos")
        
        // Clear current videos
        for video in videos {
            mutableVideos.remove(video)
        }
        
        // Add videos back in new order
        for video in reorderedVideos {
            mutableVideos.add(video)
        }
        
        playlist.dateModified = Date()
        
        do {
            try context.save()
            // Refresh the video list to reflect the new order
            if playlist == self.playlist {
                fetchVideos()
            }
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to reorder videos: \(error)")
        }
    }
    
    private func generateThumbnailsForVideos() {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else { return }
        
        isGeneratingThumbnails = true
        
        Task {
            await FileSystemManager.shared.generateMissingThumbnails(for: library, context: context)
            
            await MainActor.run {
                isGeneratingThumbnails = false
                fetchVideos() // Refresh to show new thumbnails
            }
        }
    }
    
    private func fetchVideos() {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            allVideos = []
            return
        }
        
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Video.dateAdded, ascending: false)
        ]
        
        do {
            allVideos = try context.fetch(request)
        } catch {
            print("Failed to fetch videos: \(error)")
            allVideos = []
        }
    }
}