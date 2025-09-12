//
//  FolderNavigationHeader.swift
//  Pangolin
//
//  Created by Matt Kevan on 18/08/2025.
//

import SwiftUI

struct FolderNavigationHeader: View {
    @EnvironmentObject private var store: FolderNavigationStore
    let onCreateSubfolder: () -> Void
    let onDeleteSelected: () -> Void
    let hasSelectedItems: Bool
    
    private var canGoBack: Bool {
        !store.navigationPath.isEmpty
    }
    
    private var folderName: String {
        store.folderName(for: store.currentFolderID)
    }
    
    private var shouldShowCreateButton: Bool {
        // Hide create button in smart folders
        guard let currentFolder = store.currentFolder else { return false }
        return !currentFolder.isSmartFolder
    }
    
    private var shouldShowDeleteButton: Bool {
        // Hide delete button in smart folders
        guard let currentFolder = store.currentFolder else { return false }
        return !currentFolder.isSmartFolder
    }
    
    var body: some View {
        HStack {
            // Back button
            if canGoBack {
                Button {
                    store.navigateBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Back")
                            .font(.system(size: 14))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
            }
            
            // Folder name
            Text(folderName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // Action buttons (hidden in smart folders)
            HStack(spacing: 8) {
                // Delete selected items button
                if shouldShowDeleteButton {
                    Button {
                        onDeleteSelected()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(hasSelectedItems ? .primary : .secondary)
                    .disabled(!hasSelectedItems)
                    .help("Delete Selected Items")
                }
                
                // Create subfolder button
                if shouldShowCreateButton {
                    Button {
                        onCreateSubfolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
                    .help("Create New Subfolder")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(backgroundMaterial)
        .overlay(
            Rectangle()
                .fill(separatorColor)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
    
    private var backgroundMaterial: some View {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
    
    private var separatorColor: Color {
        #if os(macOS)
        Color(NSColor.separatorColor)
        #else
        Color(.separator)
        #endif
    }
}

#Preview {
    FolderNavigationHeader(
        onCreateSubfolder: {
            // Preview create action
        },
        onDeleteSelected: {
            // Preview delete action
        },
        hasSelectedItems: true
    )
    .environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))
}