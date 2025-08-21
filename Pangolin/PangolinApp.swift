// PangolinApp.swift

import SwiftUI

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @State private var showLibrarySelector = false
    @State private var showCreateLibrary = false
    @State private var hasAttemptedAutoOpen = false
    @State private var isAttemptingAutoOpen = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if libraryManager.isLibraryOpen {
                    // REFACTORED: Pass the configured libraryManager into MainView's initializer.
                    // This ensures the entire view hierarchy, including the FolderNavigationStore,
                    // uses the correct, active Core Data context.
                    MainView(libraryManager: libraryManager)
                        .environmentObject(libraryManager)
                } else if isAttemptingAutoOpen {
                    // Show loading state while attempting to auto-open
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Opening last library...")
                            .font(.headline)
                    }
                    .frame(minWidth: 600, minHeight: 500)
                } else {
                    LibraryWelcomeView(
                        showLibrarySelector: $showLibrarySelector,
                        showCreateLibrary: $showCreateLibrary
                    )
                    .environmentObject(libraryManager)
                }
            }
            .onAppear {
                if !hasAttemptedAutoOpen {
                    attemptAutoOpenLastLibrary()
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
            
            CommandMenu("Video") {
                Button("Generate Thumbnails") {
                    generateThumbnails()
                }
                .disabled(!libraryManager.isLibraryOpen)
            }
        }
        #endif
    }
    
    private func attemptAutoOpenLastLibrary() {
        hasAttemptedAutoOpen = true
        isAttemptingAutoOpen = true
        
        Task {
            do {
                try await libraryManager.openLastLibrary()
                await MainActor.run {
                    isAttemptingAutoOpen = false
                }
            } catch {
                // Failed to auto-open, show welcome screen
                print("Failed to auto-open last library: \(error)")
                await MainActor.run {
                    isAttemptingAutoOpen = false
                }
            }
        }
    }
    
    private func generateThumbnails() {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else { return }
        
        Task {
            await FileSystemManager.shared.rebuildAllThumbnails(for: library, context: context)
        }
    }
}
