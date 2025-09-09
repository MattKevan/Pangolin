// Views/MainView.swift

import SwiftUI
import CoreData

#if os(macOS)
import AppKit
#endif

private struct ToggleSidebarButton: View {
    var body: some View {
        Button {
            #if os(macOS)
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
            #endif
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .help("Show Sidebar")
    }
}

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var folderStore: FolderNavigationStore
    @State private var showInspector = false
    @State private var showingCreateFolder = false
    @State private var showingImportPicker = false
    
    @State private var searchText = ""
    
    init(libraryManager: LibraryManager) {
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
    }
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .environmentObject(folderStore)
                .applyManagedObjectContext(libraryManager.viewContext)
        } detail: {
            DetailView(video: folderStore.selectedVideo)
                .environmentObject(folderStore)
                .navigationSplitViewColumnWidth(min: 700, ideal: 900)
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                ToggleSidebarButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import Videos")
                .disabled(libraryManager.currentLibrary == nil)

                Button {
                    showingCreateFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Add Folder")
                .disabled(libraryManager.currentLibrary == nil)

                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show Inspector")
            }
            #else
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingImportPicker = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(libraryManager.currentLibrary == nil)

                Button {
                    showingCreateFolder = true
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "info.circle")
                }
            }
            #endif
        }
        .inspector(isPresented: $showInspector) {
            // Bound inspector width to avoid recursive constraint updates
            InspectorContainer {
                if let selected = folderStore.selectedVideo {
                    VideoDetailTabView(video: selected)
                        .environmentObject(libraryManager)
                } else {
                    ContentUnavailableView(
                        "No Video Selected",
                        systemImage: "sidebar.right",
                        description: Text("Select a video to view transcript, summary and info")
                    )
                }
            }
            .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.movie, .video, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleVideoImport(result)
        }
        .sheet(isPresented: $showingCreateFolder) {
            CreateFolderView(parentFolderID: folderStore.currentFolderID)
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
        .pangolinAlert(error: $libraryManager.error)
    }
    
    private func handleVideoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let library = libraryManager.currentLibrary, let context = libraryManager.viewContext {
                Task {
                    let importer = VideoImporter()
                    await importer.importFiles(urls, to: library, context: context)
                }
            }
        case .failure(let error):
            print("Error importing files: \(error)")
        }
    }
}

// MARK: - Inspector Container

private struct InspectorContainer<Content: View>: View {
    @ViewBuilder var content: Content
    
    var body: some View {
        // Keep a simple container; avoid forcing infinite size
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background {
            #if os(macOS)
            Color(NSColor.underPageBackgroundColor)
            #else
            Color(.tertiarySystemBackground)
            #endif
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
        }
    }
}

// MARK: - View Modifier helper to conditionally inject context

private extension View {
    @ViewBuilder
    func applyManagedObjectContext(_ context: NSManagedObjectContext?) -> some View {
        if let context {
            self.environment(\.managedObjectContext, context)
        } else {
            self
        }
    }
}
