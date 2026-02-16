//
//  ContentRowView.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI

struct ContentRowView: View {
    let content: ContentType
    let isSelected: Bool
    let showCheckbox: Bool
    let viewMode: ViewMode
    @Binding var selectedItems: Set<UUID>
    @Binding var renamingItemID: UUID?
    @FocusState.Binding var focusedField: UUID?
    @Binding var editedName: String

    @EnvironmentObject private var store: FolderNavigationStore
    @State private var isDropTargeted = false
    @State private var shouldCommitOnDisappear = false
    @State private var showingDeletionConfirmation = false
    @State private var itemsToDelete: [DeletionItem] = []

    enum ViewMode {
        case grid
        case list
    }

    private var dragPayload: ContentTransfer {
        if selectedItems.contains(content.id) {
            return ContentTransfer(itemIDs: Array(selectedItems))
        } else {
            return ContentTransfer(itemIDs: [content.id])
        }
    }

    var body: some View {
        Group {
            switch viewMode {
            case .grid:
                gridContent
            case .list:
                listContent
            }
        }
        .contextMenu {
            Button("Rename") { startRenaming() }
            Button("Delete", role: .destructive) { promptDeletion() }
        }
        .draggable(dragPayload)
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
            guard case .folder(let folder) = content,
                  let folderID = folder.id else { return false }
            
            if let provider = providers.first {
                let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                    if let data = data,
                       let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data),
                       !transfer.itemIDs.contains(folderID) {
                        Task { @MainActor in
                            await store.moveItems(Set(transfer.itemIDs), to: folderID)
                        }
                    }
                }
                return true
            }
            return false
        }
        .alert(deletionAlertContent.title, isPresented: $showingDeletionConfirmation) {
            Button("Cancel", role: .cancel) { cancelDeletion() }
            Button("Delete", role: .destructive) {
                Task { await confirmDeletion() }
            }
        } message: {
            Text(deletionAlertContent.message)
        }
    }

    // MARK: - View Builders
    
    @ViewBuilder
    private var gridContent: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(content.isFolder ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                    .frame(height: 120)
                
                contentIcon
                    .font(.system(size: 40))
                    .foregroundColor(content.isFolder ? .blue : .primary)
                
                if showCheckbox {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isSelected ? .blue : .gray)
                                .background(Color.white)
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            
            VStack(alignment: .center, spacing: 4) {
                nameEditorView
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                if case .folder(let folder) = content {
                    Text("\(folder.itemCount) items")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if case .video(let video) = content {
                    Text(video.formattedDuration)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(isSelected && !showCheckbox ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private var listContent: some View {
        HStack {
            if showCheckbox {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
            }
            
            contentIcon
                .font(.system(size: 20))
                .foregroundColor(content.isFolder ? .blue : .primary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                nameEditorView
                    .lineLimit(1)
                
                HStack {
                    if case .folder(let folder) = content {
                        Text("\(folder.itemCount) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if case .video(let video) = content {
                        Text(video.formattedDuration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(ByteCountFormatter().string(fromByteCount: video.fileSize))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected && !showCheckbox ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
        .overlay(
             RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
    
    @ViewBuilder
    private var nameEditorView: some View {
        if renamingItemID == content.id {
            TextField("Name", text: $editedName)
                .focused($focusedField, equals: content.id)
                .onAppear {
                    editedName = content.name
                    shouldCommitOnDisappear = true
                }
                .onSubmit {
                    shouldCommitOnDisappear = false
                    // ✅ Call async function from a Task
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
                    if oldValue == content.id && newValue != content.id && shouldCommitOnDisappear {
                        // ✅ Call async function from a Task
                        Task { await commitRename() }
                    }
                }
        } else {
            Text(content.name)
        }
    }
    
    @ViewBuilder
    private var contentIcon: some View {
        switch content {
        case .folder:
            Image(systemName: "folder.fill")
        case .video(let video):
            if let thumbnailURL = video.thumbnailURL,
               FileManager.default.fileExists(atPath: thumbnailURL.path) {
                AsyncImage(url: thumbnailURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "video.fill")
                        .foregroundColor(.gray)
                }
                .frame(width: viewMode == .grid ? 80 : 20, height: viewMode == .grid ? 45 : 15)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "video.fill")
            }
        }
    }

    // MARK: - Renaming Logic

    private var deletionAlertContent: DeletionAlertContent {
        itemsToDelete.deletionAlertContent
    }

    private func startRenaming() {
        editedName = content.name
        renamingItemID = content.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            focusedField = content.id
        }
    }
    
    // ✅ Make the function async
    private func commitRename() async {
        shouldCommitOnDisappear = false
        
        guard let itemID = renamingItemID, itemID == content.id else {
            await MainActor.run { cancelRename() }
            return
        }
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != content.name else {
            await MainActor.run { cancelRename() }
            return
        }
        
        // ✅ Await the store operation before updating local state
        await store.renameItem(id: itemID, to: trimmedName)
        
        // ✅ Now update local state after the save is complete
        await MainActor.run {
            renamingItemID = nil
            focusedField = nil
        }
    }
    
    private func cancelRename() {
        editedName = content.name
        shouldCommitOnDisappear = false
        renamingItemID = nil
        focusedField = nil
    }

    private func promptDeletion() {
        switch content {
        case .folder(let folder):
            itemsToDelete = [DeletionItem(folder: folder)]
        case .video(let video):
            itemsToDelete = [DeletionItem(video: video)]
        }
        showingDeletionConfirmation = !itemsToDelete.isEmpty
    }

    private func cancelDeletion() {
        itemsToDelete.removeAll()
        showingDeletionConfirmation = false
    }

    private func confirmDeletion() async {
        let itemIDs = Set(itemsToDelete.map(\.id))
        let success = await store.deleteItems(itemIDs)

        await MainActor.run {
            if success {
                selectedItems.subtract(itemIDs)
                if renamingItemID.map(itemIDs.contains) == true {
                    cancelRename()
                }
            }
            cancelDeletion()
        }
    }
}
