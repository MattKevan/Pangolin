// Views/MainView.swift

import SwiftUI
import CoreData

#if os(macOS)
import AppKit
#endif

// MARK: - Inspector Tab Definition

private enum InspectorTab: CaseIterable, Hashable {
    case transcript
    case translation
    case summary
    case info
    
    var title: String {
        switch self {
        case .transcript: return "Transcript"
        case .translation: return "Translation"
        case .summary: return "Summary"
        case .info: return "Info"
        }
    }
    
    var systemImage: String {
        switch self {
        case .transcript: return "doc.text"
        case .translation: return "globe.badge.chevron.backward"
        case .summary: return "doc.text.below.ecg"
        case .info: return "info.circle"
        }
    }
}

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
    @StateObject private var searchManager = SearchManager()
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    @StateObject private var taskQueueManager = TaskQueueManager.shared
    
    @State private var showInspector = false
    @State private var showingCreateFolder = false
    @State private var showingImportPicker = false
    
    @State private var selectedInspectorTab: InspectorTab = .transcript
    
    // Prevent duplicate auto-triggers during rapid selection changes
    @State private var isAutoTranscribing = false
    
    // Popover state for task indicator
    @State private var showTaskPopover = false
    
    init(libraryManager: LibraryManager) {
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
    }
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .environmentObject(folderStore)
                .environmentObject(libraryManager)
                .environmentObject(searchManager)
                .applyManagedObjectContext(libraryManager.viewContext)
        } detail: {
            DetailContentView()
                .environmentObject(folderStore)
                .environmentObject(searchManager)
                .environmentObject(libraryManager)
                .navigationSplitViewColumnWidth(min: 700, ideal: 900)
                .toolbar {
                    if !folderStore.isSearchMode {
                        // Normal Mode: Standard toolbar items
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
                        
                        // Trailing actions
                        ToolbarItemGroup(placement: .primaryAction) {
                            // Task Queue Progress Indicator
                            if taskQueueManager.hasActiveTasks {
                                Button {
                                    showTaskPopover.toggle()
                                } label: {
                                    ZStack {
                                        ProgressView(value: taskQueueManager.overallProgress)
                                            .progressViewStyle(.circular)
                                            .controlSize(.small)
                                            .frame(width: 14, height: 14)
                                        
                                        // Badge showing number of active tasks
                                        if taskQueueManager.activeTaskCount > 1 {
                                            Text("\(taskQueueManager.activeTaskCount)")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.white)
                                                .frame(width: 12, height: 12)
                                                .background(Color.red)
                                                .clipShape(Circle())
                                                .offset(x: 6, y: -6)
                                        }
                                    }
                                    .frame(width: 20, height: 20) // hit target
                                    .accessibilityLabel("Background tasks")
                                    .accessibilityValue("\(taskQueueManager.activeTaskCount) active tasks")
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                                    TaskQueuePopoverView()
                                }
                            }
                            
                            
                            
                            Button {
                                showInspector.toggle()
                            } label: {
                                Image(systemName: "sidebar.right")
                            }
                            .keyboardShortcut("i", modifiers: [.command, .option])
                            .help("Show Inspector")
                        }
                    }
                }
                .inspector(isPresented: $showInspector) {
                    InspectorContainer {
                        Picker("Inspector Section", selection: $selectedInspectorTab) {
                            ForEach(InspectorTab.allCases, id: \.self) { tab in
                                Label(tab.title, systemImage: tab.systemImage).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.horizontal, 8)
                        .labelsHidden()
                    } content: {
                        if let selected = folderStore.selectedVideo {
                            switch selectedInspectorTab {
                            case .transcript:
                                TranscriptionView(video: selected)
                                    .environmentObject(libraryManager)
                                    .environmentObject(transcriptionService)
                                    .background(.clear)
                            case .translation:
                                TranslationView(video: selected)
                                    .environmentObject(libraryManager)
                                    .environmentObject(transcriptionService)
                                    .background(.clear)
                            case .summary:
                                SummaryView(video: selected)
                                    .environmentObject(libraryManager)
                                    .environmentObject(transcriptionService)
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
                // Removed auto-transcribe on selection change. Transcription must be user-initiated.
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.movie, .video, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleVideoImport(result)
        }
        .sheet(isPresented: $showingCreateFolder) {
            CreateFolderView(parentFolderID: nil) // Always create top-level user folders
                .environmentObject(folderStore)
        }
        .searchable(
            text: $searchManager.searchText,
            isPresented: .constant(folderStore.isSearchMode),
            placement: .automatic,
            prompt: "Search videos, transcripts, and summaries"
        )
        .searchScopes($searchManager.searchScope) {
            ForEach(SearchManager.SearchScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
        .onChange(of: folderStore.selectedSidebarItem) { _, newSelection in
            if case .search = newSelection {
                searchManager.activateSearch()
            } else {
                searchManager.deactivateSearch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerSearch"))) { _ in
            // Activate search mode when Cmd+F is pressed
            folderStore.selectedSidebarItem = .search
        }
        .pangolinAlert(error: $libraryManager.error)
    }
    
    
    private func hasTranscript(_ video: Video) -> Bool {
        if let t = video.transcriptText {
            return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
    
    // MARK: - Helpers
    
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
        VStack(spacing: 0) {
            // Full-width toolbar area
            VStack(spacing: 0) {
                toolbarContent
                    .padding(.vertical, 8)
            }
            
            // Content area with padding
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
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
        }
    }
}

// MARK: - Detail Content View
private struct DetailContentView: View {
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var libraryManager: LibraryManager

    var body: some View {
        Group {
            if folderStore.isSearchMode {
                // Search Mode: Always show search results view
                SearchResultsView()
                    .environmentObject(searchManager)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            } else {
                // Normal Mode: Show regular detail view or hierarchical content
                if let selectedVideo = folderStore.selectedVideo {
                    DetailView(video: selectedVideo)
                        .environmentObject(folderStore)
                        .environmentObject(libraryManager)
                } else {
                    HierarchicalContentView(searchText: "")
                        .environmentObject(folderStore)
                        .environmentObject(libraryManager)
                }
            }
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
