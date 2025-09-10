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
            // Toggles the sidebar in the current window
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
            #endif
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .help("Toggle Sidebar")
    }
}

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var folderStore: FolderNavigationStore
    @State private var showInspector = false
    @State private var showingCreateFolder = false
    @State private var showingImportPicker = false
    
    @State private var searchText = ""
    @State private var selectedInspectorTab: InspectorTab = .transcript

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
                .toolbar {
                   
                    // Your primary actions, grouped together.
                    ToolbarItemGroup(placement: .navigation) {
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
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showInspector.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help("Show Inspector")
                    }
                }
                .inspector(isPresented: $showInspector) {
                    // Call the new InspectorContainer with two trailing closures
                    InspectorContainer {
                        // This is the first closure: toolbarContent
                        Picker("Inspector Section", selection: $selectedInspectorTab) {
                            ForEach(InspectorTab.allCases, id: \.self) { tab in
                                Label(tab.title, systemImage: tab.systemImage).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity)

                        .labelsHidden()
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        
                    } content: {
                        // This is the second closure: content
                        if let selected = folderStore.selectedVideo {
                            switch selectedInspectorTab {
                            case .transcript:
                                TranscriptionView(video: selected)
                                    .environmentObject(libraryManager)
                                    .background(.clear)
                            case .summary:
                                SummaryView(video: selected)
                                    .environmentObject(libraryManager)
                                    .background(.clear)
                            case .info:
                                VideoInfoView(video: selected)
                                    .environmentObject(libraryManager)
                                    .background(.clear)
                            }
                        } else {
                            ContentUnavailableView(
                                "No Video Selected",
                                systemImage: "sidebar.right",
                                description: Text("Select a video to view transcript, summary and info")
                            )
                            .background(.clear)
                        }
                    }
                    .inspectorColumnWidth(min: 280, ideal: 400, max: 600)
                }
        }
        // Modifiers that apply to the whole view, like fileImporter and sheet, can remain here.
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

// MARK: - Inspector Container and other helpers

private struct InspectorContainer<ToolbarContent: View, Content: View>: View {
    @ViewBuilder var toolbarContent: ToolbarContent
    @ViewBuilder var content: Content
    
    var body: some View {
        // Main VStack for the entire inspector
        VStack(spacing: 0) {
            // A dedicated area for the toolbar content (the Picker)
            VStack(spacing: 0) {
                toolbarContent
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                
                // A subtle divider line below the toolbar
                //Divider()
            }
            
            // The main content area
            content
                .padding(.horizontal, 8)
                .padding(.top, 8)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(.regularMaterial)
        #else
        .background(Color(.tertiarySystemBackground))
        #endif
        // The side overlay remains the same
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
