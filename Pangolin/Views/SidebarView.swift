//
//  SidebarView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import CoreData
import Combine

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.managedObjectContext) private var viewContext
    
    @State private var isShowingCreateFolder = false
    @State private var editingFolder: Folder?
    @State private var renamingFolderID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var showingDeletionConfirmation = false
    @State private var folderToDelete: Folder?
    @State private var folderToDeleteSnapshot: DeletionItem?
    
    @State private var systemFolders: [Folder] = []
    @State private var userFolders: [Folder] = []
    
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
                    .contentShape(Rectangle()) // Make the entire row clickable
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
                    .contentShape(Rectangle()) // Make the entire row clickable
                    .tag(folder)
                }
            }
        }
        .onChange(of: store.selectedTopLevelFolder) { _, newFolder in
            // Defer the state update to avoid "Publishing changes from within view updates" error
            Task { @MainActor in
                if let newFolder {
                    store.currentFolderID = newFolder.id
                }
            }
        }
        #if os(macOS)
        .listStyle(SidebarListStyle())
        #else
        .listStyle(InsetGroupedListStyle())
        #endif
        // Removed Sidebar toolbar to avoid duplicates and overflow.
        // Add-folder is now owned by MainView's toolbar.
        .sheet(isPresented: $showingDeletionConfirmation) {
            if let folder = folderToDelete {
                let deletionItem = DeletionItem(folder: folder)
                DeletionConfirmationView(
                    items: [deletionItem],
                    onConfirm: {
                        Task {
                            await confirmDeletion()
                        }
                    },
                    onCancel: {
                        cancelDeletion()
                    }
                )
                .onAppear {
                    print("🗑️ SIDEBAR: Sheet rendering DeletionConfirmationView for: \(deletionItem.name)")
                }
            } else {
                Text("No folder selected for deletion")
                    .padding()
                    .onAppear {
                        print("⚠️ SIDEBAR: Sheet rendering but folderToDelete is nil!")
                        showingDeletionConfirmation = false
                    }
            }
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
            } else if (keyPress.key == .delete || keyPress.key == .deleteForward),
                      let selected = store.selectedTopLevelFolder,
                      !selected.isSmartFolder { // Only allow deletion for user folders
                deleteFolder(selected)
                return .handled
            }
            return .ignored
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerRename"))) { _ in
            triggerRenameFromMenu()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in
            refreshFolders()
        }
        .onReceive(libraryManager.$currentLibrary) { _ in
            refreshFolders()
        }
        .onAppear {
            refreshFolders()
        }
    }
    
    private func refreshFolders() {
        systemFolders = store.systemFolders()
        userFolders = store.userFolders()
    }
    
    private func deleteFolder(_ folder: Folder) {
        print("🗑️ SIDEBAR: deleteFolder called for: \(folder.name ?? "nil") (ID: \(folder.id ?? UUID()))")
        folderToDelete = folder
        // Create a snapshot that won't be affected by Core Data changes
        folderToDeleteSnapshot = DeletionItem(folder: folder)
        print("🗑️ SIDEBAR: Set folderToDelete to: \(folderToDelete?.name ?? "nil")")
        print("🗑️ SIDEBAR: Created folderToDeleteSnapshot: \(folderToDeleteSnapshot?.name ?? "nil")")
        showingDeletionConfirmation = true
        print("🗑️ SIDEBAR: Set showingDeletionConfirmation to: \(showingDeletionConfirmation)")
    }
    
    private func confirmDeletion() async {
        guard let folder = folderToDelete else { return }
        
        let success = await store.deleteItems([folder.id!])
        
        await MainActor.run {
            if success {
                // Clear selection if the deleted folder was selected
                if store.selectedTopLevelFolder?.id == folder.id {
                    // Select "All Videos" folder as fallback
                    let systemFolders = store.systemFolders()
                    if let allVideosFolder = systemFolders.first(where: { $0.name == "All Videos" }) {
                        store.selectedTopLevelFolder = allVideosFolder
                        store.currentFolderID = allVideosFolder.id
                    }
                }
            }
            
            cancelDeletion()
        }
    }
    
    private func cancelDeletion() {
        folderToDelete = nil
        folderToDeleteSnapshot = nil
        showingDeletionConfirmation = false
    }
    
    private func triggerRenameFromMenu() {
        // Trigger rename on the selected sidebar folder
        if let selected = store.selectedTopLevelFolder,
           !selected.isSmartFolder { // Only allow renaming for user folders
            renamingFolderID = selected.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                focusedField = selected.id
            }
        }
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
    @State private var shouldCommitOnDisappear = false

    var body: some View {
        Label {
            nameEditorView
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: folder.isSmartFolder ? getSmartFolderIcon(folder.name!) : "folder")
                .foregroundColor(folder.isSmartFolder ? .blue : .orange)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if showContextMenu {
                Button("Rename") {
                    renamingFolderID = folder.id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
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
                    editedName = folder.name!
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
            Text(folder.name!)
        }
    }
    
    private func commitRename() async {
        shouldCommitOnDisappear = false
        
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty && trimmedName != folder.name! else {
            await MainActor.run { cancelRename() }
            return
        }
        
        await store.renameItem(id: folder.id!, to: trimmedName)
        
        await MainActor.run {
            renamingFolderID = nil
            focusedField = nil
        }
    }

    private func cancelRename() {
        editedName = folder.name!
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
