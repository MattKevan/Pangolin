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

    enum ViewMode {
        case grid
        case list
    }

    private var dragPayload: ContentTransfer {
        // If the dragged item is part of a larger selection, drag all selected items.
        // Otherwise, just drag the single item.
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
            Button("Delete", role: .destructive) { /* TODO: Implement deletion */ }
        }
        .draggable(dragPayload)
        .onDrop(of: [.data], isTargeted: $isDropTargeted) { providers in
            guard case .folder(let folder) = content else { return false }
            
            if let provider = providers.first {
                let _ = provider.loadDataRepresentation(for: .data) { data, _ in
                    if let data = data,
                       let transfer = try? JSONDecoder().decode(ContentTransfer.self, from: data),
                       !transfer.itemIDs.contains(folder.id) {
                        Task { @MainActor in
                            await store.moveItems(Set(transfer.itemIDs), to: folder.id)
                        }
                    }
                }
                return true
            }
            return false
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
    
    /// A view that conditionally shows a `Text` label or a `TextField` for renaming.
    @ViewBuilder
    private var nameEditorView: some View {
        if renamingItemID == content.id {
            TextField("Name", text: $editedName)
                .focused($focusedField, equals: content.id)
                .onSubmit {
                    commitRename()
                }
                .onKeyPress { keyPress in
                    if keyPress.key == .escape {
                        cancelRename()
                        return .handled
                    }
                    return .ignored
                }
                .onAppear {
                    editedName = content.name
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

    /// Initiates the renaming process for this item.
    private func startRenaming() {
        editedName = content.name
        renamingItemID = content.id
        // Set focus after a brief delay to ensure TextField is rendered
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            focusedField = content.id
        }
    }
    
    /// Commits the rename operation and updates the store.
    private func commitRename() {
        guard let itemID = renamingItemID, itemID == content.id else { return }
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != content.name else {
            // Cancel rename if name is empty or unchanged
            cancelRename()
            return
        }
        
        // Perform rename operation on background queue to avoid publishing changes during view update
        Task {
            await store.renameItem(id: itemID, to: trimmedName)
            await MainActor.run {
                renamingItemID = nil
                focusedField = nil
            }
        }
    }
    
    /// Cancels the rename operation without saving.
    private func cancelRename() {
        editedName = content.name // Reset to original name
        renamingItemID = nil
        focusedField = nil
    }


}
