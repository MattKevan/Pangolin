//
//  FolderContentView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import CoreData

struct FolderContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    let searchText: String
    @AppStorage("contentViewMode") private var viewMode = ViewMode.grid
    @State private var showingImportPicker = false
    @State private var showingImportProgress = false
    @StateObject private var videoImporter = VideoImporter()
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var showingCreateFolder = false
    @State private var isGeneratingThumbnails = false
    
    // State for managing which item is being renamed and which field is focused.
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
        .onChange(of: videoImporter.isImporting) { _, isImporting in
            if !isImporting && showingImportProgress {
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
            }
        }
        .sheet(isPresented: $showingCreateFolder) {
            CreateFolderView(parentFolderID: store.currentFolderID)
        }
        // This onChange handles committing a rename when the user clicks away,
        // causing the TextField to lose focus.
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil {
                // If focus is lost (e.g., user clicked elsewhere), and we were in the middle
                // of a rename, we should end the rename process. The commit is handled
                // by the `onSubmit` modifier in the ContentRowView's TextField.
                renamingItemID = nil
            }
        }
        .onKeyPress { keyPress in
            // Trigger rename on Return key for the single selected item on macOS
            guard keyPress.key == .return, selectedItems.count == 1,
                  let selectedID = selectedItems.first else {
                return .ignored
            }
            
            // Initiate the rename process
            renamingItemID = selectedID
            
            // Programmatically set focus to the TextField
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                focusedField = selectedID
            }
            return .handled
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
                    .onTapGesture { handleTap(on: item) }
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
                .contentShape(Rectangle())
                .onTapGesture { handleTap(on: item) }
                .tag(item.id)
            }
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
    
    /// Handles all tap gestures to manage selection and trigger the Finder-style "slow-click" rename.
    private func handleTap(on item: ContentType) {
        if isSelectionMode {
            if viewMode == .grid {
                if selectedItems.contains(item.id) {
                    selectedItems.remove(item.id)
                } else {
                    selectedItems.insert(item.id)
                }
            }
        } else {
            // If the item we are tapping is the only one selected, start renaming it.
            if selectedItems.count == 1 && selectedItems.first == item.id {
                editedName = item.name
                renamingItemID = item.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                    focusedField = item.id
                }
            } else {
                // Otherwise, handle normal navigation/selection.
                selectedItems = [item.id]
                switch item {
                case .folder(let folder):
                    store.navigateToFolder(folder.id)
                case .video(let video):
                    Task { @MainActor in
                        store.selectVideo(video)
                    }
                }
            }
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
