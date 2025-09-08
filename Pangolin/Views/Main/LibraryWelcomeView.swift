//
//  LibraryWelcomeView.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryWelcomeView: View {
    @Binding var showLibrarySelector: Bool
    @Binding var showCreateLibrary: Bool
    @EnvironmentObject var libraryManager: LibraryManager
    
    // Local UI state for pickers/errors
    @State private var showingErrorAlert = false
    @State private var errorMessage: String = ""
    
    // iOS/iPadOS picker state
    @State private var showingCreateFolderPicker = false
    @State private var showingOpenLibraryPicker = false
    @State private var pickedCreateParentURL: URL?
    @State private var showingNamePrompt = false
    @State private var newLibraryName: String = "New Library"
    
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)
            
            Text("Welcome to Pangolin")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Your personal video library manager")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(spacing: 16) {
                Button(action: { createNewLibraryFlow() }) {
                    Label("Create New Library", systemImage: "plus.square")
                        .frame(width: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                
                Button(action: { openExistingLibraryFlow() }) {
                    Label("Open Existing Library", systemImage: "folder")
                        .frame(width: 200)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                
                if !libraryManager.recentLibraries.isEmpty {
                    Divider()
                        .frame(width: 200)
                    
                    VStack(alignment: .leading) {
                        Text("Recent Libraries")
                            .font(.headline)
                        
                        ForEach(libraryManager.recentLibraries.prefix(3)) { library in
                            Button(action: {
                                Task { @MainActor in
                                    do {
                                        _ = try await libraryManager.openLibrary(at: library.path)
                                    } catch {
                                        presentError(error)
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                    VStack(alignment: .leading) {
                                        Text(library.name)
                                            .font(.body)
                                        Text(library.path.path)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!library.isAvailable)
                        }
                    }
                }
            }
        }
        .padding(50)
        .frame(minWidth: 600, minHeight: 500)
        .alert("Library Error", isPresented: $showingErrorAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
        // iOS/iPadOS: pick a parent folder to create a library
        .fileImporter(isPresented: $showingCreateFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let parent = urls.first {
                    pickedCreateParentURL = parent
                    newLibraryName = "New Library"
                    showingNamePrompt = true
                }
            case .failure(let error):
                presentError(error)
            }
        }
        // iOS/iPadOS: pick an existing .pangolin library (a package directory)
        .fileImporter(isPresented: $showingOpenLibraryPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Validate extension
                    if url.pathExtension.lowercased() == "pangolin" {
                        Task { @MainActor in
                            do {
                                _ = try await libraryManager.openLibrary(at: url)
                            } catch {
                                presentError(error)
                            }
                        }
                    } else {
                        errorMessage = "Please select a Pangolin library (a folder ending with .pangolin)."
                        showingErrorAlert = true
                    }
                }
            case .failure(let error):
                presentError(error)
            }
        }
        // iOS/iPadOS: Name prompt for creating a library
        .sheet(isPresented: $showingNamePrompt) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Library Name")
                        .font(.headline)
                    TextField("Name", text: $newLibraryName)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit {
                            submitCreateOnIOS()
                        }
                    Spacer()
                }
                .padding()
                .navigationTitle("Create Library")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingNamePrompt = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            submitCreateOnIOS()
                        }
                        .disabled(newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
    
    // MARK: - Flows
    
    private func createNewLibraryFlow() {
        #if os(macOS)
        // Use NSSavePanel so the user can name the .pangolin package and pick its location
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["pangolin"]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Create New Pangolin Library"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "New Library.pangolin"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Derive parent directory and library name (without extension)
            let parent = url.deletingLastPathComponent()
            let suggestedName = url.deletingPathExtension().lastPathComponent
            
            Task { @MainActor in
                do {
                    _ = try await libraryManager.createLibrary(at: parent, name: suggestedName)
                } catch {
                    presentError(error)
                }
            }
        }
        #else
        // iOS/iPadOS: choose a parent folder, then prompt for a name
        showingCreateFolderPicker = true
        #endif
    }
    
    private func openExistingLibraryFlow() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["pangolin"]
        panel.title = "Open Pangolin Library"
        panel.prompt = "Open"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    _ = try await libraryManager.openLibrary(at: url)
                } catch {
                    presentError(error)
                }
            }
        }
        #else
        // iOS/iPadOS: pick a folder and ensure it ends with .pangolin
        showingOpenLibraryPicker = true
        #endif
    }
    
    // MARK: - iOS Create Submit
    
    private func submitCreateOnIOS() {
        let name = newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let parent = pickedCreateParentURL else {
            showingNamePrompt = false
            return
        }
        showingNamePrompt = false
        Task { @MainActor in
            do {
                _ = try await libraryManager.createLibrary(at: parent, name: name)
            } catch {
                presentError(error)
            }
        }
    }
    
    // MARK: - Error Handling
    
    private func presentError(_ error: Error) {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            errorMessage = description
        } else {
            errorMessage = error.localizedDescription
        }
        showingErrorAlert = true
    }
}

#if os(macOS)
import AppKit
#endif
