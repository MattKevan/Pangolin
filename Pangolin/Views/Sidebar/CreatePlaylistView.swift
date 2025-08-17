//
//  CreatePlaylistView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


import SwiftUI

struct CreatePlaylistView: View {
    @Environment(\.dismiss) var dismiss
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
                    // Create playlist
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(playlistName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 150)
    }
}
