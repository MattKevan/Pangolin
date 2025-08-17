//
//  CreatePlaylistView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI
import CoreData

struct CreatePlaylistView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var playlistName = ""
    
    var body: some View {
        VStack {
            Text("Create New Playlist")
                .font(.headline)
            
            TextField("Playlist Name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    createPlaylist()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(playlistName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 150)
    }
    
    private func createPlaylist() {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              let playlistEntityDescription = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Playlist"] else {
            print("Could not find Playlist entity description or library")
            return
        }
        
        let trimmedName = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // Get the next sort order for user playlists
        let request = Playlist.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND type == %@ AND parentPlaylist == NULL", library, PlaylistType.user.rawValue)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Playlist.sortOrder, ascending: false)]
        request.fetchLimit = 1
        
        let nextSortOrder: Int32
        do {
            let existingPlaylists = try context.fetch(request)
            nextSortOrder = (existingPlaylists.first?.sortOrder ?? -1) + 1
        } catch {
            print("Failed to fetch existing playlists for sort order: \(error)")
            nextSortOrder = 0
        }
        
        let playlist = Playlist(entity: playlistEntityDescription, insertInto: context)
        playlist.id = UUID()
        playlist.name = trimmedName
        playlist.type = PlaylistType.user.rawValue
        playlist.dateCreated = Date()
        playlist.dateModified = Date()
        playlist.library = library
        playlist.parentPlaylist = nil
        playlist.sortOrder = nextSortOrder
        
        do {
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }
}
