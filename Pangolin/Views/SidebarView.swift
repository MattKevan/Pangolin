//
//  SidebarView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import CoreData
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    
    @State private var renamingFolderID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var folderToDelete: DeletionItem?
    @State private var sidebarSelections = Set<SidebarSelection>()
    @State private var isSyncingSidebarSelections = false
    
    @State private var systemFolders: [Folder] = []
    @State private var userFolders: [Folder] = []
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var isDeletingFolder = false
    @State private var isInternalRootDropTargeted = false
    @State private var isExternalDropTargeted = false

    private let processingQueueManager = ProcessingQueueManager.shared

    private struct VisibleLibraryItem: Identifiable {
        let item: HierarchicalContentItem
        let depth: Int

        var id: UUID { item.id }
    }

    private var libraryRootItems: [HierarchicalContentItem] {
        userFolders.map(HierarchicalContentItem.init(folder:))
    }

    private var visibleLibraryItems: [VisibleLibraryItem] {
        flattenVisibleLibraryItems(from: libraryRootItems, depth: 0)
    }
    
    var body: some View {
        List(selection: $sidebarSelections) {
            // Search item
            Section("Pangolin") {
                Label("Search", systemImage: "magnifyingglass")
                    .contentShape(Rectangle())
                    .tag(SidebarSelection.search)
                
                ForEach(systemFolders) { folder in
                    FolderRowView(
                        folder: folder,
                        showContextMenu: false,
                        renamingFolderID: $renamingFolderID,
                        focusedField: $focusedField,
                        onCreateSubfolder: { _ in },
                        onDelete: {}
                    )
                    .contentShape(Rectangle()) // Make the entire row clickable
                    .tag(SidebarSelection.folder(folder))
                }
            }
            
            // Library hierarchy (folders + videos)
            Section("Library") {
                ForEach(visibleLibraryItems) { visibleItem in
                    SidebarLibraryOutlineRow(
                        item: visibleItem.item,
                        depth: visibleItem.depth,
                        isExpanded: expandedFolderIDs.contains(visibleItem.item.id),
                        dragItemIDs: dragItemIDs(for: visibleItem.item.id),
                        renamingFolderID: $renamingFolderID,
                        focusedField: $focusedField,
                        onToggleExpansion: {
                            toggleFolderExpansion(for: visibleItem.item)
                        },
                        onCreateSubfolder: createChildFolder,
                        onDeleteFolder: deleteFolder
                    )
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                    .tag(sidebarSelection(for: visibleItem.item))
                }
            }
        }
        #if os(macOS)
        .listStyle(SidebarListStyle())
        #else
        .listStyle(InsetGroupedListStyle())
        #endif
        .contextMenu {
            Button("New Folder") {
                createTopLevelFolder()
            }
            .disabled(libraryManager.currentLibrary == nil)
        }
        // Removed Sidebar toolbar to avoid duplicates and overflow.
        // Add-folder is now owned by MainView's toolbar.
        .alert(
            sidebarDeletionAlertContent.title,
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        cancelDeletion()
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                cancelDeletion()
            }
            Button("Delete", role: .destructive) {
                guard let deletionItem = folderToDelete else {
                    cancelDeletion()
                    return
                }
                Task {
                    await confirmDeletion(deletionItem)
                }
            }
        } message: {
            Text(sidebarDeletionAlertContent.message)
        }
        .onKeyPress { keyPress in
            // When an inline editor is active, let the TextField handle Return/Delete.
            if renamingFolderID != nil || focusedField != nil {
                return .ignored
            }

            if keyPress.key == .return,
               case .folder(let selected) = store.selectedSidebarItem,
               !selected.isSmartFolder { // Only allow renaming for user folders
                renamingFolderID = selected.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                    focusedField = selected.id
                }
                return .handled
            } else if (keyPress.key == .delete || keyPress.key == .deleteForward),
                      case .folder(let selected) = store.selectedSidebarItem,
                      !selected.isSmartFolder { // Only allow deletion for user folders
                deleteFolder(selected)
                return .handled
            }
            return .ignored
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerRename)) { _ in
            triggerRenameFromMenu()
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerCreateFolder)) { _ in
            createFolderFromCurrentSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
            if !isDeletingFolder {
                refreshFolders()
            }
        }
        .onReceive(libraryManager.$currentLibrary) { _ in
            refreshFolders()
        }
        .onAppear {
            refreshFolders()
            syncSidebarSelections(with: store.selectedSidebarItem)
        }
        .onChange(of: sidebarSelectionExpansionKey) { _, _ in
            syncExpandedFoldersForSelection()
        }
        .onChange(of: store.selectedVideo?.id) { _, _ in
            syncExpandedFoldersForSelection()
        }
        .onChange(of: sidebarSelections) { oldSelection, newSelection in
            syncStoreSelection(oldSelection: oldSelection, newSelection: newSelection)
        }
        .onChange(of: store.selectedSidebarItem) { _, newSelection in
            syncSidebarSelections(with: newSelection)
        }
        .onDrop(of: [.data], isTargeted: $isInternalRootDropTargeted) { providers in
            handleInternalRootDrop(providers: providers)
        }
        .onDrop(of: [.fileURL], isTargeted: $isExternalDropTargeted) { providers in
            handleExternalFileDrop(providers: providers)
        }
        .overlay(alignment: .top) {
            if isExternalDropTargeted {
                Text("Drop videos or folders to import")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
    }
    
    private func refreshFolders() {
        systemFolders = store.systemFolders()
        userFolders = store.userFolders()
        syncExpandedFoldersForSelection()
    }

    private func syncStoreSelection(oldSelection: Set<SidebarSelection>, newSelection: Set<SidebarSelection>) {
        guard !isSyncingSidebarSelections else { return }

        let nextSelection: SidebarSelection?
        if newSelection.isEmpty {
            nextSelection = nil
        } else if let currentSelection = store.selectedSidebarItem, newSelection.contains(currentSelection) {
            nextSelection = currentSelection
        } else if let newlyAdded = newSelection.subtracting(oldSelection).first {
            nextSelection = newlyAdded
        } else {
            nextSelection = newSelection.first
        }

        guard !selectionKeysEqual(lhs: store.selectedSidebarItem, rhs: nextSelection) else { return }

        isSyncingSidebarSelections = true
        store.selectedSidebarItem = nextSelection
        isSyncingSidebarSelections = false
    }

    private func syncSidebarSelections(with selection: SidebarSelection?) {
        guard !isSyncingSidebarSelections else { return }
        let nextSelections = selection.map { Set([$0]) } ?? []
        guard sidebarSelections != nextSelections else { return }

        isSyncingSidebarSelections = true
        sidebarSelections = nextSelections
        isSyncingSidebarSelections = false
    }

    private func selectionKeysEqual(lhs: SidebarSelection?, rhs: SidebarSelection?) -> Bool {
        switch (lhs, rhs) {
        case (.search, .search):
            return true
        case let (.folder(leftFolder), .folder(rightFolder)):
            return leftFolder.id == rightFolder.id
        case let (.video(leftVideo), .video(rightVideo)):
            return leftVideo.id == rightVideo.id
        case (.none, .none):
            return true
        default:
            return false
        }
    }

    private func dragItemIDs(for itemID: UUID) -> [UUID] {
        let selectedMovableIDs = Set(sidebarSelections.compactMap { selection -> UUID? in
            switch selection {
            case .search:
                return nil
            case .folder(let folder):
                guard !folder.isSmartFolder else { return nil }
                return folder.id
            case .video(let video):
                return video.id
            }
        })

        if selectedMovableIDs.contains(itemID), selectedMovableIDs.count > 1 {
            return Array(selectedMovableIDs)
        }

        return [itemID]
    }
    
    private var sidebarDeletionAlertContent: DeletionAlertContent {
        guard let folderToDelete else {
            return [].deletionAlertContent
        }
        return [folderToDelete].deletionAlertContent
    }
    
    private func deleteFolder(_ folder: Folder) {
        print("🗑️ SIDEBAR: deleteFolder called for: \(folder.name ?? "nil") (ID: \(folder.id ?? UUID()))")
        isDeletingFolder = true
        // Create a snapshot that won't be affected by Core Data changes
        let deletionItem = DeletionItem(folder: folder)
        print("🗑️ SIDEBAR: Created deletion item: \(deletionItem.name)")
        folderToDelete = deletionItem
        print("🗑️ SIDEBAR: Set folderToDelete item, this should trigger alert")
    }
    
    private func confirmDeletion(_ deletionItem: DeletionItem) async {
        let success = await store.deleteItems([deletionItem.id])
        
        await MainActor.run {
            if success {
                // Clear selection if the deleted folder was selected
                if case .folder(let selectedFolder) = store.selectedSidebarItem,
                   selectedFolder.id == deletionItem.id {
                    // Select "All Videos" folder as fallback
                    store.selectAllVideos()
                }
            }
            
            cancelDeletion()
        }
    }
    
    private func cancelDeletion() {
        folderToDelete = nil
        isDeletingFolder = false
        // Refresh folders after deletion process is complete
        refreshFolders()
    }
    
    private func triggerRenameFromMenu() {
        // Trigger rename on the selected sidebar folder
        if case .folder(let selected) = store.selectedSidebarItem,
           !selected.isSmartFolder { // Only allow renaming for user folders
            renamingFolderID = selected.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                focusedField = selected.id
            }
        }
    }

    private func createFolderFromCurrentSelection() {
        let parentFolderID = selectedParentFolderIDForNewFolder()
        createFolder(parentFolderID: parentFolderID)
    }

    private func createTopLevelFolder() {
        createFolder(parentFolderID: nil)
    }

    private func createChildFolder(_ parentFolder: Folder) {
        createFolder(parentFolderID: parentFolder.id)
    }

    private func selectedParentFolderIDForNewFolder() -> UUID? {
        switch store.selectedSidebarItem {
        case .folder(let folder):
            return folder.isSmartFolder ? nil : folder.id
        case .video(let video):
            guard let folder = video.folder, !folder.isSmartFolder else { return nil }
            return folder.id
        case .search, .none:
            guard let currentFolder = store.currentFolder, !currentFolder.isSmartFolder else { return nil }
            return currentFolder.id
        }
    }

    private func createFolder(parentFolderID: UUID?) {
        guard libraryManager.currentLibrary != nil else { return }

        if let parentFolderID {
            expandedFolderIDs.insert(parentFolderID)
        }

        Task { @MainActor in
            guard let createdFolderID = await store.createFolder(name: "Untitled Folder", in: parentFolderID) else {
                return
            }

            refreshFolders()
            beginInlineRename(for: createdFolderID)
        }
    }

    private func beginInlineRename(for folderID: UUID) {
        renamingFolderID = folderID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            focusedField = folderID
            #if os(macOS)
            try? await Task.sleep(nanoseconds: 20_000_000)
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            #endif
        }
    }

    private var sidebarSelectionExpansionKey: String {
        switch store.selectedSidebarItem {
        case .search:
            return "search"
        case .folder(let folder):
            return "folder:\(folder.id?.uuidString ?? "nil")"
        case .video(let video):
            return "video:\(video.id?.uuidString ?? "nil")"
        case .none:
            return "none"
        }
    }

    private func sidebarSelection(for item: HierarchicalContentItem) -> SidebarSelection {
        switch item.contentType {
        case .folder(let folder):
            return .folder(folder)
        case .video(let video):
            return .video(video)
        }
    }

    private func toggleFolderExpansion(for item: HierarchicalContentItem) {
        guard item.isFolder else { return }

        if expandedFolderIDs.contains(item.id) {
            expandedFolderIDs.remove(item.id)
        } else {
            expandedFolderIDs.insert(item.id)
        }
    }

    private func flattenVisibleLibraryItems(from items: [HierarchicalContentItem], depth: Int) -> [VisibleLibraryItem] {
        var flattened: [VisibleLibraryItem] = []

        for item in items {
            flattened.append(VisibleLibraryItem(item: item, depth: depth))

            if item.isFolder,
               expandedFolderIDs.contains(item.id),
               let children = item.children,
               !children.isEmpty {
                flattened.append(contentsOf: flattenVisibleLibraryItems(from: children, depth: depth + 1))
            }
        }

        return flattened
    }

    private func syncExpandedFoldersForSelection() {
        if case .folder(let selectedFolder) = store.selectedSidebarItem,
           let folderID = selectedFolder.id,
           let path = folderPath(to: folderID, in: libraryRootItems) {
            expandedFolderIDs.formUnion(path)
            return
        }

        if case .video(let selectedVideo) = store.selectedSidebarItem,
           let videoID = selectedVideo.id,
           let path = folderPathToVideo(videoID, in: libraryRootItems) {
            expandedFolderIDs.formUnion(path)
            return
        }

        if let selectedVideoID = store.selectedVideo?.id,
           let path = folderPathToVideo(selectedVideoID, in: libraryRootItems) {
            expandedFolderIDs.formUnion(path)
        }
    }

    private func folderPath(to folderID: UUID, in items: [HierarchicalContentItem]) -> [UUID]? {
        for item in items {
            if let folder = item.folder, folder.id == folderID {
                return [item.id]
            }

            if let children = item.children,
               let childPath = folderPath(to: folderID, in: children) {
                if item.isFolder {
                    return [item.id] + childPath
                }
                return childPath
            }
        }

        return nil
    }

    private func folderPathToVideo(_ videoID: UUID, in items: [HierarchicalContentItem]) -> [UUID]? {
        for item in items {
            if let video = item.video, video.id == videoID {
                return []
            }

            if let children = item.children,
               let childPath = folderPathToVideo(videoID, in: children) {
                if item.isFolder {
                    return [item.id] + childPath
                }
                return childPath
            }
        }

        return nil
    }

    private func handleExternalFileDrop(providers: [NSItemProvider]) -> Bool {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else {
            return false
        }

        let matchingProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !matchingProviders.isEmpty else { return false }

        let lock = NSLock()
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in matchingProviders {
            group.enter()
            let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier
                : UTType.url.identifier

            let _ = provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = droppedURL(from: item) else {
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
                await processingQueueManager.enqueueImport(urls: droppedURLs, library: library, context: context)
                refreshFolders()
            }
        }

        return true
    }

    private func handleInternalRootDrop(providers: [NSItemProvider]) -> Bool {
        let matchingProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.data.identifier)
        }
        guard !matchingProviders.isEmpty else { return false }

        let lock = NSLock()
        var itemIDs = Set<UUID>()
        let group = DispatchGroup()

        for provider in matchingProviders {
            group.enter()
            let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                defer { group.leave() }
                guard let data,
                      let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) else {
                    return
                }

                lock.lock()
                itemIDs.formUnion(transfer.itemIDs)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !itemIDs.isEmpty else { return }
            Task { @MainActor in
                await store.moveItems(itemIDs, to: nil)
            }
        }

        return true
    }

    private func droppedURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let nsURL = item as? NSURL {
            return nsURL as URL
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }

            if let string = String(data: data, encoding: .utf8),
               let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }

        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let nsString = item as? NSString {
            return URL(string: (nsString as String).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
    
}

// MARK: - Folder Row View
private struct FolderRowView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    let folder: Folder
    let showContextMenu: Bool
    @Binding var renamingFolderID: UUID?
    @FocusState.Binding var focusedField: UUID?
    let onCreateSubfolder: (Folder) -> Void
    let onDelete: () -> Void
    
    @State private var isDropTargeted = false
    @State private var editedName: String = ""
    @State private var shouldCommitOnDisappear = false
    
    private var folderDisplayName: String {
        folder.name ?? "Untitled Folder"
    }

    var body: some View {
        Label {
            nameEditorView
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: folder.isSmartFolder ? getSmartFolderIcon(folderDisplayName) : "folder")
                .foregroundColor(folder.isSmartFolder ? .blue : .orange)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if showContextMenu {
                Button("New Folder") {
                    onCreateSubfolder(folder)
                }
                Button("Rename") {
                    guard let folderID = folder.id else { return }
                    renamingFolderID = folderID
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        focusedField = folderID
                    }
                }
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }
        }
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
            guard !folder.isSmartFolder else { return false }
            
            if let provider = providers.first {
                let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                    if let data = data,
                       let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) {
                        Task { @MainActor in
                            await store.moveItems(Set(transfer.itemIDs), to: folder.id)
                        }
                    }
                }
                return true
            }
            return false
        }
        .overlay {
            if isDropTargeted && !folder.isSmartFolder {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    #if os(macOS)
                    .padding(-4)
                    #endif
            }
        }
    }
    
    @ViewBuilder
    private var nameEditorView: some View {
        if renamingFolderID == folder.id {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: folder.id)
                .onAppear {
                    editedName = folderDisplayName
                    shouldCommitOnDisappear = true
                }
                .onSubmit {
                    shouldCommitOnDisappear = false
                    Task { await commitRename() }
                }
                .onKeyPress { keyPress in
                    if keyPress.key == .escape {
                        shouldCommitOnDisappear = false
                        cancelRename()
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: focusedField) { oldValue, newValue in
                    if oldValue == folder.id && newValue != folder.id && shouldCommitOnDisappear {
                        Task { await commitRename() }
                    }
                }
        } else {
            Text(folderDisplayName)
        }
    }
    
    private func commitRename() async {
        shouldCommitOnDisappear = false
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderID = folder.id else {
            await MainActor.run { cancelRename() }
            return
        }

        guard !trimmedName.isEmpty && trimmedName != (folder.name ?? "") else {
            await MainActor.run { cancelRename() }
            return
        }
        
        await store.renameItem(id: folderID, to: trimmedName)
        
        await MainActor.run {
            renamingFolderID = nil
            focusedField = nil
        }
    }

    private func cancelRename() {
        editedName = folderDisplayName
        shouldCommitOnDisappear = false
        renamingFolderID = nil
        focusedField = nil
    }
    
    private func getSmartFolderIcon(_ name: String) -> String {
        switch name {
        case "All Videos": return "video.fill"
        case "Recent": return "clock.fill"
        case "Favorites": return "heart.fill"
        default: return "folder"
        }
    }
}

