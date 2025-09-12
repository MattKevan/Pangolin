// PangolinApp.swift

import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared
    @StateObject private var videoFileManager = VideoFileManager.shared
    @StateObject private var videoScanner = iCloudVideoScanner.shared
    @State private var hasAttemptedAutoOpen = false
    
    var body: some Scene {
        WindowGroup {
            VStack {
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
                        } else if videoScanner.isScanning {
                            VStack(spacing: 10) {
                                Text("Restoring your video library...")
                                    .font(.headline)
                                
                                Text(videoScanner.scanStatusMessage)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                
                                if videoScanner.scanProgress > 0 {
                                    ProgressView(value: videoScanner.scanProgress)
                                        .frame(maxWidth: 300)
                                    Text("\(Int(videoScanner.scanProgress * 100))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            Text("Opening iCloud library...")
                                .font(.headline)
                        }
                        
                        if let error = libraryManager.error {
                            VStack(spacing: 15) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 50))
                                    .foregroundColor(.red)
                                
                                Text("Library Error")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                
                                Text(error.localizedDescription)
                                    .multilineTextAlignment(.center)
                                
                                if let recovery = error.recoverySuggestion {
                                    Text(recovery)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                
                                // Special handling for database corruption and invalid libraries  
                                switch error {
                                case .databaseCorrupted(_), .invalidLibrary(_):
                                    VStack(spacing: 10) {
                                        Text("Your library database is corrupted, but it can be fixed.")
                                            .font(.body)
                                            .multilineTextAlignment(.center)
                                            .foregroundColor(.primary)
                                        
                                        Text("This will create a fresh library. Your videos will remain in iCloud.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                        
                                        HStack(spacing: 10) {
                                            Button("Reset Library") {
                                                resetCorruptedLibrary()
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .foregroundColor(.white)
                                            .tint(.red)
                                            
                                            Button("Retry") {
                                                retryLibraryOpen()
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                default:
                                    Button("Retry") {
                                        retryLibraryOpen()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(30)
                            #if os(macOS)
                            .background(Color(.controlBackgroundColor))
                            #else
                            .background(Color(.systemGray6))
                            #endif
                            .cornerRadius(12)
                            .padding(.horizontal, 40)
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
                
                Divider()
                
                Button("Clean Up Temp Files") {
                    libraryManager.cleanupStaleDownloadsManually()
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
                
                Button("Reset Database (Debug)") {
                    resetCorruptedLibrary()
                }
                .keyboardShortcut("D", modifiers: [.command, .option, .shift])
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
                _ = try await libraryManager.smartStartup()
                print("✅ Successfully opened iCloud library")
            } catch {
                print("❌ Failed to get/create iCloud library: \(error)")
                // Set the error for UI display
                libraryManager.error = error as? LibraryError
            }
        }
    }
    
    private func retryLibraryOpen() {
        // Clear the error and try again
        libraryManager.error = nil
        hasAttemptedAutoOpen = false
        attemptAutoOpeniCloudLibrary()
    }
    
    private func resetCorruptedLibrary() {
        Task {
            do {
                libraryManager.error = nil
                print("🔧 APP: Starting database reset...")
                _ = try await libraryManager.resetCorruptedDatabase()
                print("✅ APP: Database reset successful")
            } catch {
                print("❌ APP: Database reset failed: \(error)")
                libraryManager.error = error as? LibraryError
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

