import SwiftUI

struct FolderOutlinePane: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @StateObject private var videoFileManager = VideoFileManager.shared

    private struct VisibleOutlineItem: Identifiable {
        let item: HierarchicalContentItem
        let depth: Int

        var id: UUID { item.id }
    }

    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var selectedItemID: UUID?

    @State private var pendingRenameItem: HierarchicalContentItem?
    @State private var renameText = ""

    @State private var showingDeletionConfirmation = false
    @State private var itemsToDelete: [DeletionItem] = []

    private var visibleItems: [VisibleOutlineItem] {
        flattenVisibleItems(from: store.hierarchicalContent, depth: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            FolderNavigationHeader(
                onCreateSubfolder: {
                    createSubfolder(in: selectedFolderForCreateID ?? store.currentFolderID)
                },
                onDeleteSelected: {
                    guard let item = selectedItem else { return }
                    promptDelete(item)
                },
                hasSelectedItems: selectedItem != nil
            )

            Group {
                if store.hierarchicalContent.isEmpty {
                    ContentUnavailableView(
                        "No items",
                        systemImage: "folder",
                        description: Text("This folder is empty.")
                    )
                } else {
                    List {
                        ForEach(visibleItems) { visibleItem in
                            outlineRow(for: visibleItem.item, depth: visibleItem.depth)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncSelectionAndExpansionFromStore()
        }
        .onChange(of: store.selectedVideo?.id) { _, _ in
            syncSelectionAndExpansionFromStore()
        }
        .onChange(of: store.hierarchicalContent) { _, _ in
            reconcileSelection()
            syncSelectionAndExpansionFromStore()
        }
        .alert("Rename Item", isPresented: isRenameAlertPresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                clearRenameState()
            }
            Button("Save") {
                commitRename()
            }
        } message: {
            Text("Enter a new name.")
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
    }

    private func outlineRow(for item: HierarchicalContentItem, depth: Int) -> some View {
        Button {
            handleRowTap(item)
        } label: {
            HStack(spacing: 8) {
                Color.clear
                    .frame(width: CGFloat(depth) * 14)

                if item.isFolder {
                    Image(systemName: expandedFolderIDs.contains(item.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }

                FolderOutlineRow(
                    item: item,
                    isActiveVideo: isSelectedVideo(item)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(for: item))
        .contextMenu {
            contextMenu(for: item)
        }
    }

    private func flattenVisibleItems(from items: [HierarchicalContentItem], depth: Int) -> [VisibleOutlineItem] {
        var flattened: [VisibleOutlineItem] = []

        for item in items {
            flattened.append(VisibleOutlineItem(item: item, depth: depth))

            if item.isFolder,
               expandedFolderIDs.contains(item.id),
               let children = item.children,
               !children.isEmpty {
                flattened.append(contentsOf: flattenVisibleItems(from: children, depth: depth + 1))
            }
        }

        return flattened
    }

    @ViewBuilder
    private func contextMenu(for item: HierarchicalContentItem) -> some View {
        switch item.contentType {
        case .folder(let folder):
            Button("New Subfolder") {
                createSubfolder(in: folder.id)
            }
            Button("Rename") {
                startRename(item)
            }
            Button("Delete", role: .destructive) {
                promptDelete(item)
            }
        case .video(let video):
            Button("Retry Transfer") {
                Task {
                    await videoFileManager.retryTransfer(for: video)
                }
            }
            Button("Retry Offload") {
                Task {
                    await videoFileManager.retryOffload(for: video)
                }
            }
            Divider()
            Button("Rename") {
                startRename(item)
            }
            Button("Delete", role: .destructive) {
                promptDelete(item)
            }
        }
    }

    private var selectedItem: HierarchicalContentItem? {
        guard let selectedItemID else { return nil }
        return findItem(withID: selectedItemID, in: store.hierarchicalContent)
    }

    private var selectedFolderForCreateID: UUID? {
        selectedItem?.folder?.id
    }

    private var isRenameAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingRenameItem != nil },
            set: { isPresented in
                if !isPresented {
                    clearRenameState()
                }
            }
        )
    }
    
    private var deletionAlertContent: DeletionAlertContent {
        itemsToDelete.deletionAlertContent
    }

    private func rowBackground(for item: HierarchicalContentItem) -> Color {
        if isSelectedVideo(item) {
            return Color.accentColor.opacity(0.15)
        }

        if selectedItemID == item.id {
            return Color.secondary.opacity(0.12)
        }

        return .clear
    }

    private func isSelectedVideo(_ item: HierarchicalContentItem) -> Bool {
        guard let video = item.video,
              let selectedVideo = store.selectedVideo else {
            return false
        }

        return video.objectID == selectedVideo.objectID
    }

    private func handleRowTap(_ item: HierarchicalContentItem) {
        selectedItemID = item.id

        if item.isFolder {
            if expandedFolderIDs.contains(item.id) {
                expandedFolderIDs.remove(item.id)
            } else {
                expandedFolderIDs.insert(item.id)
            }
            return
        }

        if let selectedVideo = item.video {
            store.selectVideo(selectedVideo)
        }
    }

    private func reconcileSelection() {
        guard let selectedItemID else { return }
        if findItem(withID: selectedItemID, in: store.hierarchicalContent) == nil {
            self.selectedItemID = nil
        }
    }

    private func syncSelectionAndExpansionFromStore() {
        guard let selectedVideo = store.selectedVideo,
              let selectedVideoID = selectedVideo.id,
              findItem(withID: selectedVideoID, in: store.hierarchicalContent) != nil else {
            return
        }

        selectedItemID = selectedVideoID

        if let folderPath = folderPathToVideo(selectedVideoID, in: store.hierarchicalContent) {
            expandedFolderIDs.formUnion(folderPath)
        }
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

    private func createSubfolder(in parentFolderID: UUID?) {
        Task {
            await store.createFolder(name: "New Folder", in: parentFolderID)
        }
    }

    private func startRename(_ item: HierarchicalContentItem) {
        pendingRenameItem = item
        renameText = item.name
    }

    private func clearRenameState() {
        pendingRenameItem = nil
        renameText = ""
    }

    private func commitRename() {
        guard let pendingRenameItem else {
            clearRenameState()
            return
        }

        let trimmedName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != pendingRenameItem.name else {
            clearRenameState()
            return
        }

        let id = pendingRenameItem.id
        clearRenameState()

        Task {
            await store.renameItem(id: id, to: trimmedName)
        }
    }

    private func promptDelete(_ item: HierarchicalContentItem) {
        let deletionItem: DeletionItem

        switch item.contentType {
        case .folder(let folder):
            deletionItem = DeletionItem(folder: folder)
        case .video(let video):
            deletionItem = DeletionItem(video: video)
        }

        itemsToDelete = [deletionItem]
        showingDeletionConfirmation = true
    }

    private func confirmDeletion() async {
        let itemIDs = Set(itemsToDelete.map(\.id))
        let success = await store.deleteItems(itemIDs)

        await MainActor.run {
            if success, let selectedItemID, itemIDs.contains(selectedItemID) {
                self.selectedItemID = nil
            }
            cancelDeletion()
        }
    }

    private func cancelDeletion() {
        itemsToDelete.removeAll()
        showingDeletionConfirmation = false
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
}
