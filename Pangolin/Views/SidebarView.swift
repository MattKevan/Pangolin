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

struct SidebarView: View {
    @EnvironmentObject private var store: FolderNavigationStore
    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.managedObjectContext) private var viewContext
    
    @State private var isShowingCreateFolder = false
    @State private var editingFolder: Folder?
    @State private var renamingFolderID: UUID? = nil
    @FocusState private var focusedField: UUID?
    @State private var folderToDelete: DeletionItem?
    
    @State private var systemFolders: [Folder] = []
    @State private var userFolders: [Folder] = []
    @State private var isDeletingFolder = false
    @State private var isExternalDropTargeted = false

    private let processingQueueManager = ProcessingQueueManager.shared
    
    var body: some View {
        List(selection: $store.selectedSidebarItem) {
            // Search item
            Section("Pangolin") {
                Label("Search", systemImage: "magnifyingglass")
                    .contentShape(Rectangle())
                    .tag(SidebarSelection.search)
                
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
                    .tag(SidebarSelection.folder(folder))
                }
            }
            
            // Library top-level folders
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
                    .contentShape(Rectangle())
                    .tag(SidebarSelection.folder(folder))
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
        .alert(
            sidebarDeletionAlertContent.title,
            isPresented: Binding(
                get: { folderToDelete != nil },
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
            Button("Delete", role: .destructive) {
                guard let deletionItem = folderToDelete else {
                    cancelDeletion()
                    return
                }
                Task {
                    await confirmDeletion(deletionItem)
                }
            }
        } message: {
            Text(sidebarDeletionAlertContent.message)
        }
        .onKeyPress { keyPress in
            if keyPress.key == .return,
               case .folder(let selected) = store.selectedSidebarItem,
               !selected.isSmartFolder { // Only allow renaming for user folders
                renamingFolderID = selected.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                    focusedField = selected.id
                }
                return .handled
            } else if (keyPress.key == .delete || keyPress.key == .deleteForward),
                      case .folder(let selected) = store.selectedSidebarItem,
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
            if !isDeletingFolder {
                refreshFolders()
            }
        }
        .onReceive(libraryManager.$currentLibrary) { _ in
            refreshFolders()
        }
        .onAppear {
            refreshFolders()
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
    
    private func refreshFolders() {
        systemFolders = store.systemFolders()
        userFolders = store.userFolders()
    }
    
    private var sidebarDeletionAlertContent: DeletionAlertContent {
        guard let folderToDelete else {
            return [].deletionAlertContent
        }
        return [folderToDelete].deletionAlertContent
    }
    
    private func deleteFolder(_ folder: Folder) {
        print("🗑️ SIDEBAR: deleteFolder called for: \(folder.name ?? "nil") (ID: \(folder.id ?? UUID()))")
        isDeletingFolder = true
        // Create a snapshot that won't be affected by Core Data changes
        let deletionItem = DeletionItem(folder: folder)
        print("🗑️ SIDEBAR: Created deletion item: \(deletionItem.name)")
        folderToDelete = deletionItem
        print("🗑️ SIDEBAR: Set folderToDelete item, this should trigger alert")
    }
    
    private func confirmDeletion(_ deletionItem: DeletionItem) async {
        let success = await store.deleteItems([deletionItem.id])
        
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
    
    private func cancelDeletion() {
        folderToDelete = nil
        isDeletingFolder = false
        // Refresh folders after deletion process is complete
        refreshFolders()
    }
    
    private func triggerRenameFromMenu() {
        // Trigger rename on the selected sidebar folder
        if case .folder(let selected) = store.selectedSidebarItem,
           !selected.isSmartFolder { // Only allow renaming for user folders
            renamingFolderID = selected.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
                focusedField = selected.id
            }
        }
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
    @Binding var editingFolder: Folder?
    @Binding var renamingFolderID: UUID?
    @FocusState.Binding var focusedField: UUID?
    let onDelete: () -> Void
    
    @State private var isDropTargeted = false
    @State private var editedName: String = ""
    @State private var shouldCommitOnDisappear = false
    
    private var folderDisplayName: String {
        folder.name ?? "Untitled Folder"
    }

    var body: some View {
        Label {
            nameEditorView
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: folder.isSmartFolder ? getSmartFolderIcon(folderDisplayName) : "folder")
                .foregroundColor(folder.isSmartFolder ? .blue : .orange)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if showContextMenu {
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
    
    private func getSmartFolderIcon(_ name: String) -> String {
        switch name {
        case "All Videos": return "video.fill"
        case "Recent": return "clock.fill"
        case "Favorites": return "heart.fill"
        default: return "folder"
        }
    }
}

// MARK: - Sidebar Library Row
