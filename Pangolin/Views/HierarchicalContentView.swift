//
//  HierarchicalContentView.swift  
//  Pangolin
//
//  Created by Claude on 19/08/2025.
//

import SwiftUI
import CoreData

/// A Finder-like hierarchical content view using SwiftUI's native OutlineGroup/hierarchical List
struct HierarchicalContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject var libraryManager: LibraryManager
    let searchText: String
    
    @State private var refreshTrigger = UUID()
    @State private var selectedItems: Set<UUID> = []
    @State private var showingImportPicker = false
    @State private var showingImportProgress = false
    @State private var showingCreateFolder = false
    @State private var isGeneratingThumbnails = false
    @StateObject private var videoImporter = VideoImporter()
    
    // Renaming state
    @State private var renamingItemID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var editedName: String = ""
    
    private var hierarchicalContent: [HierarchicalContentItem] {
        let _ = refreshTrigger // Force recomputation
        let allContent = store.hierarchicalContent(for: store.currentFolderID)
        
        if searchText.isEmpty {
            return allContent
        } else {
            // Filter hierarchical content by search text
            return filterHierarchicalContent(allContent, searchText: searchText)
        }
    }
    
    var body: some View {
        contentView
        .toolbar {
            toolbarContent
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.movie, .video, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if let library = libraryManager.currentLibrary, let context = libraryManager.viewContext {
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
            CreateFolderView(parentFolderID: store.currentFolderID)
        }
        .onChange(of: videoImporter.isImporting) { _, isImporting in
            if !isImporting && showingImportProgress {
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentUpdated)) { _ in
            DispatchQueue.main.async {
                refreshTrigger = UUID()
            }
        }
        .onKeyPress { keyPress in
            // Return key triggers rename on single selected item
            guard keyPress.key == .return, selectedItems.count == 1,
                  let selectedID = selectedItems.first,
                  let selectedItem = findItem(withID: selectedID, in: hierarchicalContent) else {
                return .ignored
            }
            
            startRenaming(selectedItem)
            return .handled
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if hierarchicalContent.isEmpty {
            ContentUnavailableView(
                "No Content", 
                systemImage: "folder.badge.questionmark", 
                description: Text(store.currentFolderID == nil ? "Import videos to get started" : "This folder is empty")
            )
        } else {
            hierarchicalListView
        }
    }
    
    @ViewBuilder 
    private var hierarchicalListView: some View {
        List(hierarchicalContent, id: \.id, children: \.children, selection: $selectedItems) { item in
            HierarchicalContentRowView(
                item: item,
                renamingItemID: $renamingItemID,
                focusedField: $focusedField,
                editedName: $editedName,
                selectedItems: $selectedItems
            )
            .contentShape(Rectangle()) // Ensure full row is clickable
        }
        .onChange(of: selectedItems) { _, newSelection in
            handleSelectionChange(newSelection)
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            macOSToolbarButtons
        }
        
        // Show selection count when items are selected
        ToolbarItem(placement: .status) {
            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        #else
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            iOSMenu
        }
        #endif
    }
    
    @ViewBuilder
    private var macOSToolbarButtons: some View {
        Button("Create Folder") { showingCreateFolder = true }
        Button("Import Videos") { showingImportPicker = true }
            .disabled(libraryManager.currentLibrary == nil)
        
        if !videosWithoutThumbnails.isEmpty {
            Button(isGeneratingThumbnails ? "Generating..." : "Generate Thumbnails") {
                generateThumbnailsForVideos()
            }
            .disabled(isGeneratingThumbnails)
        }
        
        Menu {
            ForEach(SortOption.allCases, id: \.self) { option in
                Button(option.rawValue) { store.currentSortOption = option }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
    
    @ViewBuilder
    private var iOSMenu: some View {
        Menu {
            Button { showingImportPicker = true } label: { 
                Label("Import Videos", systemImage: "square.and.arrow.down") 
            }
            .disabled(libraryManager.currentLibrary == nil)
            Button { showingCreateFolder = true } label: { 
                Label("New Folder", systemImage: "folder.badge.plus") 
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    // MARK: - Helper Functions
    
    private var videosWithoutThumbnails: [Video] {
        return getAllVideos(from: hierarchicalContent).filter { $0.thumbnailPath == nil }
    }
    
    private func getAllVideos(from items: [HierarchicalContentItem]) -> [Video] {
        var videos: [Video] = []
        for item in items {
            if let video = item.video {
                videos.append(video)
            }
            if let children = item.children {
                videos.append(contentsOf: getAllVideos(from: children))
            }
        }
        return videos
    }
    
    private func findItem(withID id: UUID, in items: [HierarchicalContentItem]) -> HierarchicalContentItem? {
        for item in items {
            if item.id == id {
                return item
            }
            if let children = item.children,
               let found = findItem(withID: id, in: children) {
                return found
            }
        }
        return nil
    }
    
    private func filterHierarchicalContent(_ items: [HierarchicalContentItem], searchText: String) -> [HierarchicalContentItem] {
        return items.compactMap { item in
            let nameMatches = item.name.localizedCaseInsensitiveContains(searchText)
            let filteredChildren = item.children?.compactMap { child in
                filterHierarchicalContent([child], searchText: searchText).first
            }
            
            if nameMatches || (filteredChildren?.isEmpty == false) {
                var filteredItem = item
                filteredItem.children = filteredChildren
                return filteredItem
            }
            return nil
        }
    }
    
    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        // When a single video is selected, set it for detail view
        if newSelection.count == 1, let selectedID = newSelection.first {
            if let selectedItem = findItem(withID: selectedID, in: hierarchicalContent),
               let video = selectedItem.video {
                store.selectVideo(video)
            }
        } else {
            store.selectedVideo = nil
        }
    }
    
    private func startRenaming(_ item: HierarchicalContentItem) {
        editedName = item.name
        renamingItemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
            focusedField = item.id
        }
    }
    
    private func generateThumbnailsForVideos() {
        guard let library = libraryManager.currentLibrary, let context = libraryManager.viewContext else { return }
        isGeneratingThumbnails = true
        Task {
            await FileSystemManager.shared.generateMissingThumbnails(for: library, context: context)
            await MainActor.run {
                isGeneratingThumbnails = false
            }
        }
    }
}