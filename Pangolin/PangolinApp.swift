// PangolinApp.swift

import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared
    @State private var showLibrarySelector = false
    @State private var showCreateLibrary = false
    @State private var hasAttemptedAutoOpen = false
    @State private var isAttemptingAutoOpen = false
    @State private var showingImportPicker = false
    @State private var showingCreateFolder = false
    
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
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.movie, .video, .folder], allowsMultipleSelection: true) { result in
                handleVideoImport(result)
            }
            .sheet(isPresented: $showingCreateFolder) {
                CreateFolderView(parentFolderID: getCurrentFolderForNewFolder())
            }
        }
        #if os(macOS)
        .commands {
            // New Library menu
            CommandMenu("Library") {
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
                            Task { @MainActor in
                                try? await libraryManager.openLibrary(at: library.path)
                            }
                        }
                        .disabled(!library.isAvailable)
                    }
                }
            }
            
            // File menu additions
            CommandGroup(after: .newItem) {
                Button("Import Videos...") {
                    showingImportPicker = true
                }
                .keyboardShortcut("I", modifiers: .command)
                .disabled(!libraryManager.isLibraryOpen)
                
                Button("New Folder...") {
                    showingCreateFolder = true
                }
                .keyboardShortcut("N", modifiers: [.command, .shift, .option])
                .disabled(!libraryManager.isLibraryOpen)
            }
            
            // Edit menu additions
            CommandGroup(after: .undoRedo) {
                Button("Rename") {
                    triggerRename()
                }
                .keyboardShortcut(.return)
                .disabled(!libraryManager.isLibraryOpen || !hasRenameableSelection())
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
    
    private func handleVideoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let library = libraryManager.currentLibrary, let context = libraryManager.viewContext {
                // Import videos to the currently selected folder or root
                Task {
                    // Use VideoImporter to handle the import process
                    let importer = VideoImporter()
                    await importer.importFiles(urls, to: library, context: context)
                }
            }
        case .failure(let error):
            print("Error importing files: \(error)")
        }
    }
    
    private func getCurrentFolderForNewFolder() -> UUID? {
        // This would need to communicate with the current UI state
        // For now, return nil to create at root level
        // TODO: Integrate with FolderNavigationStore to get current folder
        return nil
    }
    
    private func hasRenameableSelection() -> Bool {
        // Check if there's a renameable selection by checking if a rename notification would work
        // This is a simple heuristic - in practice, this would be more sophisticated
        return libraryManager.isLibraryOpen
    }
    
    private func triggerRename() {
        // This would trigger rename on the selected item
        // TODO: Implement rename triggering mechanism
        NotificationCenter.default.post(name: NSNotification.Name("TriggerRename"), object: nil)
    }
}
