//
//  PlaylistRow.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI
import CoreData

struct PlaylistRow: View {
    let playlist: Playlist
    @Binding var editingPlaylist: Playlist?
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var isTargeted = false
    @State private var editingName = ""
    @FocusState private var isTextFieldFocused: Bool
    
    private var isEditing: Bool {
        editingPlaylist?.id == playlist.id
    }
    
    var body: some View {
        Label {
            HStack {
                if isEditing {
                    TextField("Playlist name", text: $editingName)
                        .textFieldStyle(.plain)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            saveNewName()
                        }
                        .onKeyPress { keyPress in
                            if keyPress.key == .escape {
                                cancelEditing()
                                return .handled
                            }
                            return .ignored
                        }
                } else {
                    Text(playlist.name)
                }
                
                Spacer()
                if playlist.videoCount > 0 {
                    Text("\(playlist.videoCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } icon: {
            Image(systemName: playlist.dynamicIconName)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        #if os(macOS)
        .draggable(PlaylistTransfer(playlist: playlist)) {
            Label(playlist.name, systemImage: playlist.dynamicIconName)
                .padding(8)
                .background(Color.accentColor.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(6)
        }
        .dropDestination(for: VideoTransfer.self) { videoTransfers, location in
            guard !videoTransfers.isEmpty,
                  playlist.canAcceptVideos else { return false }
            moveVideosToPlaylist(videoTransfers)
            return true
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
        .dropDestination(for: VideoBatchTransfer.self) { batchTransfers, location in
            guard !batchTransfers.isEmpty,
                  playlist.canAcceptVideos else { return false }
            moveBatchVideosToPlaylist(batchTransfers)
            return true
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
        .dropDestination(for: PlaylistTransfer.self) { playlistTransfers, location in
            guard !playlistTransfers.isEmpty,
                  playlist.canAcceptPlaylists else { return false }
            nestPlaylistIntoParent(playlistTransfers)
            return true
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
        #else
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            guard playlist.canAcceptVideos else { return false }
            handleiOSDrop(providers: providers)
            return true
        }
        #endif
        .contextMenu {
            if playlist.type == PlaylistType.user.rawValue {
                Button("Rename") {
                    startEditing()
                }
                .keyboardShortcut(.return, modifiers: [])
                
                Divider()
                
                Button("Delete", role: .destructive) {
                    deletePlaylist()
                }
            }
        }
        .onChange(of: editingPlaylist) { oldValue, newValue in
            if newValue?.id == playlist.id && editingName.isEmpty {
                // Start editing this playlist
                editingName = playlist.name
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
        }
    }
    
    private func nestPlaylistIntoParent(_ playlistTransfers: [PlaylistTransfer]) {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              playlist.type == PlaylistType.user.rawValue,
              let playlistTransfer = playlistTransfers.first else { return }
        
        // Prevent nesting a playlist into itself or its descendants
        if playlistTransfer.id == playlist.id {
            return
        }
        
        // Find the playlist being moved
        let request = Playlist.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, playlistTransfer.id as CVarArg)
        
        do {
            let playlists = try context.fetch(request)
            guard let draggedPlaylist = playlists.first else { return }
            
            // Prevent circular nesting by checking if target playlist is a descendant of dragged playlist
            if isDescendantOf(playlist: playlist, potentialAncestor: draggedPlaylist) {
                return
            }
            
            // Update the parent relationship
            draggedPlaylist.parentPlaylist = playlist
            draggedPlaylist.dateModified = Date()
            
            // Update sort order - add to end of children
            let currentChildren = playlist.childPlaylistsArray ?? []
            draggedPlaylist.sortOrder = Int32(currentChildren.count)
            
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to nest playlist: \(error)")
        }
    }
    
    private func isDescendantOf(playlist: Playlist, potentialAncestor: Playlist) -> Bool {
        var current = playlist.parentPlaylist
        while let parent = current {
            if parent.id == potentialAncestor.id {
                return true
            }
            current = parent.parentPlaylist
        }
        return false
    }
    
    private func moveVideosToPlaylist(_ videoTransfers: [VideoTransfer]) {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              playlist.type == PlaylistType.user.rawValue else { return }
        
        // Find videos by their IDs
        let videoIDs = videoTransfers.map { $0.id }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id IN %@", library, videoIDs)
        
        do {
            let videos = try context.fetch(request)
            let targetPlaylistVideos = playlist.mutableSetValue(forKey: "videos")
            
            for (video, transfer) in zip(videos, videoTransfers) {
                // Remove from source playlist if it exists
                if let sourcePlaylistId = transfer.sourcePlaylistId {
                    let sourceRequest = Playlist.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, sourcePlaylistId as CVarArg)
                    
                    if let sourcePlaylists = try? context.fetch(sourceRequest),
                       let sourcePlaylist = sourcePlaylists.first {
                        let sourcePlaylistVideos = sourcePlaylist.mutableSetValue(forKey: "videos")
                        sourcePlaylistVideos.remove(video)
                        sourcePlaylist.dateModified = Date()
                    }
                }
                
                // Add to target playlist if not already there
                if !targetPlaylistVideos.contains(video) {
                    targetPlaylistVideos.add(video)
                }
            }
            
            playlist.dateModified = Date()
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to move videos to playlist: \(error)")
        }
    }
    
    private func moveBatchVideosToPlaylist(_ batchTransfers: [VideoBatchTransfer]) {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              playlist.type == PlaylistType.user.rawValue,
              let batchTransfer = batchTransfers.first else { return }
        
        // Find videos by their IDs
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id IN %@", library, batchTransfer.videoIds)
        
        do {
            let videos = try context.fetch(request)
            let targetPlaylistVideos = playlist.mutableSetValue(forKey: "videos")
            
            for video in videos {
                // Remove from source playlist if it exists
                if let sourcePlaylistId = batchTransfer.sourcePlaylistId {
                    let sourceRequest = Playlist.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "library == %@ AND id == %@", library, sourcePlaylistId as CVarArg)
                    
                    if let sourcePlaylists = try? context.fetch(sourceRequest),
                       let sourcePlaylist = sourcePlaylists.first {
                        let sourcePlaylistVideos = sourcePlaylist.mutableSetValue(forKey: "videos")
                        sourcePlaylistVideos.remove(video)
                        sourcePlaylist.dateModified = Date()
                    }
                }
                
                // Add to target playlist if not already there
                if !targetPlaylistVideos.contains(video) {
                    targetPlaylistVideos.add(video)
                }
            }
            
            playlist.dateModified = Date()
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to move batch videos to playlist: \(error)")
        }
    }
    
    #if os(iOS)
    private func handleiOSDrop(providers: [NSItemProvider]) -> Bool {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              playlist.type == PlaylistType.user.rawValue else { return false }
        
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { (object, error) in
                    if let videoIdString = object as? String,
                       let videoId = UUID(uuidString: videoIdString) {
                        
                        DispatchQueue.main.async {
                            let request = Video.fetchRequest()
                            request.predicate = NSPredicate(format: "library == %@ AND id == %@", library, videoId as CVarArg)
                            
                            do {
                                let videos = try context.fetch(request)
                                if let video = videos.first {
                                    let mutableVideos = self.playlist.mutableSetValue(forKey: "videos")
                                    if !mutableVideos.contains(video) {
                                        mutableVideos.add(video)
                                        self.playlist.dateModified = Date()
                                        try context.save()
                                        NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
                                    }
                                }
                            } catch {
                                print("Failed to add video to playlist on iOS: \(error)")
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    #endif
    
    // MARK: - Editing Functions
    
    private func startEditing() {
        editingName = playlist.name
        editingPlaylist = playlist
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isTextFieldFocused = true
        }
    }
    
    private func cancelEditing() {
        editingPlaylist = nil
        editingName = ""
        isTextFieldFocused = false
    }
    
    private func saveNewName() {
        let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty,
              trimmedName != playlist.name,
              let context = libraryManager.viewContext else {
            cancelEditing()
            return
        }
        
        playlist.name = trimmedName
        playlist.dateModified = Date()
        
        do {
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to rename playlist: \(error)")
        }
        
        editingPlaylist = nil
        editingName = ""
        isTextFieldFocused = false
    }
    
    private func deletePlaylist() {
        guard let context = libraryManager.viewContext else { return }
        
        // Remove the playlist from Core Data
        context.delete(playlist)
        
        do {
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
}