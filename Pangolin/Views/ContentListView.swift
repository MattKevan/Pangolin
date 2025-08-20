//
//  ContentListView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import CoreData
import Combine

// NOTE: The old 'extension Notification.Name' is REMOVED from this file.
// The new name is now globally available from the 'NotificationNames.swift' file.

struct ContentListView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    let searchText: String
    @AppStorage("contentViewMode") private var viewMode = ViewMode.grid
    @State private var showingImportPicker = false
    @State private var showingImportProgress = false
    @StateObject private var videoImporter = VideoImporter()
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var showingCreateFolder = false
    @State private var isGeneratingThumbnails = false
    
    // Renaming state
    @State private var renamingItemID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var editedName: String = ""
    
    @State private var selectedItems: Set<UUID> = []
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif
    
    private var isSelectionMode: Bool {
        #if os(iOS)
        return editMode?.wrappedValue.isEditing ?? false
        #else
        return _isSelectionMode
        #endif
    }
    @State private var _isSelectionMode = false

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case list = "List"
    }
    
    var content: [ContentType] {        
        var allContent = store.content(for: store.currentFolderID)
        if !searchText.isEmpty {
            allContent = allContent.filter { item in
                item.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        return allContent
    }
    
    var videosWithoutThumbnails: [Video] {
        return content.compactMap { item in
            if case .video(let video) = item, video.thumbnailPath == nil {
                return video
            }
            return nil
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            FolderNavigationHeader {
                showingCreateFolder = true
            }
            
            contentView
        }
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
        .onChange(of: videoImporter.isImporting) { _, isImporting in
            if !isImporting && showingImportProgress {
                // CORRECTED: This now uses the globally defined notification name.
                // Apply this fix to all places where you post this notification.
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
            }
        }
        .sheet(isPresented: $showingCreateFolder) {
            CreateFolderView(parentFolderID: store.currentFolderID)
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil {
                // When focus is lost, clear renaming state if no commit happened
                if renamingItemID != nil {
                    renamingItemID = nil
                }
            }
        }
        .onKeyPress { keyPress in
            // Trigger rename on Return key for the single selected item on macOS
            guard keyPress.key == .return, selectedItems.count == 1,
                  let selectedID = selectedItems.first, renamingItemID == nil,
                  let selectedItem = content.first(where: { $0.id == selectedID }) else {
                return .ignored
            }
            
            // Initiate the rename process
            editedName = selectedItem.name
            renamingItemID = selectedID
            
            // Set focus programmatically
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                focusedField = selectedID
            }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentUpdated)) { _ in
            // Core Data change notifications now handled automatically
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if content.isEmpty {
            ContentUnavailableView("No Content", systemImage: "folder.badge.questionmark", description: Text(store.currentFolderID == nil ? "Import videos to get started" : "This folder is empty"))
        } else {
            switch viewMode {
            case .grid: gridView
            case .list: listView
            }
        }
    }
    
    @ViewBuilder
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                ForEach(content, id: \.id) { item in
                    ContentRowView(
                        content: item,
                        isSelected: selectedItems.contains(item.id),
                        showCheckbox: isSelectionMode,
                        viewMode: .grid,
                        selectedItems: $selectedItems,
                        renamingItemID: $renamingItemID,
                        focusedField: $focusedField,
                        editedName: $editedName
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        handleGridDoubleClick(on: item)
                    }
                    .simultaneousGesture(
                        TapGesture()
                            .modifiers(.command)
                            .onEnded {
                                handleGridCommandClick(on: item)
                            }
                    )
                    .simultaneousGesture(
                        TapGesture()
                            .modifiers(.shift)
                            .onEnded {
                                handleGridShiftClick(on: item)
                            }
                    )
                    .onTapGesture { 
                        handleGridTap(on: item)
                    }
                    .contextMenu {
                        Button("Rename") {
                            startRenaming(item)
                        }
                        Button("Delete", role: .destructive) {
                            // TODO: Implement deletion
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var listView: some View {
        List(selection: $selectedItems) {
            ForEach(content, id: \.id) { item in
                ContentRowView(
                    content: item,
                    isSelected: selectedItems.contains(item.id),
                    showCheckbox: isSelectionMode,
                    viewMode: .list,
                    selectedItems: $selectedItems,
                    renamingItemID: $renamingItemID,
                    focusedField: $focusedField,
                    editedName: $editedName
                )
                .contentShape(Rectangle()) // Ensure entire row is clickable
                .onTapGesture(count: 2) {
                    // Handle double-click separately
                    handleDoubleClick(on: item)
                }
                .contextMenu {
                    Button("Rename") {
                        startRenaming(item)
                    }
                    Button("Delete", role: .destructive) {
                        // TODO: Implement deletion
                    }
                }
                .tag(item.id)
            }
        }
        .onChange(of: selectedItems) { _, newSelection in
            handleSelectionChange(newSelection)
        }
        #if os(iOS)
        .environment(\.editMode, editMode)
        #endif
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup {
            if _isSelectionMode {
                Button("Done") {
                    _isSelectionMode = false
                    selectedItems.removeAll()
                }
            } else {
                macOSNormalButtons
            }
        }
        
        // Show selection count when items are selected (following macOS Finder pattern)
        ToolbarItem(placement: .status) {
            if !selectedItems.isEmpty && !isSelectionMode {
                Text("\(selectedItems.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        #else
        ToolbarItem(placement: .navigationBarLeading) {
            if !content.isEmpty {
                EditButton()
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            iOSMenu
        }
        #endif
    }
    
    @ViewBuilder
    private var macOSNormalButtons: some View {
        Button("Create Folder") { showingCreateFolder = true }
        Button("Import Videos") { showingImportPicker = true }
            .disabled(libraryManager.currentLibrary == nil)
        
        if !videosWithoutThumbnails.isEmpty {
            Button(isGeneratingThumbnails ? "Generating..." : "Generate Thumbnails") {
                generateThumbnailsForVideos()
            }
            .disabled(isGeneratingThumbnails)
        }
        
        Button("Select") { _isSelectionMode = true }
            .disabled(content.isEmpty)
        
        Picker("View Mode", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.2x2" : "list.bullet")
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        
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
            Button { showingImportPicker = true } label: { Label("Import Videos", systemImage: "square.and.arrow.down") }
                .disabled(libraryManager.currentLibrary == nil)
            Button { showingCreateFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Picker("View Mode", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode == .grid ? "square.grid.2x2" : "list.bullet").tag(mode)
                }
            }
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button(option.rawValue) { store.currentSortOption = option }
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    private func handleContentSelection(item: ContentType) {
        if isSelectionMode {
            if viewMode == .grid {
                if selectedItems.contains(item.id) {
                    selectedItems.remove(item.id)
                } else {
                    selectedItems.insert(item.id)
                }
            }
        } else {
            switch item {
            case .folder(let folder):
                store.navigateToFolder(folder.id!)
            case .video(let video):
                Task { @MainActor in
                    store.selectVideo(video)
                }
            }
            selectedItems.removeAll()
        }
    }
    
    /// Handles changes to SwiftUI List selection
    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        guard !isSelectionMode else { return }
        
        // Defer the state update to avoid "Publishing changes from within view updates" error
        Task { @MainActor in
            // When a single video is selected, set it for detail view
            if newSelection.count == 1, let selectedID = newSelection.first {
                if let selectedItem = content.first(where: { $0.id == selectedID }),
                   case .video(let video) = selectedItem {
                    store.selectVideo(video)
                }
            } else {
                // Clear selected video if not single selection
                store.selectedVideo = nil
            }
        }
    }
    
    /// Handles double-click for navigation
    private func handleDoubleClick(on item: ContentType) {
        guard !isSelectionMode else { return }
        
        switch item {
        case .folder(let folder):
            store.navigateToFolder(folder.id!)
        case .video(let video):
            Task { @MainActor in
                store.selectVideo(video)
            }
        }
    }
    
    /// Starts renaming for the given item
    private func startRenaming(_ item: ContentType) {
        editedName = item.name
        renamingItemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
            focusedField = item.id
        }
    }
    
    /// Handles all tap gestures for grid view (which doesn't have built-in selection)
    private func handleGridTap(on item: ContentType) {
        if isSelectionMode {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        } else {
            // Check for rename on already selected item (slow-click)
            if selectedItems.count == 1 && selectedItems.first == item.id && renamingItemID == nil {
                // Delay to distinguish from double-click
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s delay
                    if selectedItems.count == 1 && selectedItems.first == item.id {
                        editedName = item.name
                        renamingItemID = item.id
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s for focus
                        focusedField = item.id
                    }
                }
            } else {
                // Normal selection - need to handle manually for grid view
                selectedItems = [item.id]
                renamingItemID = nil // Cancel any ongoing rename
                
                // For videos, also set the selected video for detail view
                if case .video(let video) = item {
                    Task { @MainActor in
                        store.selectVideo(video)
                    }
                }
            }
        }
    }
    
    /// Handles double-click for grid view navigation
    private func handleGridDoubleClick(on item: ContentType) {
        guard !isSelectionMode else { return }
        
        switch item {
        case .folder(let folder):
            store.navigateToFolder(folder.id!)
        case .video(let video):
            // Double-click should also select the video
            Task { @MainActor in
                store.selectVideo(video)
            }
        }
    }
    
    /// Handles Command+Click for multi-selection
    private func handleGridCommandClick(on item: ContentType) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }
    
    /// Handles Shift+Click for range selection
    private func handleGridShiftClick(on item: ContentType) {
        // Find the last selected item's index by checking the content array
        var lastSelectedIndex: Int?
        for (index, contentItem) in content.enumerated() {
            if selectedItems.contains(contentItem.id) {
                lastSelectedIndex = index
            }
        }
        
        guard let lastIndex = lastSelectedIndex,
              let currentIndex = content.firstIndex(where: { $0.id == item.id }) else {
            // If no previous selection or can't find indices, just select this item
            selectedItems = [item.id]
            return
        }
        
        let startIndex = min(lastIndex, currentIndex)
        let endIndex = max(lastIndex, currentIndex)
        
        // Select all items in range
        let rangeItems = content[startIndex...endIndex].map { $0.id }
        selectedItems.formUnion(rangeItems)
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
