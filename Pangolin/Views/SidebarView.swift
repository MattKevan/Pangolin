//
//  SidebarView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import CoreData

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @State private var isShowingCreateFolder = false
    @State private var editingFolder: Folder?
    @State private var renamingFolderID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var refreshTrigger = UUID()
    
    // Computed properties that force refresh when trigger changes
    private var systemFolders: [Folder] {
        let _ = refreshTrigger // Force recomputation
        return store.systemFolders()
    }
    
    private var userFolders: [Folder] {
        let _ = refreshTrigger // Force recomputation
        return store.userFolders()
    }
    
    var body: some View {
        List(selection: $store.selectedTopLevelFolder) {
            // System folders (smart folders)
            Section("Pangolin") {
                ForEach(systemFolders) { folder in
                    FolderRowView(
                        folder: folder, 
                        showContextMenu: false, 
                        editingFolder: $editingFolder,
                        renamingFolderID: $renamingFolderID,
                        focusedField: $focusedField,
                        onDelete: {}
                    )
                    .tag(folder)
                }
            }
            
            // User folders
            Section("Library") {
                ForEach(userFolders) { folder in
                    FolderRowView(
                        folder: folder, 
                        showContextMenu: true, 
                        editingFolder: $editingFolder,
                        renamingFolderID: $renamingFolderID,
                        focusedField: $focusedField,
                        onDelete: { deleteFolder(folder) }
                    )
                    .tag(folder)
                }
            }
        }
        .onChange(of: store.selectedTopLevelFolder) { _, newFolder in
            if let newFolder {
                store.currentFolderID = newFolder.id
            }
        }
        #if os(macOS)
        .listStyle(SidebarListStyle())
        #else
        .listStyle(InsetGroupedListStyle())
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { isShowingCreateFolder = true }) {
                    Label("Add Folder", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingCreateFolder) {
            CreateFolderView(parentFolderID: nil)
        }
        .onKeyPress { keyPress in
            if keyPress.key == .return,
               let selected = store.selectedTopLevelFolder,
               !selected.isSmartFolder { // Only allow renaming for user folders
                renamingFolderID = selected.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                    focusedField = selected.id
                }
                return .handled
            }
            return .ignored
        }
        // Handle focus loss to end rename mode
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil {
                renamingFolderID = nil
            }
        }
        // Listen for content updates to refresh sidebar
        .onReceive(NotificationCenter.default.publisher(for: .contentUpdated)) { _ in
            DispatchQueue.main.async {
                refreshTrigger = UUID()
            }
        }
    }
    
    private func deleteFolder(_ folder: Folder) {
        // TODO: Implement folder deletion with confirmation
        print("Deleting folder: \(folder.name)")
    }
}

// MARK: - Folder Row View
private struct FolderRowView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    let folder: Folder
    let showContextMenu: Bool
    @Binding var editingFolder: Folder?
    @Binding var renamingFolderID: UUID?
    @FocusState.Binding var focusedField: UUID?
    let onDelete: () -> Void
    
    @State private var isDropTargeted = false
    @State private var editedName: String = ""

    var body: some View {
        Label {
            nameEditorView
        } icon: {
            Image(systemName: folder.isSmartFolder ? getSmartFolderIcon(folder.name) : "folder")
                .foregroundColor(folder.isSmartFolder ? .blue : .orange)
        }
        .onTapGesture {
            handleSlowClickRename()
        }
        .contextMenu {
            if showContextMenu {
                Button("Rename") {
                    renamingFolderID = folder.id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                        focusedField = folder.id
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
            // Provide visual feedback when a drop is targeted
            if isDropTargeted && !folder.isSmartFolder {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    #if os(macOS)
                    .padding(-4)
                    #endif
            }
        }
    }
    
    /// A view that conditionally shows a `Text` label or a `TextField` for renaming.
    @ViewBuilder
    private var nameEditorView: some View {
        if renamingFolderID == folder.id {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: folder.id)
                .onAppear {
                    editedName = folder.name
                }
                .onSubmit {
                    // Commit the rename when the user presses Return/Enter
                    commitRename()
                }
                .onKeyPress { keyPress in
                    if keyPress.key == .escape {
                        // Cancel the rename when the user presses Escape
                        cancelRename()
                        return .handled
                    }
                    return .ignored
                }
        } else {
            Text(folder.name)
        }
    }
    
    /// Commits the new name to the data store.
    private func commitRename() {
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName != folder.name {
            Task {
                await store.renameItem(id: folder.id, to: trimmedName)
                await MainActor.run {
                    renamingFolderID = nil
                    focusedField = nil
                }
            }
        } else {
            // Cancel if no change
            renamingFolderID = nil
            focusedField = nil
        }
    }

    /// Cancels the renaming process.
    private func cancelRename() {
        editedName = folder.name // Reset to original name
        renamingFolderID = nil
        focusedField = nil
    }
    
    /// Handles slow-click rename for user folders only
    private func handleSlowClickRename() {
        // Only allow renaming for user folders (not system folders) and only if this folder is already selected
        guard !folder.isSmartFolder, 
              showContextMenu, 
              store.selectedTopLevelFolder?.id == folder.id,
              renamingFolderID == nil else { 
            return 
        }
        
        // Start renaming
        editedName = folder.name
        renamingFolderID = folder.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
            focusedField = folder.id
        }
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