// MARK: - Sidebar Library Outline Row
private struct SidebarLibraryOutlineRow: View {
    @EnvironmentObject private var store: FolderNavigationStore

    let item: HierarchicalContentItem
    let depth: Int
    let isExpanded: Bool
    let dragItemIDs: [UUID]
    @Binding var renamingFolderID: UUID?
    @FocusState.Binding var focusedField: UUID?
    let onToggleExpansion: () -> Void
    let onCreateSubfolder: (Folder) -> Void
    let onDeleteFolder: (Folder) -> Void

    @State private var isDropTargeted = false
    @State private var editedName = ""
    @State private var shouldCommitOnDisappear = false

    private var hasChildren: Bool {
        (item.children?.isEmpty == false) && item.isFolder
    }

    private var folder: Folder? {
        if case .folder(let folder) = item.contentType {
            return folder
        }
        return nil
    }

    private var video: Video? {
        if case .video(let video) = item.contentType {
            return video
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: CGFloat(depth) * 10)

            if hasChildren {
                Button {
                    onToggleExpansion()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 8, height: 8)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 8, height: 8)
            }

            rowIcon

            rowTitleView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .draggable(ContentTransfer(itemIDs: dragItemIDs))
        .contextMenu {
            if let folder, !folder.isSmartFolder {
                Button("New Folder") {
                    onCreateSubfolder(folder)
                }

                Button("Rename") {
                    guard let folderID = folder.id else { return }
                    renamingFolderID = folderID
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        focusedField = folderID
                    }
                }

                Button("Delete", role: .destructive) {
                    onDeleteFolder(folder)
                }
            }
        }
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
            guard let folder, !folder.isSmartFolder else { return false }
            guard let provider = providers.first else { return false }

            let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                if let data,
                   let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) {
                    Task { @MainActor in
                        await store.moveItems(Set(transfer.itemIDs), to: folder.id)
                    }
                }
            }

            return true
        }
        .overlay {
            if isDropTargeted, folder != nil {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
                    #if os(macOS)
                    .padding(-4)
                    #endif
            }
        }
    }

    @ViewBuilder
    private var rowIcon: some View {
        if folder != nil {
            Image(systemName: "folder.fill")
                .foregroundColor(.orange)
                .frame(width: 18, height: 18)
        } else if video != nil {
            Image(systemName: "video.fill")
                .foregroundColor(.blue)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rowTitleView: some View {
        if let folder {
            folderTitleView(folder: folder)
        } else if let video {
            Text(video.title ?? video.fileName ?? "Untitled")
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func folderTitleView(folder: Folder) -> some View {
        if renamingFolderID == folder.id {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: folder.id)
                .onAppear {
                    editedName = folder.name ?? "Untitled Folder"
                    shouldCommitOnDisappear = true
                }
                .onSubmit {
                    shouldCommitOnDisappear = false
                    Task { await commitRename(for: folder) }
                }
                .onKeyPress { keyPress in
                    if keyPress.key == .escape {
                        shouldCommitOnDisappear = false
                        cancelRename()
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: focusedField) { oldValue, newValue in
                    if oldValue == folder.id && newValue != folder.id && shouldCommitOnDisappear {
                        Task { await commitRename(for: folder) }
                    }
                }
        } else {
            Text(folder.name ?? "Untitled Folder")
                .lineLimit(1)
        }
    }

    private func commitRename(for folder: Folder) async {
        shouldCommitOnDisappear = false

        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folderID = folder.id else {
            await MainActor.run { cancelRename() }
            return
        }

        guard !trimmedName.isEmpty && trimmedName != (folder.name ?? "") else {
            await MainActor.run { cancelRename() }
            return
        }

        await store.renameItem(id: folderID, to: trimmedName)

        await MainActor.run {
            renamingFolderID = nil
            focusedField = nil
        }
    }

    private func cancelRename() {
        shouldCommitOnDisappear = false
        renamingFolderID = nil
        focusedField = nil
    }
}
