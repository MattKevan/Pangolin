//
//  LibraryWelcomeView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct LibraryWelcomeView: View {
    @Binding var showLibrarySelector: Bool
    @Binding var showCreateLibrary: Bool
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)
            
            Text("Welcome to Pangolin")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Your personal video library manager")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                Button(action: { showCreateLibrary = true }) {
                    Label("Create New Library", systemImage: "plus.square")
                        .frame(width: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                
                Button(action: { showLibrarySelector = true }) {
                    Label("Open Existing Library", systemImage: "folder")
                        .frame(width: 200)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                
                if !libraryManager.recentLibraries.isEmpty {
                    Divider()
                        .frame(width: 200)
                    
                    VStack(alignment: .leading) {
                        Text("Recent Libraries")
                            .font(.headline)
                        
                        ForEach(libraryManager.recentLibraries.prefix(3)) { library in
                            Button(action: {
                                Task {
                                    try? await libraryManager.openLibrary(at: library.path)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                    VStack(alignment: .leading) {
                                        Text(library.name)
                                            .font(.body)
                                        Text(library.path.path)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!library.isAvailable)
                        }
                    }
                }
            }
        }
        .padding(50)
        .frame(minWidth: 600, minHeight: 500)
    }
}
