// PangolinApp.swift

import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared
    @StateObject private var videoFileManager = VideoFileManager.shared
    @State private var hasAttemptedAutoOpen = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if libraryManager.isLibraryOpen {
                    // REFACTORED: Pass the configured libraryManager into MainView's initializer.
                    // This ensures the entire view hierarchy, including the FolderNavigationStore,
                    // uses the correct, active Core Data context.
                    MainView(libraryManager: libraryManager)
                        .environmentObject(libraryManager)
                        .environmentObject(videoFileManager)
                } else {
                    // Show loading state while opening iCloud library
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        if libraryManager.isLoading {
                            Text("Initializing iCloud library...")
                                .font(.headline)
                            
                            if libraryManager.loadingProgress > 0 {
                                ProgressView(value: libraryManager.loadingProgress)
                                    .frame(maxWidth: 300)
                                Text("\(Int(libraryManager.loadingProgress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("Opening iCloud library...")
                                .font(.headline)
                        }
                        
                        if let error = libraryManager.error {
                            VStack(spacing: 10) {
                                Text("Error")
                                    .font(.headline)
                                    .foregroundColor(.red)
                                Text(error.localizedDescription)
                                    .multilineTextAlignment(.center)
                                if let recovery = error.recoverySuggestion {
                                    Text(recovery)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                
                                Button("Retry") {
                                    retryLibraryOpen()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                        }
                    }
                    .frame(minWidth: 600, minHeight: 500)
                }
            }
            .onAppear {
                if !hasAttemptedAutoOpen {
                    attemptAutoOpeniCloudLibrary()
                }
            }
        }
        #if os(macOS)
        .commands {
            // iCloud Library menu
            CommandMenu("Library") {
                Button("Refresh Library") {
                    retryLibraryOpen()
                }
                .keyboardShortcut("R", modifiers: .command)
                .disabled(libraryManager.isLoading)
            }
            
            // File menu additions
            CommandGroup(after: .newItem) {
                // Import and folder creation now handled in MainView toolbar
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
    
    private func attemptAutoOpeniCloudLibrary() {
        hasAttemptedAutoOpen = true
        
        Task {
            do {
                // Always try to get or create iCloud library
                _ = try await libraryManager.getOrCreateiCloudLibrary()
                print("✅ Successfully opened iCloud library")
            } catch {
                print("❌ Failed to get/create iCloud library: \(error)")
                // Error will be shown in the UI via libraryManager.error
            }
        }
    }
    
    private func retryLibraryOpen() {
        // Clear the error and try again
        libraryManager.error = nil
        hasAttemptedAutoOpen = false
        attemptAutoOpeniCloudLibrary()
    }
    
    private func generateThumbnails() {
        guard let library = libraryManager.currentLibrary,
              let context = libraryManager.viewContext else { return }
        
        Task {
            await FileSystemManager.shared.rebuildAllThumbnails(for: library, context: context)
        }
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
