// PangolinApp.swift

import SwiftUI
import Combine

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var videoFileManager = VideoFileManager.shared
    @StateObject private var storagePolicyManager = StoragePolicyManager.shared
    @State private var hasAttemptedStartup = false

    var body: some Scene {
        WindowGroup {
            VStack {
                if libraryManager.isLibraryOpen {
                    MainView(libraryManager: libraryManager)
                        .environmentObject(libraryManager)
                        .environmentObject(videoFileManager)
                } else {
                    StartupStatusView(
                        error: libraryManager.error,
                        retryAction: retryLibraryOpen,
                        resetAction: resetCorruptedLibrary
                    )
                }
            }
            .frame(minWidth: 600, minHeight: 500)
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
                .disabled(!libraryManager.isLibraryOpen)
            }

            CommandGroup(after: .undoRedo) {
                Button("Search") {
                    triggerSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!libraryManager.isLibraryOpen)

                Divider()

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
        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(libraryManager)
                .environmentObject(storagePolicyManager)
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

    private func hasRenameableSelection() -> Bool {
        return libraryManager.isLibraryOpen
    }

    private func triggerSearch() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerSearch"), object: nil)
    }

    private func triggerRename() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerRename"), object: nil)
    }
    
    private func triggerImportVideos() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerImportVideos"), object: nil)
    }
}

private struct StartupStatusView: View {
    let error: LibraryError?
    let retryAction: () -> Void
    let resetAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.red)

                Text("Couldn’t Open Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(error.localizedDescription)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                if let recovery = error.recoverySuggestion {
                    Text(recovery)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Retry", action: retryAction)
                        .buttonStyle(.borderedProminent)

                    if case .databaseCorrupted = error {
                        Button("Reset Library", action: resetAction)
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing iCloud Library…")
                    .font(.headline)
                Text("Setting up your cloud-backed library in Documents/Pangolin.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}
