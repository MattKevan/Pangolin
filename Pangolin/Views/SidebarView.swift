//
//  SidebarView.swift
//  Pangolin
//
//  Sidebar with fixed system items and editable library tree.
//

import SwiftUI
import CoreData

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore

    @State private var selectedTreeID: UUID?
    @State private var renamingItemID: UUID?
    @State private var editedName = ""
    @FocusState private var focusedField: UUID?

    @State private var itemToDelete: DeletionItem?

    var body: some View {
        List(selection: $selectedTreeID) {
            Section {
                searchRow

                ForEach(store.systemSidebarFolders, id: \.objectID) { folder in
                    systemFolderRow(folder)
                }
            }

            Section("Library") {
                OutlineGroup(store.sidebarTreeContent, children: \.children) { item in
                    libraryRow(for: item)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Library")
        .sheet(item: $itemToDelete) { deletionItem in
            DeletionConfirmationView(
                items: [deletionItem],
                onConfirm: {
                    Task {
                        _ = await store.deleteItems([deletionItem.id])
                        itemToDelete = nil
                    }
                },
                onCancel: {
                    itemToDelete = nil
                }
            )
        }
        .onChange(of: store.sidebarTreeContent) { _, newTree in
            guard let selectedTreeID else { return }
            if findItem(with: selectedTreeID, in: newTree) == nil {
                self.selectedTreeID = nil
            }
        }
        .onChange(of: selectedTreeID) { _, newID in
            guard let newID else { return }
            let selected = findItem(with: newID, in: store.sidebarTreeContent)
            store.handleSidebarTreeSelection(selected)
        }
        .onChange(of: store.selectedSidebarItem) { _, newSelection in
            if case .folder(let folder) = newSelection, !folder.isSmartFolder {
                selectedTreeID = folder.id
            } else {
                selectedTreeID = nil
            }
        }
        .onDrop(of: [.data], isTargeted: nil) { providers in
            handleRootDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerRename"))) { _ in
            if let selectedID = selectedTreeID,
               let item = findItem(with: selectedID, in: store.sidebarTreeContent) {
                startRename(item)
            }
        }
    }

    private var searchRow: some View {
        Button {
            cancelRename()
            selectedTreeID = nil
            store.activateSearch()
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func systemFolderRow(_ folder: Folder) -> some View {
        Button {
            cancelRename()
            selectedTreeID = nil
            store.selectSystemFolder(folder)
        } label: {
            Label(folder.name ?? "Folder", systemImage: smartFolderIcon(for: folder.name ?? ""))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func libraryRow(for item: HierarchicalContentItem) -> some View {
        SidebarTreeRow(
            item: item,
            renamingItemID: $renamingItemID,
            editedName: $editedName,
            focusedField: $focusedField,
            onRename: { startRename(item) },
            onDelete: { startDelete(item) },
            onCreateFolder: { createSubfolderIfNeeded(item) },
            onCommitRename: { commitRename(item) },
            onCancelRename: cancelRename,
            onDrop: { transfer in
                handleDrop(transfer, destination: item)
            }
        )
        .tag(item.id)
        .draggable(ContentTransfer(itemIDs: [item.id]))
    }

    private func createSubfolderIfNeeded(_ item: HierarchicalContentItem) {
        guard case .folder(let folder) = item.contentType else { return }
        Task {
            await store.createFolder(name: "New Folder", in: folder.id)
        }
    }

    private func startRename(_ item: HierarchicalContentItem) {
        renamingItemID = item.id
        editedName = item.name
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            focusedField = item.id
        }
    }

    private func commitRename(_ item: HierarchicalContentItem) {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else {
            cancelRename()
            return
        }
        Task {
            await store.renameItem(id: item.id, to: trimmed)
            cancelRename()
        }
    }

    private func cancelRename() {
        renamingItemID = nil
        editedName = ""
        focusedField = nil
    }

    private func startDelete(_ item: HierarchicalContentItem) {
        switch item.contentType {
        case .folder(let folder):
            itemToDelete = DeletionItem(folder: folder)
        case .video(let video):
            itemToDelete = DeletionItem(video: video)
        }
    }

    private func handleDrop(_ transfer: ContentTransfer, destination: HierarchicalContentItem) -> Bool {
        guard case .folder(let folder) = destination.contentType,
              !folder.isSmartFolder else {
            return false
        }

        Task {
            await store.moveItems(Set(transfer.itemIDs), to: folder.id)
        }
        return true
    }

    private func handleRootDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(for: .data) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) else { return }
            Task { @MainActor in
                await store.moveItems(Set(transfer.itemIDs), to: nil)
            }
        }
        return true
    }

    private func findItem(with id: UUID, in items: [HierarchicalContentItem]) -> HierarchicalContentItem? {
        for item in items {
            if item.id == id {
                return item
            }
            if let children = item.children,
               let found = findItem(with: id, in: children) {
                return found
            }
        }
        return nil
    }

    private func smartFolderIcon(for name: String) -> String {
        switch name {
        case "All Videos": return "video.fill"
        case "Recent": return "clock.fill"
        case "Favorites": return "heart.fill"
        default: return "folder"
        }
    }
}

private struct SidebarTreeRow: View {
    let item: HierarchicalContentItem

    @Binding var renamingItemID: UUID?
    @Binding var editedName: String
    @FocusState.Binding var focusedField: UUID?

    let onRename: () -> Void
    let onDelete: () -> Void
    let onCreateFolder: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDrop: @MainActor (ContentTransfer) -> Bool

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            nameView
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if item.isFolder {
                Button("New Subfolder", action: onCreateFolder)
            }
            Button("Rename", action: onRename)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
            guard item.isFolder else { return false }
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(for: .data) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data) else { return }
                Task { @MainActor in
                    _ = onDrop(transfer)
                }
            }
            return true
        }
        .overlay {
            if isDropTargeted && item.isFolder {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    #if os(macOS)
                    .padding(-4)
                    #endif
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if case .folder(let folder) = item.contentType {
            Image(systemName: folder.isSmartFolder ? smartFolderIcon(for: folder.name ?? "") : "folder")
                .foregroundStyle(.accent)
        } else {
            Image(systemName: "play.rectangle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var nameView: some View {
        if renamingItemID == item.id {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: item.id)
                .onSubmit(onCommitRename)
                .onKeyPress(.escape) {
                    onCancelRename()
                    return .handled
                }
                .onChange(of: focusedField) { oldValue, newValue in
                    if oldValue == item.id && newValue != item.id {
                        onCommitRename()
                    }
                }
        } else {
            Text(item.name)
                .lineLimit(1)
        }
    }

    private func smartFolderIcon(for name: String) -> String {
        switch name {
        case "All Videos": return "video.fill"
        case "Recent": return "clock.fill"
        case "Favorites": return "heart.fill"
        default: return "folder"
        }
    }
}
