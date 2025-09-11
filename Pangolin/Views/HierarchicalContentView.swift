//
//  HierarchicalContentView.swift  
//  Pangolin
//
//  Created by Claude on 19/08/2025.
//

import SwiftUI
import CoreData
import Combine

/// A Finder-like hierarchical content view using SwiftUI's native OutlineGroup/hierarchical List
struct HierarchicalContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject var libraryManager: LibraryManager
    let searchText: String
    
    @State private var selectedItems: Set<UUID> = []
    @State private var showingDeletionConfirmation = false
    @State private var itemsToDelete: [DeletionItem] = []
    
    // Renaming state
    @State private var renamingItemID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var editedName: String = ""
    
    // Processing queue
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    @State private var showingProcessingPanel = false
    
    // Track last explicitly selected video ID to preserve selection across refreshes
    @State private var lastSelectedVideoID: UUID?
    
    // This property filters the store's reactive data source
    private var filteredContent: [HierarchicalContentItem] {
        let sourceContent = store.hierarchicalContent
        
        if searchText.isEmpty {
            return sourceContent
        } else {
            // Filter hierarchical content by search text
            return filterHierarchicalContent(sourceContent, searchText: searchText)
        }
    }
    
    var body: some View {
        contentView
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerRename"))) { _ in
                triggerRenameFromMenu()
            }
            // Processing panel remains available if something external presents it
            .sheet(isPresented: $showingProcessingPanel) {
                BulkProcessingView(
                    processingManager: processingQueueManager,
                    isPresented: $showingProcessingPanel
                )
            }
            .onKeyPress { keyPress in
                // Return key triggers rename on single selected item
                if keyPress.key == .return, selectedItems.count == 1,
                   let selectedID = selectedItems.first,
                   let selectedItem = findItem(withID: selectedID, in: filteredContent),
                   renamingItemID == nil {
                    startRenaming(selectedItem)
                    return .handled
                }
                // Delete key triggers deletion of selected items
                else if (keyPress.key == .delete || keyPress.key == .deleteForward), !selectedItems.isEmpty {
                    deleteSelectedItems()
                    return .handled
                }
                
                return .ignored
            }
            // Deletion confirmation sheet (still owned here because it's tightly coupled to selection)
            .sheet(isPresented: $showingDeletionConfirmation) {
                if !itemsToDelete.isEmpty {
                    DeletionConfirmationView(
                        items: itemsToDelete,
                        onConfirm: {
                            Task {
                                await confirmDeletion()
                            }
                        },
                        onCancel: {
                            cancelDeletion()
                        }
                    )
                } else {
                    // Fallback empty view - should not normally show
                    Text("No items to delete")
                        .padding()
                        .onAppear {
                            print("⚠️ SHEET: Empty deletion sheet appeared - this should not happen")
                            showingDeletionConfirmation = false
                        }
                }
            }
            // When content refreshes (store.hierarchicalContent changes), try to restore selection
            .onChange(of: store.hierarchicalContent) { _, _ in
                restoreSelectionIfPossible()
            }
    }
    
    @ViewBuilder
    private var contentView: some View {
        VStack(spacing: 0) {
            // Header remains for navigation affordance (if you still want to keep it)
            FolderNavigationHeader {
                // The "Add Folder" button was moved to MainView's toolbar.
                // If you still want the header's plus action to do something here, you can:
                // showingCreateFolder = true
            }
            
            if filteredContent.isEmpty {
                // Keep the header at the top; show empty state under it
                VStack(alignment: .center, spacing: 12) {
                    ContentUnavailableView(
                        "No Content",
                        systemImage: "folder.badge.questionmark",
                        description: Text(store.currentFolderID == nil ? "Import videos to get started" : "This folder is empty")
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                hierarchicalListView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // Ensure the whole content fills the available space and pins to the top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    @ViewBuilder 
    private var hierarchicalListView: some View {
        List(filteredContent, id: \.id, children: \.children, selection: $selectedItems) { item in
            HierarchicalContentRowView(
                item: item,
                renamingItemID: $renamingItemID,
                focusedField: $focusedField,
                editedName: $editedName,
                selectedItems: $selectedItems,
                onDelete: { itemID in
                    deleteSpecificItem(itemID)
                }
            )
            .contentShape(Rectangle()) // Ensure full row is clickable
        }
        .contextMenu(forSelectionType: UUID.self) { selection in
            if !selection.isEmpty {
                bulkProcessingContextMenu(for: selection)
            }
        }
        .onChange(of: selectedItems) { _, newSelection in
            handleSelectionChange(newSelection)
        }
    }
    
    // MARK: - Context Menu Functions
    
    @ViewBuilder
    private func bulkProcessingContextMenu(for selection: Set<UUID>) -> some View {
        let selectedVideos = getSelectedVideos(from: selection)
        
        if !selectedVideos.isEmpty {
            Menu("Processing Queue") {
                Button("Transcribe (\(selectedVideos.count) videos)") {
                    processingQueueManager.addTranscriptionOnly(for: selectedVideos)
                }
                
                Button("Translate (\(selectedVideos.count) videos)") {
                    processingQueueManager.addTranslationOnly(for: selectedVideos)
                }
                
                Button("Summarize (\(selectedVideos.count) videos)") {
                    processingQueueManager.addSummaryOnly(for: selectedVideos)
                }
                
                Divider()
                
                Button("Full Workflow (\(selectedVideos.count) videos)") {
                    processingQueueManager.addFullProcessingWorkflow(for: selectedVideos)
                }
                
                Button("Transcribe & Summarize (\(selectedVideos.count) videos)") {
                    processingQueueManager.addTranscriptionAndSummary(for: selectedVideos)
                }
            }
            
            Divider()
        }
        
        Button("Delete Selected") {
            deleteSelectedItems()
        }
        .disabled(selection.isEmpty)
    }
    
    private func getSelectedVideos(from selection: Set<UUID>) -> [Video] {
        var videos: [Video] = []
        
        func extractVideos(from items: [HierarchicalContentItem], selectedIDs: Set<UUID>) {
            for item in items {
                if selectedIDs.contains(item.id) {
                    if case .video(let video) = item.contentType {
                        videos.append(video)
                    }
                }
                
                if let children = item.children {
                    extractVideos(from: children, selectedIDs: selectedIDs)
                }
            }
        }
        
        extractVideos(from: filteredContent, selectedIDs: selection)
        return videos
    }
    
    // MARK: - Helper Functions
    
    private var videosWithoutThumbnails: [Video] {
        return getAllVideos(from: store.hierarchicalContent).filter { $0.thumbnailPath == nil }
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
            
            // Recursively filter children
            let filteredChildren = item.children.flatMap { filterHierarchicalContent($0, searchText: searchText) }
            
            // Include if name matches OR if it has children that match
            if nameMatches || (filteredChildren?.isEmpty == false) {
                var filteredItem = item
                // Assign the filtered children back to the item
                filteredItem.children = filteredChildren
                return filteredItem
            }
            return nil
        }
    }
    
    private func handleSelectionChange(_ newSelection: Set<UUID>) {
        // Defer the state update to avoid "Publishing changes from within view updates" error
        Task { @MainActor in
            // When a single video is selected, set it for detail view
            if newSelection.count == 1, let selectedID = newSelection.first {
                if let selectedItem = findItem(withID: selectedID, in: filteredContent),
                   let video = selectedItem.video {
                    lastSelectedVideoID = video.id
                    store.selectVideo(video)
                } else {
                    // ID exists but no longer maps to a video (e.g., filtered out)
                    // Keep previous selection if possible
                    restoreSelectionIfPossible()
                }
            } else {
                // Selection became empty or multi-selected. Do not clear the currently selected video immediately.
                // Try to preserve the last selected video if it still exists.
                restoreSelectionIfPossible()
            }
        }
    }
    
    private func restoreSelectionIfPossible() {
        // If we already have a selected video in the store and it still exists, keep it.
        if let current = store.selectedVideo,
           findItem(withID: current.id!, in: filteredContent) != nil {
            lastSelectedVideoID = current.id
            // Optionally re-assert the list selection to match the detail selection.
            if selectedItems != [current.id!] {
                selectedItems = [current.id!]
            }
            return
        }
        
        // If we have a remembered last selected video ID, reselect it if still present
        if let lastID = lastSelectedVideoID,
           let item = findItem(withID: lastID, in: filteredContent),
           let video = item.video {
            store.selectVideo(video)
            if selectedItems != [lastID] {
                selectedItems = [lastID]
            }
            return
        }
        
        // Otherwise, fall back to the store's auto-selection logic (it selects first video if needed)
        // Sync the list selection to match store.selectedVideo if set
        if let fallback = store.selectedVideo?.id {
            if selectedItems != [fallback] {
                selectedItems = [fallback]
            }
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
    
    // MARK: - Deletion Methods
    
    private func deleteSelectedItems() {
        print("🗑️ CONTENT: deleteSelectedItems called with selectedItems: \(selectedItems)")
        
        guard let context = libraryManager.viewContext else {
            print("⚠️ CONTENT: No view context available")
            return
        }
        
        var deletionItems: [DeletionItem] = []
        
        for itemID in selectedItems {
            if let item = findItem(withID: itemID, in: filteredContent) {
                print("🗑️ CONTENT: Found item \(item.name) for deletion - contentType: \(item.contentType)")
                switch item.contentType {
                case .folder(let folder):
                    print("🗑️ CONTENT: Creating deletion item for folder: \(folder.name ?? "nil")")
                    deletionItems.append(DeletionItem(folder: folder))
                case .video(let video):
                    print("🗑️ CONTENT: Creating deletion item for video: \(video.title ?? "nil")")
                    deletionItems.append(DeletionItem(video: video))
                }
            } else {
                print("🗑️ CONTENT: ⚠️ Could not find item with ID: \(itemID)")
            }
        }
        
        // Check if any system folders are selected
        let hasSystemFolder = deletionItems.contains { item in
            if item.isFolder {
                // Find the folder in Core Data and check if it's a system folder
                let request = Folder.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                if let folder = try? context.fetch(request).first {
                    return folder.isSmartFolder
                }
            }
            return false
        }
        
        if hasSystemFolder {
            // Show error - cannot delete system folders
            store.errorMessage = "Cannot delete system folders"
            return
        }
        
        guard !deletionItems.isEmpty else {
            print("⚠️ CONTENT: No items found for deletion from selectedItems: \(selectedItems)")
            // Don't show the sheet if there are no items
            return
        }
        
        print("🗑️ CONTENT: Setting itemsToDelete to \(deletionItems.count) items: \(deletionItems.map { $0.name })")
        itemsToDelete = deletionItems
        
        print("🗑️ CONTENT: About to set showingDeletionConfirmation = true")
        showingDeletionConfirmation = true
        print("🗑️ CONTENT: showingDeletionConfirmation is now: \(showingDeletionConfirmation)")
        print("🗑️ CONTENT: itemsToDelete.count is now: \(itemsToDelete.count)")
    }
    
    private func confirmDeletion() async {
        let itemIDs = Set(itemsToDelete.map { $0.id })
        let success = await store.deleteItems(itemIDs)
        
        await MainActor.run {
            if success {
                // Clear selection
                selectedItems.removeAll()
                lastSelectedVideoID = nil
            }
            cancelDeletion()
        }
    }
    
    private func cancelDeletion() {
        itemsToDelete.removeAll()
        showingDeletionConfirmation = false
    }
    
    private func deleteSpecificItem(_ itemID: UUID) {
        print("🎯 CONTENT: deleteSpecificItem called for ID: \(itemID)")
        
        // Find the item to get more context
        if let item = findItem(withID: itemID, in: filteredContent) {
            print("🎯 CONTENT: Found item: \(item.name) - isFolder: \(item.isFolder)")
        } else {
            print("🎯 CONTENT: ⚠️ Could not find item with ID: \(itemID)")
        }
        
        // Set the selection to just this item and trigger deletion
        selectedItems = [itemID]
        print("🎯 CONTENT: Set selectedItems to: \(selectedItems)")
        deleteSelectedItems()
    }
    
    private func triggerRenameFromMenu() {
        // Trigger rename on the first selected item
        if selectedItems.count == 1, let selectedID = selectedItems.first,
           let selectedItem = findItem(withID: selectedID, in: filteredContent) {
            startRenaming(selectedItem)
        }
    }
}

