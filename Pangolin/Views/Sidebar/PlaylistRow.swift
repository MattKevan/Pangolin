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
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var isTargeted = false
    
    var body: some View {
        Label {
            HStack {
                Text(playlist.name)
                Spacer()
                if playlist.videoCount > 0 {
                    Text("\(playlist.videoCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } icon: {
            Image(systemName: playlist.iconName ?? "folder")
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        #if os(macOS)
        .dropDestination(for: VideoTransfer.self) { videoTransfers, location in
            addVideosToPlaylist(videoTransfers)
            return true
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
        #else
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            handleiOSDrop(providers: providers)
            return true
        }
        #endif
    }
    
    private func addVideosToPlaylist(_ videoTransfers: [VideoTransfer]) {
        guard let context = libraryManager.viewContext,
              let library = libraryManager.currentLibrary,
              playlist.type == PlaylistType.user.rawValue else { return }
        
        // Find videos by their IDs
        let videoIDs = videoTransfers.map { $0.id }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@ AND id IN %@", library, videoIDs)
        
        do {
            let videos = try context.fetch(request)
            let mutableVideos = playlist.mutableSetValue(forKey: "videos")
            
            for video in videos {
                if !mutableVideos.contains(video) {
                    mutableVideos.add(video)
                }
            }
            
            playlist.dateModified = Date()
            try context.save()
            NotificationCenter.default.post(name: .playlistsUpdated, object: nil)
        } catch {
            print("Failed to add videos to playlist: \(error)")
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
}