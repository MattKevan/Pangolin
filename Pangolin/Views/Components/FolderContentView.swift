//
//  FolderContentView.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI
import CoreData
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct FolderContentView: View {
    let folderID: UUID?
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject var libraryManager: LibraryManager
    @AppStorage("contentViewMode") private var viewMode = ViewMode.grid
    @State private var isLoading = false
    @State private var selectedItems: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showingCreateFolder = false
    @State private var showingImportPicker = false
    @State private var showingImportProgress = false
    @StateObject private var videoImporter = VideoImporter()
    @State private var isGeneratingThumbnails = false
    @State private var contentRefreshTrigger = false
    
    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case list = "List"
    }
    
    private var content: [ContentType] {
        // Force refresh when contentRefreshTrigger changes
        _ = contentRefreshTrigger
        return store.content(for: folderID)
    }
    
    private var videosWithoutThumbnails: [Video] {
        return content.compactMap { item in
            if case .video(let video) = item, video.thumbnailPath == nil {
                return video
            }
            return nil
        }
    }
    
    var body: some View {
        Group {
            if content.isEmpty {
                ContentUnavailableView(
                    "No Content",
                    systemImage: "folder.badge.questionmark",
                    description: Text(folderID == nil ? "Import videos to get started" : "This folder is empty")
                )
            } else {
                #if os(macOS)
                macOSContentView
                #else
                iOSContentView
                #endif
            }
        }
        .navigationTitle(store.folderName(for: folderID))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            toolbarContent
        }
        .task {
            await MainActor.run {
                store.currentFolderID = folderID
            }
        }
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
        .sheet(isPresented: $showingCreateFolder) {
            CreateFolderView(parentFolderID: folderID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentUpdated)) { _ in
            // Trigger content refresh when data changes
            contentRefreshTrigger.toggle()
        }
        .onChange(of: videoImporter.isImporting) { _, isImporting in
            if !isImporting && showingImportProgress {
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
            }
        }
    }
    
    // MARK: - Platform-Specific Content Views
    
    @ViewBuilder
    private var macOSContentView: some View {
        switch viewMode {
        case .grid:
            macOSGridView
        case .list:
            macOSListView
        }
    }
    
    @ViewBuilder
    private var iOSContentView: some View {
        switch viewMode {
        case .grid:
            iOSGridView
        case .list:
            iOSListView
        }
    }
    
    // MARK: - Grid Views
    
    @ViewBuilder
    private var macOSGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 16) {
                ForEach(content, id: \.id) { item in
                    contentNavigationLink(for: item)
                        .contextMenu {
                            macOSContextMenu(for: item)
                        }
                        .onHover { isHovered in
                            // macOS hover effects could be added here
                        }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var iOSGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                ForEach(content, id: \.id) { item in
                    contentNavigationLink(for: item)
                        .contextMenu {
                            iOSContextMenu(for: item)
                        }
                }
            }
            .padding()
        }
        #if os(iOS)
        .refreshable {
            // iOS pull-to-refresh
            await refreshContent()
        }
        #endif
    }
    
    // MARK: - List Views
    
    @ViewBuilder
    private var macOSListView: some View {
        List(selection: $selectedItems) {
            ForEach(content, id: \.id) { item in
                contentNavigationLink(for: item)
                    .tag(item.id)
                    .contextMenu {
                        macOSContextMenu(for: item)
                    }
            }
        }
        .listStyle(.inset)
        .onChange(of: selectedItems) { _, newSelection in
            handleListSelection(newSelection)
        }
    }
    
    @ViewBuilder
    private var iOSListView: some View {
        List(selection: $selectedItems) {
            ForEach(content, id: \.id) { item in
                contentNavigationLink(for: item)
                    .tag(item.id)
                    .contextMenu {
                        iOSContextMenu(for: item)
                    }
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(isSelectionMode ? .active : .inactive))
        #endif
        .onChange(of: selectedItems) { _, newSelection in
            handleListSelection(newSelection)
        }
    }
    
    // MARK: - Navigation Link Helper
    
    @ViewBuilder
    private func contentNavigationLink(for item: ContentType) -> some View {
        let isItemSelected: Bool = {
            if isSelectionMode {
                return selectedItems.contains(item.id)
            } else {
                // In normal mode, show video as selected if it's the currently playing video
                if case .video(let video) = item {
                    return store.selectedVideo?.id == video.id
                } else {
                    return false
                }
            }
        }()
        
        let rowView = ContentRowView(
            content: item,
            isSelected: isItemSelected,
            showCheckbox: isSelectionMode,
            viewMode: viewMode == .grid ? .grid : .list,
            selectedItems: $selectedItems
        )
        
        switch item {
        case .folder(let folder):
            if !isSelectionMode {
                NavigationLink(value: folder.id) {
                    rowView
                }
                .buttonStyle(.plain)
            } else {
                rowView
            }
            
        case .video:
            // Let the List handle all selection - no custom Button needed
            rowView
        }
    }
    
    // MARK: - Selection Handling
    
    private func handleListSelection(_ newSelection: Set<UUID>) {
        // Only handle single selections in normal mode (not selection mode)
        if !isSelectionMode {
            if let selectedID = newSelection.first,
               let selectedContent = content.first(where: { $0.id == selectedID }) {
                switch selectedContent {
                case .video(let video):
                    print("🎬 Selected video: \(video.title)")
                    store.selectVideo(video)
                case .folder:
                    // Let NavigationLink handle folder navigation
                    break
                }
            }
        }
    }
    
    
    // MARK: - Context Menus
    
    @ViewBuilder
    private func macOSContextMenu(for item: ContentType) -> some View {
        Group {
            Button("Open") {
                if case .folder = item {
                    // NavigationLink handles folder navigation automatically
                } else if case .video(let video) = item {
                    Task { @MainActor in
                        store.selectVideo(video)
                    }
                }
            }
            
            if case .folder = item {
                Button("Rename") {
                    // Handle rename
                }
                Divider()
                Button("Delete", role: .destructive) {
                    // Handle delete
                }
            }
        }
    }
    
    @ViewBuilder
    private func iOSContextMenu(for item: ContentType) -> some View {
        Group {
            if case .folder = item {
                Button {
                    // NavigationLink handles folder navigation automatically
                } label: {
                    Label("Open", systemImage: "folder")
                }
                
                Button {
                    // Handle rename
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                Button(role: .destructive) {
                    // Handle delete
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else if case .video(let video) = item {
                Button {
                    Task { @MainActor in
                        store.selectVideo(video)
                    }
                } label: {
                    Label("Play", systemImage: "play")
                }
            }
        }
    }
    
    // MARK: - Toolbar Content
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            macOSToolbarButtons
        }
        #else
        ToolbarItem(placement: .navigationBarLeading) {
            if !content.isEmpty {
                Button(isSelectionMode ? "Done" : "Select") {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedItems.removeAll()
                    }
                }
            }
        }
        
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            iOSToolbarMenu
        }
        #endif
    }
    
    @ViewBuilder
    private var macOSToolbarButtons: some View {
        Button(isSelectionMode ? "Done" : "Select") {
            isSelectionMode.toggle()
            if !isSelectionMode {
                selectedItems.removeAll()
            }
        }
        
        Button("Create Folder") { 
            showingCreateFolder = true 
        }
        
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
        
        Picker("View Mode", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.2x2" : "list.bullet")
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        
        Menu {
            ForEach(SortOption.allCases, id: \.self) { option in
                Button(option.rawValue) { 
                    store.currentSortOption = option 
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
    
    @ViewBuilder
    private var iOSToolbarMenu: some View {
        Menu {
            Button { 
                showingImportPicker = true 
            } label: {
                Label("Import Videos", systemImage: "square.and.arrow.down")
            }
            .disabled(libraryManager.currentLibrary == nil)
            
            Button { 
                showingCreateFolder = true 
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            
            Picker("View Mode", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.2x2" : "list.bullet")
                        .tag(mode)
                }
            }
            
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button(option.rawValue) { 
                        store.currentSortOption = option 
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    // MARK: - Helper Methods
    
    private func generateThumbnailsForVideos() {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else { return }
        
        isGeneratingThumbnails = true
        
        Task {
            await FileSystemManager.shared.generateMissingThumbnails(for: library, context: context)
            
            await MainActor.run {
                isGeneratingThumbnails = false
            }
        }
    }
    
    @MainActor
    private func refreshContent() async {
        // Refresh logic for iOS pull-to-refresh
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay for demo
    }
}