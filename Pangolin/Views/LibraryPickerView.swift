//
//  LibraryPickerView.swift
//  Pangolin
//
//  Simple view for creating or opening a library on first launch
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryPickerView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var showingCreatePicker = false
    @State private var showingOpenPicker = false

    var body: some View {
        VStack(spacing: 30) {
            // App icon and title
            VStack(spacing: 16) {
                Image(systemName: "video.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)

                Text("Welcome to Pangolin")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Choose how to get started with your video library")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Action buttons
            VStack(spacing: 16) {
                Button(action: {
                    showingCreatePicker = true
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Create New Library")
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    showingOpenPicker = true
                }) {
                    HStack {
                        Image(systemName: "folder.fill")
                        Text("Open Existing Library")
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Help text
            VStack(spacing: 8) {
                Text("Library files are saved as .pangolin packages")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("All your videos, thumbnails, and data are stored inside the library for easy backup and sharing")
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 400)
        .fileExporter(
            isPresented: $showingCreatePicker,
            document: LibraryDocument(),
            contentType: .pangolinLibrary,
            defaultFilename: "My Video Library"
        ) { result in
            handleCreateLibrary(result)
        }
        .fileImporter(
            isPresented: $showingOpenPicker,
            allowedContentTypes: [.pangolinLibrary]
        ) { result in
            handleOpenLibrary(result)
        }
    }

    private func handleCreateLibrary(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    let parentDirectory = url.deletingLastPathComponent()
                    let libraryName = url.deletingPathExtension().lastPathComponent
                    _ = try await libraryManager.createLibrary(at: parentDirectory, name: libraryName)
                } catch {
                    print("❌ Failed to create library: \(error)")
                    libraryManager.error = error as? LibraryError
                }
            }
        case .failure(let error):
            print("❌ Library creation cancelled: \(error)")
        }
    }

    private func handleOpenLibrary(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                do {
                    _ = try await libraryManager.openLibrary(at: url)
                } catch {
                    print("❌ Failed to open library: \(error)")
                    libraryManager.error = error as? LibraryError
                }
            }
        case .failure(let error):
            print("❌ Library opening cancelled: \(error)")
        }
    }
}



#Preview {
    LibraryPickerView()
        .environmentObject(LibraryManager.shared)
}