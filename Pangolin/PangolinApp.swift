//
//  PangolinApp.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @State private var showLibrarySelector = false
    @State private var showCreateLibrary = false
    
    var body: some Scene {
        WindowGroup {
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
                            do {
                                let _ = try await libraryManager.openLibrary(at: url)
                            } catch {
                                print("Failed to open library: \(error)")
                                // In a real app, show an error alert to the user
                            }
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
                            do {
                                let _ = try await libraryManager.createLibrary(at: url, name: "My Library")
                            } catch {
                                print("Failed to create library: \(error)")
                                // In a real app, show an error alert to the user
                            }
                        }
                    }
                case .failure(let error):
                    print("Error creating library: \(error)")
                }
            }
        }
        // CORRECTED: The .commands modifier is only available on macOS.
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Library...") {
                    showCreateLibrary = true
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
                
                Button("Open Library...") {
                    showLibrarySelector = true
                }
                .keyboardShortcut("O", modifiers: .command)
                
                Divider()
                
                Menu("Recent Libraries") {
                    ForEach(libraryManager.recentLibraries) { library in
                        Button(library.name) {
                            Task {
                                try? await libraryManager.openLibrary(at: library.path)
                            }
                        }
                        .disabled(!library.isAvailable)
                    }
                }
            }
        }
        #endif
    }
}
