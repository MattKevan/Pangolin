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
    @State private var itemToDelete: DeletionItem?
    @State private var sidebarSelections = Set<SidebarSelection>()
    @State private var isSyncingSidebarSelections = false
    
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
            sidebarShortcutsSection
            libraryTreeSection
        }
        #if os(macOS)
        .listStyle(SidebarListStyle())
        #else
        .listStyle(InsetGroupedListStyle())
        #endif
        .contextMenu {
            Button("New folder") {
                createTopLevelFolder()
            }
            .disabled(libraryManager.currentLibrary == nil)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createFolderFromCurrentSelection()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Add Folder")
                .disabled(libraryManager.currentLibrary == nil)
            }
        }
        .alert(
            sidebarDeletionAlertTitle,
            isPresented: Binding(
                get: { itemToDelete != nil },
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
            if itemToDelete?.isFolder == true {
                Button("Keep Videos in Library") {
                    guard let deletionItem = itemToDelete else {
                        cancelDeletion()
                        return
                    }
                    Task {
                        await confirmFolderDeletion(deletionItem, mode: .keepVideosInLibrary)
                    }
                }
                Button("Delete Folder and Videos", role: .destructive) {
                    guard let deletionItem = itemToDelete else {
                        cancelDeletion()
                        return
                    }
                    Task {
                        await confirmFolderDeletion(deletionItem, mode: .deleteAllVideos)
                    }
                }
            } else {
                Button("Remove From Folder") {
                    guard let deletionItem = itemToDelete else {
                        cancelDeletion()
                        return
                    }
                    Task {
                        await removeVideoFromFolder(deletionItem)
                    }
                }
                Button("Delete Video", role: .destructive) {
                    guard let deletionItem = itemToDelete else {
                        cancelDeletion()
                        return
                    }
                    Task {
                        await deleteVideoEntirely(deletionItem)
                    }
                }
            }
        } message: {
            Text(sidebarDeletionAlertMessage)
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
            } else if keyPress.key == .return,
                      case .video(let selectedVideo) = store.selectedSidebarItem {
                renamingFolderID = selectedVideo.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    focusedField = selectedVideo.id
                }
                return .handled
            } else if (keyPress.key == .delete || keyPress.key == .deleteForward),
                      case .folder(let selected) = store.selectedSidebarItem,
                      !selected.isSmartFolder { // Only allow deletion for user folders
                deleteFolder(selected)
                return .handled
            } else if (keyPress.key == .delete || keyPress.key == .deleteForward),
                      case .video(let selectedVideo) = store.selectedSidebarItem {
                deleteVideo(selectedVideo)
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

    @ViewBuilder
    private var sidebarShortcutsSection: some View {
        Section("Pangolin") {
            sidebarShortcutRow(
                title: "Search",
                systemImage: "magnifyingglass",
                destination: .search
            )

            ForEach(SmartCollectionKind.allCases) { smartCollection in
                sidebarShortcutRow(
                    title: smartCollection.title,
                    systemImage: smartCollection.sidebarIcon,
                    destination: .smartCollection(smartCollection)
                )
            }
        }
    }

    @ViewBuilder
    private var libraryTreeSection: some View {
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
                    onDeleteFolder: deleteFolder,
                    onDeleteVideo: deleteVideo
                )
                .contentShape(Rectangle())
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                .tag(sidebarSelection(for: visibleItem.item))
            }
        }
    }

    @ViewBuilder
    private func sidebarShortcutRow(
        title: String,
        systemImage: String,
        destination: SidebarSelection
    ) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 8))
        .tag(destination)
    }
    
    private func refreshFolders() {
        userFolders = store.userFolders()
        syncExpandedFoldersForSelection()
    }

    private func syncStoreSelection(oldSelection: Set<SidebarSelection>, newSelection: Set<SidebarSelection>) {
        guard !isSyncingSidebarSelections else { return }

        guard oldSelection != newSelection else { return }

        let newTreeSelection = treeSelections(from: newSelection)

        let nextSelection: SidebarSelection?
        if newSelection.isEmpty {
            // Clearing selection should not clear a virtual route that owns the current destination.
            if case .search = store.selectedSidebarItem {
                return
            }
            if case .smartCollection = store.selectedSidebarItem {
                return
            }
            nextSelection = nil
        } else if let currentSelection = store.selectedSidebarItem, newSelection.contains(currentSelection) {
            nextSelection = currentSelection
        } else if let newlyAdded = newSelection.subtracting(oldSelection).first {
            nextSelection = newlyAdded
        } else if let treeSelection = newTreeSelection.first {
            nextSelection = treeSelection
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
        let nextSelections: Set<SidebarSelection>
        switch selection {
        case .search, .smartCollection:
            nextSelections = selection.map { Set([$0]) } ?? []
        case .folder, .video:
            nextSelections = selection.map { Set([$0]) } ?? []
        case .none:
            nextSelections = []
        }
        guard sidebarSelections != nextSelections else { return }

        isSyncingSidebarSelections = true
        sidebarSelections = nextSelections
        isSyncingSidebarSelections = false
    }

    private func selectionKeysEqual(lhs: SidebarSelection?, rhs: SidebarSelection?) -> Bool {
        lhs?.stableKey == rhs?.stableKey
    }

    private func treeSelections(from selections: Set<SidebarSelection>) -> Set<SidebarSelection> {
        Set(selections.filter(isTreeSelection))
    }

    private func isTreeSelection(_ selection: SidebarSelection) -> Bool {
        switch selection {
        case .folder, .video:
            return true
        case .search, .smartCollection:
            return false
        }
    }

    private func dragItemIDs(for itemID: UUID) -> [UUID] {
        let selectedMovableIDs = Set(sidebarSelections.compactMap { selection -> UUID? in
            switch selection {
            case .search:
                return nil
            case .smartCollection:
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
    
    private var sidebarDeletionAlertTitle: String {
        guard let itemToDelete else { return "Delete Item?" }
        let noun = itemToDelete.isFolder ? "Folder" : "Video"
        return "Delete \(noun) \"\(itemToDelete.name)\"?"
    }

    private var sidebarDeletionAlertMessage: String {
        if itemToDelete?.isFolder == true {
            return "Choose whether to keep videos from this folder (and any subfolders) in the library as unfiled videos, or delete the videos and their files from disk. This action cannot be undone."
        }
        return "Choose whether to remove this video from its folder (it will remain in the library as an unfiled video) or delete it entirely from the library and disk. This action cannot be undone."
    }
    
    private func deleteFolder(_ folder: Folder) {
        print("🗑️ SIDEBAR: deleteFolder called for: \(folder.name ?? "nil") (ID: \(folder.id ?? UUID()))")
        isDeletingFolder = true
        // Create a snapshot that won't be affected by Core Data changes
        let deletionItem = DeletionItem(folder: folder)

        // Skip the delete-options dialog when the folder tree contains no videos.
        if folder.totalVideoCount == 0 {
            Task {
                await confirmFolderDeletion(deletionItem, mode: .keepVideosInLibrary)
            }
            return
        }

        print("🗑️ SIDEBAR: Created deletion item: \(deletionItem.name)")
        itemToDelete = deletionItem
        print("🗑️ SIDEBAR: Set itemToDelete item, this should trigger alert")
    }
    
    private func deleteVideo(_ video: Video) {
        print("🗑️ SIDEBAR: deleteVideo called for: \(video.title ?? video.fileName ?? "nil") (ID: \(video.id ?? UUID()))")
        isDeletingFolder = true
        itemToDelete = DeletionItem(video: video)
    }

    private func confirmFolderDeletion(_ deletionItem: DeletionItem, mode: FolderDeletionMode) async {
        let success = await store.deleteItems([deletionItem.id], folderDeletionMode: mode)
        
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

    private func removeVideoFromFolder(_ deletionItem: DeletionItem) async {
        await store.moveItems([deletionItem.id], to: nil)

        await MainActor.run {
            if case .video(let selectedVideo) = store.selectedSidebarItem,
               selectedVideo.id == deletionItem.id {
                store.selectAllVideos()
            }
            cancelDeletion()
        }
    }

    private func deleteVideoEntirely(_ deletionItem: DeletionItem) async {
        let success = await store.deleteItems([deletionItem.id])

        await MainActor.run {
            if success,
               case .video(let selectedVideo) = store.selectedSidebarItem,
               selectedVideo.id == deletionItem.id {
                store.selectAllVideos()
            }
            cancelDeletion()
        }
    }
    
    private func cancelDeletion() {
        itemToDelete = nil
        isDeletingFolder = false
        // Refresh folders after deletion process is complete
        refreshFolders()
    }
    
    private func triggerRenameFromMenu() {
        switch store.selectedSidebarItem {
        case .folder(let selected) where !selected.isSmartFolder:
            renamingFolderID = selected.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                focusedField = selected.id
            }
        case .video(let selectedVideo):
            renamingFolderID = selectedVideo.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                focusedField = selectedVideo.id
            }
        default:
            break
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
        case .search, .smartCollection, .none:
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
        store.selectedSidebarItem?.stableKey ?? "none"
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

        final class ItemIDStore {
            private let lock = NSLock()
            private var value = Set<UUID>()

            func formUnion<S: Sequence>(_ ids: S) where S.Element == UUID {
                lock.lock()
                value.formUnion(ids)
                lock.unlock()
            }

            func snapshot() -> Set<UUID> {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let itemIDStore = ItemIDStore()
        let group = DispatchGroup()

        for provider in matchingProviders {
            group.enter()
            let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                defer { group.leave() }
                guard let data,
                      let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) else {
                    return
                }

                itemIDStore.formUnion(transfer.itemIDs)
            }
        }

        group.notify(queue: .main) {
            let itemIDs = itemIDStore.snapshot()
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
        folder.name ?? "Untitled folder"
    }

    var body: some View {
        Label {
            nameEditorView
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "folder")
        }
        .contentShape(Rectangle())
        .contextMenu {
            if showContextMenu {
                Button("New folder") {
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
    let onDeleteVideo: (Video) -> Void

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
                Button("New folder") {
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
            } else if let video {
                Button("Rename") {
                    guard let videoID = video.id else { return }
                    renamingFolderID = videoID
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        focusedField = videoID
                    }
                }

                Button("Delete", role: .destructive) {
                    onDeleteVideo(video)
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
            Image(systemName: "folder")
                .frame(width: 18, height: 18)
        } else if video != nil {
            Image(systemName: "video")
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var rowTitleView: some View {
        if let folder {
            folderTitleView(folder: folder)
        } else if let video {
            videoTitleView(video: video)
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

    @ViewBuilder
    private func videoTitleView(video: Video) -> some View {
        if renamingFolderID == video.id {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: video.id)
                .onAppear {
                    editedName = video.title ?? video.fileName ?? "Untitled"
                    shouldCommitOnDisappear = true
                }
                .onSubmit {
                    shouldCommitOnDisappear = false
                    Task { await commitRename(for: video) }
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
                    if oldValue == video.id && newValue != video.id && shouldCommitOnDisappear {
                        Task { await commitRename(for: video) }
                    }
                }
        } else {
            Text(video.title ?? video.fileName ?? "Untitled")
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

    private func commitRename(for video: Video) async {
        shouldCommitOnDisappear = false

        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let videoID = video.id else {
            await MainActor.run { cancelRename() }
            return
        }

        let currentName = video.title ?? video.fileName ?? ""
        guard !trimmedName.isEmpty && trimmedName != currentName else {
            await MainActor.run { cancelRename() }
            return
        }

        await store.renameItem(id: videoID, to: trimmedName)

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
