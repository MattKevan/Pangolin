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
        WindowGroup {
            ZStack {
                MainView(libraryManager: libraryManager)
                    .environmentObject(libraryManager)
                    .environmentObject(videoFileManager)
                    .allowsHitTesting(libraryManager.isLibraryOpen)

                if !libraryManager.isLibraryOpen {
                    StartupOverlayView(
                        error: libraryManager.error,
                        loadingProgress: libraryManager.loadingProgress,
                        retryAction: retryLibraryOpen,
                        resetAction: resetCorruptedLibrary
                    )
                    .transition(.opacity)
                }
            }
            .frame(minWidth: 600, minHeight: 500)
            .animation(.easeOut(duration: 0.2), value: libraryManager.isLibraryOpen)
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
                .environmentObject(videoFileManager)
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

private struct StartupOverlayView: View {
    let error: LibraryError?
    let loadingProgress: Double
    let retryAction: () -> Void
    let resetAction: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            StartupStatusView(
                error: error,
                loadingProgress: loadingProgress,
                retryAction: retryAction,
                resetAction: resetAction
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 28, x: 0, y: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(true)
    }
}

private struct StartupStatusView: View {
    let error: LibraryError?
    let loadingProgress: Double
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

                if loadingProgress > 0 {
                    ProgressView(value: min(max(loadingProgress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}
