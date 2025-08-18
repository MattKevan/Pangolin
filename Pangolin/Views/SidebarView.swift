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
    
    var body: some View {
        List(selection: $store.selectedTopLevelFolder) {
            // System folders (smart folders)
            Section("Pangolin") {
                ForEach(store.systemFolders()) { folder in
                    FolderRowView(folder: folder, showContextMenu: false, editingFolder: $editingFolder, onDelete: {})
                        .tag(folder)
                }
            }
            
            // User folders
            Section("Library") {
                ForEach(store.userFolders()) { folder in
                    FolderRowView(folder: folder, showContextMenu: true, editingFolder: $editingFolder) {
                        deleteFolder(folder)
                    }
                    .tag(folder)
                }
            }
        }
        .onChange(of: store.selectedTopLevelFolder) { _, newFolder in
            if let newFolder {
                store.currentFolderID = newFolder.id
            }
        }
        // CORRECTED: Use platform-specific list styles.
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
               let selected = store.selectedTopLevelFolder {
                editingFolder = selected
                return .handled
            }
            return .ignored
        }
    }
    
    private func deleteFolder(_ folder: Folder) {
        // TODO: Implement folder deletion with confirmation
    }
}

// MARK: - Folder Row View
private struct FolderRowView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    let folder: Folder
    let showContextMenu: Bool
    @Binding var editingFolder: Folder?
    let onDelete: () -> Void
    
    @State private var isDropTargeted = false

    var body: some View {
        Label {
            Text(folder.name)
        } icon: {
            Image(systemName: folder.isSmartFolder ? getSmartFolderIcon(folder.name) : "folder")
                .foregroundColor(folder.isSmartFolder ? .blue : .orange)
        }
        .contextMenu {
            if showContextMenu {
                Button("Rename") {
                    editingFolder = folder
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
                    .padding(-4) // Adjust padding to look good in the sidebar
                    #endif
            }
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
