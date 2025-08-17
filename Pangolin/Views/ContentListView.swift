//
//  ContentListView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/ContentListView.swift
import SwiftUI
import CoreData

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
                                VideoGridItem(video: video, isSelected: selectedVideo?.id == video.id)
                                    .onTapGesture {
                                        selectedVideo = video
                                    }
                            }
                        }
                        .padding()
                    }
                case .list:
                    List(videos, id: \.id, selection: $selectedVideo) { video in
                        VideoListRow(video: video)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Import Videos") {
                    showingImportPicker = true
                }
                .disabled(libraryManager.currentLibrary == nil)
                
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
            }
        }
        .onAppear {
            fetchVideos()
        }
        .onChange(of: libraryManager.currentLibrary) { library in
            fetchVideos()
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