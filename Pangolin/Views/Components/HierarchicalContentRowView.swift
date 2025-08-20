//
//  HierarchicalContentRowView.swift
//  Pangolin
//
//  Created by Claude on 19/08/2025.
//

import SwiftUI
import CoreData

/// Row view for hierarchical content items in the native SwiftUI List
struct HierarchicalContentRowView: View {
    let item: HierarchicalContentItem
    @Binding var renamingItemID: UUID?
    @FocusState.Binding var focusedField: UUID?
    @Binding var editedName: String
    @Binding var selectedItems: Set<UUID>
    
    @EnvironmentObject private var store: FolderNavigationStore
    
    // Add state to prevent double-commits on focus loss
    @State private var shouldCommitOnDisappear = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon or Thumbnail
            Group {
                if case .video(let video) = item.contentType {
                    VideoThumbnailView(video: video, size: CGSize(width: 32, height: 18))
                        .frame(width: 32, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                } else {
                    Image(systemName: iconName)
                        .foregroundColor(iconColor)
                        .frame(width: 16, height: 16)
                }
            }
            
            // Name (editable if renaming)
            if renamingItemID == item.id {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: item.id)
                    .onAppear {
                        editedName = item.name
                        shouldCommitOnDisappear = true
                    }
                    .onSubmit {
                        shouldCommitOnDisappear = false // Prevent double commit
                        commitRename()
                    }
                    .onKeyPress(.escape) {
                        shouldCommitOnDisappear = false
                        cancelRename()
                        return .handled
                    }
                    .onChange(of: focusedField) { oldValue, newValue in
                        // Detect when THIS TextField loses focus
                        if oldValue == item.id && newValue != item.id && shouldCommitOnDisappear {
                            commitRename()
                        }
                    }
            } else {
                Text(item.name)
                    .lineLimit(1)
                    .font(.system(.body, design: .default, weight: .regular))
            }
            
            Spacer()
            
            // Additional info for videos
            if case .video(let video) = item.contentType {
                Text(video.formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .draggable(dragPayload)
        .dropDestination(for: ContentTransfer.self) { items, location in
            handleDrop(items)
        } isTargeted: { isTargeted in
            // Could add visual feedback for drop targeting
        }
    }
    
    // MARK: - Computed Properties
    
    private var iconName: String {
        switch item.contentType {
        case .folder:
            return item.hasChildren ? "folder" : "folder"
        case .video:
            return "play.rectangle"
        }
    }
    
    private var iconColor: Color {
        switch item.contentType {
        case .folder:
            return .accentColor
        case .video:
            return .primary
        }
    }
    
    private var dragPayload: ContentTransfer {
        // If the dragged item is part of a larger selection, drag all selected items.
        // Otherwise, just drag the single item.
        if selectedItems.contains(item.id) {
            return ContentTransfer(itemIDs: Array(selectedItems))
        } else {
            return ContentTransfer(itemIDs: [item.id])
        }
    }
    
    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename") {
            startRenaming()
        }
        
        if case .folder = item.contentType {
            Divider()
            Button("Create Subfolder") {
                // TODO: Implement subfolder creation
            }
        }
        
        Divider()
        Button("Delete", role: .destructive) {
            // TODO: Implement deletion
        }
    }
    
    // MARK: - Actions
    
    private func startRenaming() {
        editedName = item.name
        renamingItemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
            focusedField = item.id
        }
    }
    
    private func commitRename() {
        shouldCommitOnDisappear = false // Prevent further commits
        
        guard let renamingID = renamingItemID,
              renamingID == item.id else {
            cancelRename()
            return
        }
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != item.name else {
            cancelRename()
            return
        }
        
        Task {
            await store.renameItem(id: item.id, to: trimmedName)
            await MainActor.run {
                renamingItemID = nil
                focusedField = nil
            }
        }
    }
    
    private func cancelRename() {
        shouldCommitOnDisappear = false
        renamingItemID = nil
        focusedField = nil
        editedName = ""
    }
    
    private func handleDrop(_ items: [ContentTransfer]) -> Bool {
        guard case .folder(let folder) = item.contentType else { return false }
        
        // Extract all item IDs from transfers
        let itemIDs = Set(items.flatMap { $0.itemIDs })
        
        // Don't allow dropping an item onto itself
        guard !itemIDs.contains(item.id) else { return false }
        
        Task {
            await store.moveItems(itemIDs, to: folder.id)
        }
        
        return true
    }
}