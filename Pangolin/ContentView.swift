//
//  ContentView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var libraryManager = LibraryManager.shared
    @State private var showLibrarySelector = false
    @State private var showCreateLibrary = false
    
    var body: some View {
        Group {
            if libraryManager.isLibraryOpen {
                MainView()
                    .environmentObject(libraryManager)
            } else {
                LibraryWelcomeView(
                    showLibrarySelector: $showLibrarySelector,
                    showCreateLibrary: $showCreateLibrary
                )
                .environmentObject(libraryManager)
            }
        }
        .fileImporter(
            isPresented: $showLibrarySelector,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        try? await libraryManager.openLibrary(at: url)
                    }
                }
            case .failure(let error):
                print("Error selecting library: \(error)")
            }
        }
        .fileImporter(
            isPresented: $showCreateLibrary,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        try? await libraryManager.createLibrary(at: url, name: "My Library")
                    }
                }
            case .failure(let error):
                print("Error creating library: \(error)")
            }
        }
    }
}
