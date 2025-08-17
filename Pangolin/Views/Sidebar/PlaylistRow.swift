//
//  PlaylistRow.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct PlaylistRow: View {
    let playlist: Playlist
    
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
    }
}