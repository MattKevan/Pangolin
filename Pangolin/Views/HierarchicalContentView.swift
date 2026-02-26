//
//  HierarchicalContentView.swift  
//  Pangolin
//
//  Created by Claude on 19/08/2025.
//

import SwiftUI
import CoreData
import Combine

/// A Finder-like hierarchical content view using SwiftUI's native Table with columns
@available(*, deprecated, message: "Legacy library content view. Current library routing uses FolderContentView/FolderOutlinePane/SmartFolderTablePane.")
struct HierarchicalContentView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var videoFileManager: VideoFileManager
    let searchText: String
    
    @State private var selectedItems: Set<UUID> = []
    @State private var showingDeletionConfirmation = false
    @State private var itemsToDelete: [DeletionItem] = []
    
    // Renaming state
    @State private var renamingItemID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var editedName: String = ""
    
    // Processing panel (simplified)
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    @State private var showingProcessingPanel = false
    
    // Create folder dialog
    @State private var showingCreateFolder = false
    
    // Track last explicitly selected video ID to preserve selection across refreshes
    @State private var lastSelectedVideoID: UUID?
    
    // Table sorting
    @State private var sortOrder = [KeyPathComparator(\HierarchicalContentItem.name)]
    
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
            .onReceive(NotificationCenter.default.publisher(for: .triggerRename)) { _ in
                triggerRenameFromMenu()
            }
            // Processing panel remains available if something external presents it
            .sheet(isPresented: $showingProcessingPanel) {
                VStack {
                    Text("Processing")
                        .font(.headline)
                    Text("Processing functionality has been simplified.")
                    Button("Close") {
                        showingProcessingPanel = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(minWidth: 300, minHeight: 200)
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
            .alert(deletionAlertContent.title, isPresented: $showingDeletionConfirmation) {
                Button("Cancel", role: .cancel) {
                    cancelDeletion()
                }
                Button("Delete", role: .destructive) {
                    Task {
                        await confirmDeletion()
                    }
                }
            } message: {
                Text(deletionAlertContent.message)
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
            FolderNavigationHeader(
                onCreateSubfolder: {
                    showingCreateFolder = true
                },
                onDeleteSelected: {
                    deleteSelectedItems()
                },
                hasSelectedItems: !selectedItems.isEmpty
            )
            
            hierarchicalTableView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Ensure the whole content fills the available space and pins to the top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.clear)
    }
    
    // MARK: - Table Content Builders
    
    @ViewBuilder
    private func buildNameCellContent(for item: HierarchicalContentItem) -> some View {
        HStack(spacing: 8) {
            buildItemIcon(for: item)
            buildItemName(for: item)
            Spacer(minLength: 0)
        }
    }
    
    @ViewBuilder
    private func buildItemIcon(for item: HierarchicalContentItem) -> some View {
        if case .video(let video) = item.contentType {
            VideoThumbnailView(video: video, size: CGSize(width: 20, height: 14), showsDurationOverlay: false, showsCloudStatusOverlay: false)
                .frame(width: 20, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Image(systemName: item.isFolder ? "folder" : "play.rectangle")
                .foregroundColor(item.isFolder ? .accentColor : .primary)
                .frame(width: 16, height: 16)
        }
    }
    
    @ViewBuilder
    private func buildItemName(for item: HierarchicalContentItem) -> some View {
        if renamingItemID == item.id {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: item.id)
                .onAppear {
                    editedName = item.name
                }
                .onSubmit {
                    Task { await commitRename() }
                }
                .onKeyPress(.escape) {
                    cancelRename()
                    return .handled
                }
        } else {
            Text(item.name)
                .lineLimit(1)
        }
    }
    
    @ViewBuilder
    private func buildDurationContent(for item: HierarchicalContentItem) -> some View {
        if case .video(let video) = item.contentType {
            Text(video.formattedDuration)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            Text("")
        }
    }
    
    @ViewBuilder
    private func buildPlayedContent(for item: HierarchicalContentItem) -> some View {
        if case .video(let video) = item.contentType {
            Image(systemName: video.watchStatus.systemImage)
                .foregroundColor(watchStatusColor(video.watchStatus))
                .help(video.watchStatus.displayName)
        } else {
            Text("")
        }
    }
    
    @ViewBuilder
    private func buildFavoriteContent(for item: HierarchicalContentItem) -> some View {
        if case .video(let video) = item.contentType {
            Button {
                toggleFavorite(video: video)
            } label: {
                Image(systemName: video.isFavorite ? "heart.fill" : "heart")
                    .foregroundColor(video.isFavorite ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(video.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        } else {
            Text("")
        }
    }
    
    @ViewBuilder
    private func buildiCloudStatusContent(for item: HierarchicalContentItem) -> some View {
        if case .video(let video) = item.contentType {
            VideoICloudStatusCell(video: video)
        } else {
            Text("")
        }
    }
    
    @ViewBuilder 
    private var hierarchicalTableView: some View {
        Table(filteredContent, children: \.children, selection: $selectedItems, sortOrder: $sortOrder) {
            
            TableColumn("Name") { item in
                buildNameCellContent(for: item)
            }
            .width(min: 200, ideal: 300, max: nil)
            
            TableColumn("Duration") { item in
                buildDurationContent(for: item)
            }
            .width(min: 80, ideal: 80, max: 100)
            
            TableColumn("Played") { item in
                buildPlayedContent(for: item)
            }
            .width(min: 60, ideal: 60, max: 80)
            
            TableColumn("Favorite") { item in
                buildFavoriteContent(for: item)
            }
            .width(min: 60, ideal: 60, max: 80)
            
            TableColumn("iCloud") { item in
                buildiCloudStatusContent(for: item)
            }
            .width(min: 120, ideal: 140, max: 180)
        }
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .tableStyle(.automatic)
        .contextMenu(forSelectionType: UUID.self) { selection in
            if !selection.isEmpty {
                bulkProcessingContextMenu(for: selection)
            }
        }
        .onChange(of: selectedItems) { oldSelection, newSelection in
            print("🔍 TABLE SELECTION: Changed from \(oldSelection.count) to \(newSelection.count) items")
            print("🔍 TABLE SELECTION: New selection: \(newSelection)")
            handleSelectionChange(newSelection)
        }
        .onChange(of: sortOrder) { _, newSortOrder in
            // Handle sorting - would need to implement sorting in the store
            // For now, we'll keep the current order
        }
        .draggable(dragPayload)
        .dropDestination(for: ContentTransfer.self) { items, location in
            // Handle drop operations
            return handleTableDrop(items)
        } isTargeted: { isTargeted in
            // Could add visual feedback for drop targeting
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

                Button("Generate Thumbnails (\(selectedVideos.count) videos)") {
                    processingQueueManager.addThumbnailsOnly(for: selectedVideos)
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

    private func watchStatusColor(_ status: VideoWatchStatus) -> Color {
        switch status {
        case .unwatched:
            return .secondary
        case .inProgress:
            return .orange
        case .watched:
            return .green
        }
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
                }
                // Don't restore selection for single video - let it be
            } else if newSelection.isEmpty {
                // Only restore selection if nothing is selected
                restoreSelectionIfPossible()
            } else {
                // Multi-selection: Preserve the currently active video in player view
                // Don't change video unless the current one is no longer selected
                
                if let currentlySelectedVideo = store.selectedVideo,
                   let currentVideoID = currentlySelectedVideo.id,
                   newSelection.contains(currentVideoID) {
                    // Current video is still in the selection - keep it active
                    lastSelectedVideoID = currentVideoID
                } else {
                    // Current video is not in selection, try to pick the most recently selected video
                    if let lastID = lastSelectedVideoID,
                       newSelection.contains(lastID),
                       let item = findItem(withID: lastID, in: filteredContent),
                       let video = item.video {
                        // Last selected video is in the multi-selection - use it
                        store.selectVideo(video)
                    } else {
                        // Pick the first video from the multi-selection for the player
                        for selectedID in newSelection {
                            if let item = findItem(withID: selectedID, in: filteredContent),
                               let video = item.video {
                                lastSelectedVideoID = video.id
                                store.selectVideo(video)
                                break
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func restoreSelectionIfPossible() {
        print("🔄 TABLE: Attempting to restore selection...")
        print("🔄 TABLE: Current selectedItems: \(selectedItems)")
        print("🔄 TABLE: Current store.selectedVideo: \(store.selectedVideo?.title ?? "none")")
        print("🔄 TABLE: LastSelectedVideoID: \(lastSelectedVideoID?.uuidString ?? "none")")
        
        // Check if store has a selected video that still exists in current content
        if let current = store.selectedVideo,
           let currentID = current.id,
           findItem(withID: currentID, in: filteredContent) != nil {
            
            // If table selection doesn't match store selection, update table
            if !selectedItems.contains(currentID) {
                print("✅ TABLE: Restoring selection to match store: \(current.title ?? "unknown")")
                lastSelectedVideoID = currentID
                selectedItems = [currentID]
                return
            } else {
                print("✅ TABLE: Selection already matches store")
                return
            }
        }
        
        // Store's selection is nil or doesn't exist - check if we have a valid table selection
        if let firstSelectedID = selectedItems.first,
           let item = findItem(withID: firstSelectedID, in: filteredContent),
           let video = item.video {
            print("✅ TABLE: Updating store to match table selection: \(video.title ?? "unknown")")
            lastSelectedVideoID = video.id
            store.selectVideo(video)
            return
        }
        
        // If we have a remembered last selected video ID, try to restore it
        if let lastID = lastSelectedVideoID,
           let item = findItem(withID: lastID, in: filteredContent),
           let video = item.video {
            print("✅ TABLE: Restoring last remembered selection: \(video.title ?? "unknown")")
            store.selectVideo(video)
            selectedItems = [lastID]
            return
        }
        
        // Clear invalid selections
        if !selectedItems.isEmpty {
            let validSelections = selectedItems.filter { id in
                findItem(withID: id, in: filteredContent) != nil
            }
            
            if validSelections.isEmpty {
                print("❌ TABLE: All selections invalid, clearing")
                selectedItems.removeAll()
                lastSelectedVideoID = nil
            } else {
                print("🔧 TABLE: Keeping valid selections: \(validSelections)")
                selectedItems = Set(validSelections)
            }
        }
        
        print("🔄 TABLE: Selection restoration complete")
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
    
    private var deletionAlertContent: DeletionAlertContent {
        itemsToDelete.deletionAlertContent
    }
    
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
    
    // MARK: - Drag and Drop
    
    private var dragPayload: ContentTransfer {
        // If selected items exist, drag all selected items, otherwise drag nothing
        if selectedItems.isEmpty {
            return ContentTransfer(itemIDs: [])
        } else {
            return ContentTransfer(itemIDs: Array(selectedItems))
        }
    }
    
    private func handleTableDrop(_ items: [ContentTransfer]) -> Bool {
        // For table-level drop, we might want to handle differently
        // For now, return false to indicate drop not handled at table level
        return false
    }
    
    // MARK: - Renaming Functions
    
    private func commitRename() async {
        guard let renamingID = renamingItemID,
              let item = findItem(withID: renamingID, in: filteredContent) else {
            await MainActor.run { cancelRename() }
            return
        }
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != item.name else {
            await MainActor.run { cancelRename() }
            return
        }
        
        // Use the store's rename function
        await store.renameItem(id: item.id, to: trimmedName)
        
        await MainActor.run {
            renamingItemID = nil
            focusedField = nil
        }
    }
    
    private func cancelRename() {
        renamingItemID = nil
        focusedField = nil
        editedName = ""
    }
    
    // MARK: - Favorite Toggle
    
    private func toggleFavorite(video: Video) {
        guard let context = libraryManager.viewContext else { return }
        
        video.isFavorite.toggle()
        
        do {
            try context.save()
            print("✅ FAVORITE: Toggled favorite status for video: \(video.title ?? "Unknown")")
        } catch {
            print("❌ FAVORITE: Failed to save favorite status: \(error)")
            // Revert the change on error
            video.isFavorite.toggle()
        }
    }
}
