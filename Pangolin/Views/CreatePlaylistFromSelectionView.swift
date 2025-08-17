//
//  CreatePlaylistFromSelectionView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import CoreData

struct CreatePlaylistFromSelectionView: View {
    let selectedVideos: [Video]
    let library: Library
    let onPlaylistCreated: () -> Void
    
    @State private var playlistName = ""
    @State private var selectedParent: Playlist?
    @State private var availableParents: [Playlist] = []
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        NavigationView {
            Form {
                Section("Playlist Details") {
                    TextField("Playlist Name", text: $playlistName)
                    
                    Picker("Parent Playlist", selection: $selectedParent) {
                        Text("None (Root Level)")
                            .tag(nil as Playlist?)
                        
                        ForEach(availableParents, id: \.id) { playlist in
                            Text(playlist.name)
                                .tag(playlist as Playlist?)
                        }
                    }
                }
                
                Section("Selected Videos") {
                    Text("\(selectedVideos.count) video\(selectedVideos.count == 1 ? "" : "s") selected")
                        .foregroundColor(.secondary)
                    
                    ForEach(selectedVideos.prefix(5), id: \.id) { video in
                        HStack {
                            Image(systemName: "video")
                                .foregroundColor(.secondary)
                            Text(video.title)
                                .lineLimit(1)
                        }
                    }
                    
                    if selectedVideos.count > 5 {
                        Text("and \(selectedVideos.count - 5) more...")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Create Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createPlaylist()
                    }
                    .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            fetchAvailableParents()
        }
    }
    
    private func fetchAvailableParents() {
        guard let context = libraryManager.viewContext else { return }
        
        let request = Playlist.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND type == %@", library, PlaylistType.user.rawValue)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Playlist.name, ascending: true)
        ]
        
        do {
            availableParents = try context.fetch(request)
        } catch {
            print("Failed to fetch available parent playlists: \(error)")
            availableParents = []
        }
    }
    
    private func createPlaylist() {
        guard let context = libraryManager.viewContext,
              let playlistEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Playlist"] else {
            print("Could not find Playlist entity description")
            return
        }
        
        let playlist = Playlist(entity: playlistEntityDescription, insertInto: context)
        playlist.id = UUID()
        playlist.name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.type = PlaylistType.user.rawValue
        playlist.dateCreated = Date()
        playlist.dateModified = Date()
        playlist.library = library
        playlist.parentPlaylist = selectedParent
        // Get the next sort order for user playlists
        let sortOrderRequest = Playlist.fetchRequest()
        if let parent = selectedParent {
            sortOrderRequest.predicate = NSPredicate(format: "library == %@ AND type == %@ AND parentPlaylist == %@", library, PlaylistType.user.rawValue, parent)
        } else {
            sortOrderRequest.predicate = NSPredicate(format: "library == %@ AND type == %@ AND parentPlaylist == NULL", library, PlaylistType.user.rawValue)
        }
        sortOrderRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Playlist.sortOrder, ascending: false)]
        sortOrderRequest.fetchLimit = 1
        
        let nextSortOrder: Int32
        do {
            let existingPlaylists = try context.fetch(sortOrderRequest)
            nextSortOrder = (existingPlaylists.first?.sortOrder ?? -1) + 1
        } catch {
            print("Failed to fetch existing playlists for sort order: \(error)")
            nextSortOrder = 0
        }
        
        playlist.sortOrder = nextSortOrder
        
        // Add selected videos to the playlist
        let mutableVideos = playlist.mutableSetValue(forKey: "videos")
        for video in selectedVideos {
            mutableVideos.add(video)
        }
        
        do {
            try context.save()
            onPlaylistCreated()
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }
}