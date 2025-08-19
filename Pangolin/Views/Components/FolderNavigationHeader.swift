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
    
    private var canGoBack: Bool {
        !store.navigationPath.isEmpty
    }
    
    private var folderName: String {
        store.folderName(for: store.currentFolderID)
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
            
            Spacer()
            
            // Folder name
            Text(folderName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // Create subfolder button
            Button {
                onCreateSubfolder()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                    Text("New Folder")
                        .font(.system(size: 14))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
            .help("Create New Subfolder")
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
    FolderNavigationHeader {
        // Preview action
    }
    .environmentObject(FolderNavigationStore(libraryManager: LibraryManager.shared))
}