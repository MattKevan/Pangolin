//
//  SidebarView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/SidebarView.swift
import SwiftUI
import CoreData

struct SidebarView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @Binding var selectedPlaylist: Playlist?
    @State private var isShowingCreatePlaylist = false
    @State private var playlists: [Playlist] = []
    @State private var editingPlaylist: Playlist?
    
    var body: some View {
        List(selection: $selectedPlaylist) {
            Section("Library") {
                ForEach(systemPlaylists) { playlist in
                    PlaylistRow(playlist: playlist, editingPlaylist: $editingPlaylist)
                        .tag(playlist)
                }
            }
            
            Section("Playlists") {
                ForEach(rootUserPlaylists) { playlist in
                    PlaylistRowWithChildren(
                        playlist: playlist,
                        editingPlaylist: $editingPlaylist,
                        isRoot: true
                    )
                    .tag(playlist)
                }
                .onMove(perform: moveRootPlaylists)
            }
            #if os(macOS)
            .dropDestination(for: PlaylistTransfer.self) { playlistTransfers, location in
                guard !playlistTransfers.isEmpty else { return false }
                promotePlaylistToRoot(playlistTransfers)
                return true
            }
            #endif
        }
        #if os(macOS)
        .listStyle(SidebarListStyle())
        #else
        .listStyle(InsetGroupedListStyle())
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { isShowingCreatePlaylist = true }) {
                    Label("Add Playlist", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingCreatePlaylist) {
            CreatePlaylistView()
        }
        .onAppear {
            fetchPlaylists()
        }
        .onChange(of: libraryManager.currentLibrary) { library in
            fetchPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistsUpdated)) { _ in
            fetchPlaylists()
        }
        .onKeyPress { keyPress in
            if keyPress.key == .return,
               let selected = selectedPlaylist,
               selected.type == PlaylistType.user.rawValue {
                editingPlaylist = selected
                return .handled
            }
            return .ignored
        }
    }
    
    var systemPlaylists: [Playlist] {
        return playlists.filter { $0.type == "system" }.sorted { $0.sortOrder < $1.sortOrder }
    }
    
    var userPlaylists: [Playlist] {
        return playlists.filter { $0.type == "user" }.sorted { $0.name < $1.name }
    }
    
    var rootUserPlaylists: [Playlist] {
        return playlists.filter { $0.type == "user" && $0.parentPlaylist == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }
    
    private func moveRootPlaylists(from source: IndexSet, to destination: Int) {
        guard let context = libraryManager.viewContext else { return }
        
        // Get the actual playlists that are being moved
        let currentPlaylists = rootUserPlaylists
        
        // Validate indices to prevent crash
        guard !currentPlaylists.isEmpty,
              !source.isEmpty,
              source.allSatisfy({ $0 < currentPlaylists.count }),
              destination >= 0,
              destination <= currentPlaylists.count else {
            print("Invalid move indices: source=\(source), destination=\(destination), count=\(currentPlaylists.count)")
            return
        }
        
        // Create a new arrangement with the move applied
        var newArrangement = currentPlaylists
        newArrangement.move(fromOffsets: source, toOffset: destination)
        
        // Update sort orders for ALL root playlists based on the new arrangement
        for (index, playlist) in newArrangement.enumerated() {
            playlist.sortOrder = Int32(index)
            playlist.dateModified = Date()
        }
        
        do {
            try context.save()
            // Refresh the playlists list to reflect the changes
            fetchPlaylists()
        } catch {
            print("Failed to reorder root playlists: \(error)")
        }
    }
    
    private func promotePlaylistToRoot(_ playlistTransfers: [PlaylistTransfer]) {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              let playlistTransfer = playlistTransfers.first else { return }
        
        // Find the playlist being promoted
        let request = Playlist.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, playlistTransfer.id as CVarArg)
        
        do {
            let playlists = try context.fetch(request)
            guard let draggedPlaylist = playlists.first else { return }
            
            // Only promote child playlists (ignore if already root)
            guard draggedPlaylist.parentPlaylist != nil else { return }
            
            // Remove from parent
            draggedPlaylist.parentPlaylist = nil
            draggedPlaylist.dateModified = Date()
            
            // Update sort order - add to end of root playlists
            let currentRootPlaylists = rootUserPlaylists
            draggedPlaylist.sortOrder = Int32(currentRootPlaylists.count)
            
            try context.save()
            fetchPlaylists()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to promote playlist to root: \(error)")
        }
    }
    
    private func fetchPlaylists() {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary else {
            playlists = []
            return
        }
        
        let request = Playlist.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Playlist.type, ascending: true),
            NSSortDescriptor(keyPath: \Playlist.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \Playlist.name, ascending: true)
        ]
        
        do {
            playlists = try context.fetch(request)
        } catch {
            print("Failed to fetch playlists: \(error)")
            playlists = []
        }
    }
}