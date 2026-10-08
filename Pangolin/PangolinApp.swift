import os
// PangolinApp.swift

import SwiftUI
import Combine
import AppIntents

enum FileCommandPolicy {
    static let newProjectShortcut: KeyEquivalent = "n"
    static let importVideosShortcut: KeyEquivalent = "o"
}

@main
struct PangolinApp: App {
    @State private var libraryManager = LibraryManager.shared
    // Created once with the app; building it in MainView.init would allocate a new store on every re-render.
    @State private var folderStore = FolderNavigationStore(libraryManager: LibraryManager.shared)
    @State private var libraryActions = LibraryActions.shared
    @State private var videoFileManager = VideoFileManager.shared
    @State private var storagePolicyManager = StoragePolicyManager.shared
    @State private var hasAttemptedStartup = false

    private var mainContent: some View {
        MainView(
            libraryManager: libraryManager,
            folderStore: folderStore,
            isStartingUp: libraryManager.currentLibrary == nil && hasAttemptedStartup,
            startupError: libraryManager.error,
            startupLoadingProgress: libraryManager.loadingProgress,
            retryAction: retryLibraryOpen,
            resetAction: resetCorruptedLibrary
        )
        .environment(libraryManager)
        .environment(videoFileManager)
        .environment(libraryActions)
        .onAppear {
            if !hasAttemptedStartup {
                startLibraryStartup()
            }
        }
    }

    var body: some Scene {
        // One library and one window: the store and library state are app-wide, so a second
        // window would only mirror the first.
        #if os(macOS)
        Window("Pangolin", id: "main") {
            mainContent
        }
        .commands { appCommands }
        #else
        WindowGroup {
            mainContent
        }
        .commands { appCommands }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(libraryManager)
                .environment(storagePolicyManager)
                .environment(videoFileManager)
        }
        #endif
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                triggerCreateProject()
            }
            .keyboardShortcut(FileCommandPolicy.newProjectShortcut, modifiers: .command)
            .disabled(libraryManager.currentLibrary == nil)

            Button("Import Videos...") {
                triggerImportVideos()
            }
            .keyboardShortcut(FileCommandPolicy.importVideosShortcut, modifiers: .command)
            .disabled(libraryManager.currentLibrary == nil)

            #if os(macOS)
            Button("Reload Library") {
                retryLibraryOpen()
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])

            Divider()

            Button("Import from URL...") {
                triggerImportFromURL()
            }
            .keyboardShortcut("I", modifiers: [.command, .shift])
            .disabled(libraryManager.currentLibrary == nil)
            #endif
        }

        #if os(macOS)
        CommandMenu("Library") {
            LibraryActionsMenuContent(actions: libraryActions)

            Divider()

            SettingsLink {
                Text("Storage Settings…")
            }
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
        #endif
    }

    private func startLibraryStartup() {
        // Unit tests load the application bundle as their test host. Starting the
        // production library here would also start Core Data's CloudKit mirroring
        // before XCTest has finished bootstrapping.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            hasAttemptedStartup = true
            return
        }

        hasAttemptedStartup = true
        ThumbnailImageCache.startObservingMemoryPressure()

        Task {
            do {
                let library = try await libraryManager.smartStartup()
                await StoragePolicyManager.shared.scheduleAutomaticPolicyApply(for: library)
            } catch {
                Logger.app.error("APP: Startup failed: \(error)")
                libraryManager.error = (error as? LibraryError) ?? .unexpected(error)
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
                Logger.app.warning("APP: Starting database reset...")
                _ = try await libraryManager.resetCorruptedDatabase()
                Logger.app.info("APP: Database reset successful")
            } catch {
                Logger.app.error("APP: Database reset failed: \(error)")
                libraryManager.error = (error as? LibraryError) ?? .unexpected(error)
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

    private func triggerCreateProject() {
        NotificationCenter.default.post(name: .triggerCreateFolder, object: nil)
    }

    private func triggerImportFromURL() {
        NotificationCenter.default.post(name: .triggerImportFromURL, object: nil)
    }
}
