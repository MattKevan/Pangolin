//
//  HierarchicalPlaylistList.swift
//  Pangolin
//
//  Created by Matt Kevan on 17/08/2025.
//

import SwiftUI
import CoreData

struct PlaylistRowWithChildren: View {
    let playlist: Playlist
    @Binding var editingPlaylist: Playlist?
    let isRoot: Bool
    @State private var isExpanded = true
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        Group {
            // Main playlist row with disclosure indicator
            HStack {
                if hasChildren {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 12, height: 12)
                }
                
                PlaylistRow(playlist: playlist, editingPlaylist: $editingPlaylist)
            }
            
            // Child playlists (if any and expanded)
            if isExpanded, let children = playlist.childPlaylistsArray, !children.isEmpty {
                ForEach(children.sorted { $0.sortOrder < $1.sortOrder }) { childPlaylist in
                    HStack {
                        // Indentation for hierarchy (extra space for chevron + normal indent)
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 32)
                        
                        PlaylistRowWithChildren(
                            playlist: childPlaylist,
                            editingPlaylist: $editingPlaylist,
                            isRoot: false
                        )
                    }
                    .tag(childPlaylist)
                }
                .onMove { sourceIndices, destination in
                    moveChildPlaylists(from: sourceIndices, to: destination)
                }
            }
        }
    }
    
    private var hasChildren: Bool {
        return playlist.childPlaylistsArray?.isEmpty == false
    }
    
    private func moveChildPlaylists(from source: IndexSet, to destination: Int) {
        guard let context = libraryManager.viewContext,
              let children = playlist.childPlaylistsArray,
              !children.isEmpty else { return }
        
        // Get current sorted children
        let currentChildren = children.sorted { $0.sortOrder < $1.sortOrder }
        
        // Validate indices to prevent crash
        guard !source.isEmpty,
              source.allSatisfy({ $0 < currentChildren.count }),
              destination >= 0,
              destination <= currentChildren.count else {
            print("Invalid move indices: source=\(source), destination=\(destination), count=\(currentChildren.count)")
            return
        }
        
        // Create new arrangement with the move applied
        var newArrangement = currentChildren
        newArrangement.move(fromOffsets: source, toOffset: destination)
        
        // Update sort orders for ALL child playlists based on the new arrangement
        for (index, childPlaylist) in newArrangement.enumerated() {
            childPlaylist.sortOrder = Int32(index)
            childPlaylist.dateModified = Date()
        }
        
        do {
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to reorder child playlists: \(error)")
        }
    }
}