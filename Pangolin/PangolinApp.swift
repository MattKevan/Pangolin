// PangolinApp.swift

import SwiftUI
import Combine
import UniformTypeIdentifiers

@main
struct PangolinApp: App {
    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var videoFileManager = VideoFileManager.shared
    @State private var hasAttemptedAutoOpen = false
    @State private var showingNewLibraryPicker = false
    @State private var showingOpenLibraryPicker = false

    var body: some Scene {
        WindowGroup {
            VStack {
                if libraryManager.isLibraryOpen {
                    MainView(libraryManager: libraryManager)
                        .environmentObject(libraryManager)
                        .environmentObject(videoFileManager)
                } else {
                    LibraryPickerView()
                        .environmentObject(libraryManager)

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

                            switch error {
                            case .databaseCorrupted(_), .invalidLibrary(_):
                                VStack(spacing: 10) {
                                    Text("Your library database is corrupted, but it can be fixed.")
                                        .font(.body)
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(.primary)

                                    Text("This will create a fresh library.")
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
            }
            .frame(minWidth: 600, minHeight: 500)
            .onAppear {
                if !hasAttemptedAutoOpen {
                    attemptOpenLastLibrary()
                }
            }
            .fileExporter(
                isPresented: $showingNewLibraryPicker,
                document: LibraryDocument(),
                contentType: .pangolinLibrary,
                defaultFilename: "My Video Library"
            ) { result in
                handleNewLibraryCreation(result)
            }
            .fileImporter(
                isPresented: $showingOpenLibraryPicker,
                allowedContentTypes: [.pangolinLibrary]
            ) { result in
                handleOpenLibrarySelection(result)
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Library...") {
                    showNewLibraryPicker()
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])

                Button("Open Library...") {
                    showOpenLibraryPicker()
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])

                Divider()

                Button("Import Videos...") {
                    triggerImportDialog()
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
    }

    private func attemptOpenLastLibrary() {
        hasAttemptedAutoOpen = true

        Task {
            do {
                try await libraryManager.openLastLibrary()
            } catch {
                print("No last library found, showing picker")
            }
        }
    }

    private func retryLibraryOpen() {
        libraryManager.error = nil
        hasAttemptedAutoOpen = false
        attemptOpenLastLibrary()
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
        return libraryManager.isLibraryOpen
    }

    private func triggerSearch() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerSearch"), object: nil)
    }

    private func triggerRename() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerRename"), object: nil)
    }

    private func triggerImportDialog() {
        NotificationCenter.default.post(name: NSNotification.Name("TriggerImport"), object: nil)
    }

    private func showNewLibraryPicker() {
        showingNewLibraryPicker = true
    }

    private func showOpenLibraryPicker() {
        showingOpenLibraryPicker = true
    }

    private func handleNewLibraryCreation(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    let parentDirectory = url.deletingLastPathComponent()
                    let libraryName = url.deletingPathExtension().lastPathComponent
                    _ = try await libraryManager.createLibrary(at: parentDirectory, name: libraryName)
                    print("✅ Successfully created new library at: \(url.path)")
                } catch {
                    print("❌ Failed to create new library: \(error)")
                    libraryManager.error = error as? LibraryError
                }
            }
        case .failure(let error):
            print("❌ Library creation cancelled or failed: \(error)")
        }
    }

    private func handleOpenLibrarySelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    _ = try await libraryManager.openLibrary(at: url)
                    print("✅ Successfully opened library at: \(url.path)")
                } catch {
                    print("❌ Failed to open library: \(error)")
                    libraryManager.error = error as? LibraryError
                }
            }
        case .failure(let error):
            print("❌ Library opening cancelled or failed: \(error)")
        }
    }
}