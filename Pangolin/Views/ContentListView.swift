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
    @State private var selectedVideos: Set<Video> = []
    @State private var showingCreatePlaylist = false
    
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
    
    var body: some View {
        VStack {
            if videos.isEmpty {
                ContentUnavailableView(
                    "No Videos",
                    systemImage: "video.slash",
                    description: Text(playlist == nil ? "Import videos to get started" : "This playlist is empty")
                )
            } else {
                switch viewMode {
                case .grid:
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                            ForEach(videos, id: \.id) { video in
                                VideoGridItem(
                                    video: video, 
                                    isSelected: isSelectionMode ? selectedVideos.contains(video) : selectedVideo?.id == video.id,
                                    showCheckbox: isSelectionMode
                                )
                                .onTapGesture {
                                    if isSelectionMode {
                                        toggleVideoSelection(video)
                                    } else {
                                        selectedVideo = video
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                case .list:
                    if isSelectionMode {
                        List(videos, id: \.id) { video in
                            VideoListRow(
                                video: video, 
                                isSelected: selectedVideos.contains(video),
                                showCheckbox: true
                            )
                            .onTapGesture {
                                toggleVideoSelection(video)
                            }
                        }
                    } else {
                        List(videos, id: \.id, selection: $selectedVideo) { video in
                            VideoListRow(video: video, isSelected: false, showCheckbox: false)
                        }
                    }
                }
            }
        }
        .toolbar {
            #if os(macOS)
            ToolbarItemGroup {
                if isSelectionMode {
                    Button("Create Playlist") {
                        showingCreatePlaylist = true
                    }
                    .disabled(selectedVideos.isEmpty)
                    
                    Button("Cancel") {
                        isSelectionMode = false
                        selectedVideos.removeAll()
                    }
                } else {
                    Button("Import Videos") {
                        showingImportPicker = true
                    }
                    .disabled(libraryManager.currentLibrary == nil)
                    
                    Button("Select") {
                        isSelectionMode = true
                    }
                    .disabled(videos.isEmpty)
                    
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
            }
            #else
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelectionMode {
                    Button("Create Playlist") {
                        showingCreatePlaylist = true
                    }
                    .disabled(selectedVideos.isEmpty)
                    
                    Button("Cancel") {
                        isSelectionMode = false
                        selectedVideos.removeAll()
                    }
                } else {
                    Menu {
                        Button("Import Videos") {
                            showingImportPicker = true
                        }
                        .disabled(libraryManager.currentLibrary == nil)
                        
                        Button("Select") {
                            isSelectionMode = true
                        }
                        .disabled(videos.isEmpty)
                        
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            #endif
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
                selectedVideos: Array(selectedVideos),
                library: libraryManager.currentLibrary!,
                onPlaylistCreated: {
                    isSelectionMode = false
                    selectedVideos.removeAll()
                    NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
                }
            )
        }
    }
    
    private func toggleVideoSelection(_ video: Video) {
        if selectedVideos.contains(video) {
            selectedVideos.remove(video)
        } else {
            selectedVideos.insert(video)
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