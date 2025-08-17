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
    
    var body: some View {
        List(selection: $selectedPlaylist) {
            Section("Library") {
                ForEach(systemPlaylists) { playlist in
                    PlaylistRow(playlist: playlist)
                        .tag(playlist)
                }
            }
            
            Section("Playlists") {
                OutlineGroup(rootUserPlaylists, children: \.childPlaylistsArray) { playlist in
                    PlaylistRow(playlist: playlist)
                        .tag(playlist)
                }
            }
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
    }
    
    var systemPlaylists: [Playlist] {
        return playlists.filter { $0.type == "system" }.sorted { $0.sortOrder < $1.sortOrder }
    }
    
    var userPlaylists: [Playlist] {
        return playlists.filter { $0.type == "user" }.sorted { $0.name < $1.name }
    }
    
    var rootUserPlaylists: [Playlist] {
        return playlists.filter { $0.type == "user" && $0.parentPlaylist == nil }.sorted { $0.name < $1.name }
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