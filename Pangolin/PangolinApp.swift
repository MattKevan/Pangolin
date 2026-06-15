// PangolinApp.swift

import SwiftUI
import Combine
import AppIntents

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var videoFileManager = VideoFileManager.shared
    @StateObject private var storagePolicyManager = StoragePolicyManager.shared
    @State private var hasAttemptedStartup = false

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MainView(
                libraryManager: libraryManager,
                isStartingUp: libraryManager.currentLibrary == nil && hasAttemptedStartup,
                startupError: libraryManager.error,
                startupLoadingProgress: libraryManager.loadingProgress,
                retryAction: retryLibraryOpen,
                resetAction: resetCorruptedLibrary
            )
            .environmentObject(libraryManager)
            .environmentObject(videoFileManager)
            .onAppear {
                if !hasAttemptedStartup {
                    startLibraryStartup()
                }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload Library") {
                    retryLibraryOpen()
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])

                Divider()

                Button("Import Videos...") {
                    triggerImportVideos()
                }
                .keyboardShortcut("I", modifiers: .command)
                .disabled(libraryManager.currentLibrary == nil)

                Button("Import from URL...") {
                    triggerImportFromURL()
                }
                .keyboardShortcut("I", modifiers: [.command, .shift])
                .disabled(libraryManager.currentLibrary == nil)
            }

            CommandGroup(after: .undoRedo) {
                Button("Search") {
                    triggerSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(libraryManager.currentLibrary == nil)

                Divider()

                Button("Rename") {
                    triggerRename()
                }
                .keyboardShortcut(.return)
                .disabled(libraryManager.currentLibrary == nil)
            }

            CommandMenu("Video") {
                Button("Generate Thumbnails") {
                    generateThumbnails()
                }
                .disabled(libraryManager.currentLibrary == nil)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(libraryManager)
                .environmentObject(storagePolicyManager)
                .environmentObject(videoFileManager)
        }
        #else
        WindowGroup {
            MainView(
                libraryManager: libraryManager,
                isStartingUp: libraryManager.currentLibrary == nil && hasAttemptedStartup,
                startupError: libraryManager.error,
                startupLoadingProgress: libraryManager.loadingProgress,
                retryAction: retryLibraryOpen,
                resetAction: resetCorruptedLibrary
            )
            .environmentObject(libraryManager)
            .environmentObject(videoFileManager)
            .onAppear {
                if !hasAttemptedStartup {
                    startLibraryStartup()
                }
            }
        }
        #endif
    }

    private func startLibraryStartup() {
        hasAttemptedStartup = true

        Task {
            do {
                let library = try await libraryManager.smartStartup()
                await storagePolicyManager.applyPolicy(for: library)
            } catch {
                print("❌ APP: Startup failed: \(error)")
                libraryManager.error = error as? LibraryError
            }
        }
    }

    private func retryLibraryOpen() {
        libraryManager.error = nil
        hasAttemptedStartup = false
        startLibraryStartup()
    }

    private func resetCorruptedLibrary() {
        Task {
            do {
                libraryManager.error = nil
                print("🔧 APP: Starting database reset...")
                let library = try await libraryManager.resetCorruptedDatabase()
                await storagePolicyManager.applyPolicy(for: library)
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

        Task { @MainActor in
            let request = Video.fetchRequest()
            request.predicate = NSPredicate(format: "library == %@", library)
            let videos = (try? context.fetch(request)) ?? []
            ProcessingQueueManager.shared.enqueueThumbnails(for: videos, force: true)
        }
    }

    private func triggerSearch() {
        NotificationCenter.default.post(name: .triggerSearch, object: nil)
    }

    private func triggerRename() {
        NotificationCenter.default.post(name: .triggerRename, object: nil)
    }
    
    private func triggerImportVideos() {
        NotificationCenter.default.post(name: .triggerImportVideos, object: nil)
    }

    private func triggerImportFromURL() {
        NotificationCenter.default.post(name: .triggerImportFromURL, object: nil)
    }
}
