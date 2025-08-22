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
    let onDelete: ((UUID) -> Void)?
    
    @EnvironmentObject private var store: FolderNavigationStore
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
    // Add state to prevent double-commits on focus loss
    @State private var shouldCommitOnDisappear = false
    @State private var showingDeletionConfirmation = false
    
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
                        shouldCommitOnDisappear = false
                        // Use a Task to call the new async function
                        Task { await commitRename() }
                    }
                    .onKeyPress(.escape) {
                        shouldCommitOnDisappear = false
                        cancelRename()
                        return .handled
                    }
                    .onChange(of: focusedField) { oldValue, newValue in
                        if oldValue == item.id && newValue != item.id && shouldCommitOnDisappear {
                            // Use a Task here as well
                            Task { await commitRename() }
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
        
        // Processing options for videos
        if case .video(let video) = item.contentType {
            Divider()
            
            Menu("Add to Processing Queue") {
                Button("Transcribe") {
                    processingQueueManager.addTask(for: video, type: .transcribe)
                }
                .disabled(video.transcriptText != nil && !video.transcriptText!.isEmpty)
                
                Button("Translate") {
                    processingQueueManager.addTask(for: video, type: .translate)
                }
                .disabled(video.translatedText != nil && !video.translatedText!.isEmpty)
                
                Button("Summarize") {
                    processingQueueManager.addTask(for: video, type: .summarize)
                }
                .disabled(video.transcriptSummary != nil && !video.transcriptSummary!.isEmpty)
                
                Divider()
                
                Button("Full Workflow (Transcribe → Translate → Summarize)") {
                    processingQueueManager.addFullProcessingWorkflow(for: [video])
                }
                
                Button("Transcribe & Summarize") {
                    processingQueueManager.addTranscriptionAndSummary(for: [video])
                }
            }
        }
        
        // Bulk processing for multiple selected videos
        if selectedItems.count > 1 {
            let selectedVideos = getSelectedVideos()
            if !selectedVideos.isEmpty {
                Divider()
                
                Menu("Bulk Processing (\(selectedVideos.count) videos)") {
                    Button("Transcribe All") {
                        processingQueueManager.addTranscriptionOnly(for: selectedVideos)
                    }
                    
                    Button("Translate All") {
                        processingQueueManager.addTranslationOnly(for: selectedVideos)
                    }
                    
                    Button("Summarize All") {
                        processingQueueManager.addSummaryOnly(for: selectedVideos)
                    }
                    
                    Divider()
                    
                    Button("Full Workflow for All") {
                        processingQueueManager.addFullProcessingWorkflow(for: selectedVideos)
                    }
                    
                    Button("Transcribe & Summarize All") {
                        processingQueueManager.addTranscriptionAndSummary(for: selectedVideos)
                    }
                }
            }
        }
        
        if case .folder = item.contentType {
            Divider()
            Button("Create Subfolder") {
                // TODO: Implement subfolder creation
            }
        }
        
        Divider()
        Button("Delete", role: .destructive) {
            triggerDeletion()
        }
    }
    
    // MARK: - Actions
    
    private func getSelectedVideos() -> [Video] {
        // This would need to be implemented to get videos from selected item IDs
        // For now, return empty array - this should be implemented with access to the content hierarchy
        return []
    }
    
    private func triggerDeletion() {
        print("🗑️ ROW: Context menu delete triggered for item: \(item.name) (ID: \(item.id)) - isFolder: \(item.isFolder)")
        print("🗑️ ROW: onDelete callback exists: \(onDelete != nil)")
        onDelete?(item.id)
    }
    
    private func startRenaming() {
        editedName = item.name
        renamingItemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
            focusedField = item.id
        }
    }
    
    private func commitRename() async {
        shouldCommitOnDisappear = false

        guard let renamingID = renamingItemID,
              renamingID == item.id else {
            await MainActor.run { cancelRename() }
            return
        }
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != item.name else {
            await MainActor.run { cancelRename() }
            return
        }
        
        // ❗ KEY CHANGE: Await the save operation BEFORE updating the local UI state.
        await store.renameItem(id: item.id, to: trimmedName)
        
        // This now runs only AFTER the save is complete.
        await MainActor.run {
            renamingItemID = nil
            focusedField = nil
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