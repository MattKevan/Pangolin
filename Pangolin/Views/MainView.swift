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
    @StateObject private var searchManager = SearchManager()
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared
    
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingCreateFolder = false
    @State private var showingImportPicker = false
    
    // Prevent duplicate auto-triggers during rapid selection changes
    @State private var isAutoTranscribing = false
    
    // Popover state for task indicator
    @State private var showTaskPopover = false
    
    init(libraryManager: LibraryManager) {
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
    }
    
    var body: some View { rootView }

    private var transcriptionService: SpeechTranscriptionService {
        processingQueueManager.transcriptionService
    }

    private var rootView: some View {
        RootContainerView(
            content: rootNavigationSplitView,
            folderStore: folderStore,
            searchManager: searchManager,
            libraryManager: libraryManager,
            transcriptionService: processingQueueManager.transcriptionService,
            processingQueueManager: processingQueueManager,
            showingImportPicker: $showingImportPicker,
            showingCreateFolder: $showingCreateFolder,
            showTaskPopover: $showTaskPopover,
            updateColumnVisibility: updateColumnVisibility,
            handleAutoTranscribe: handleAutoTranscribe,
            handleVideoImport: handleVideoImport
        )
    }

    private var rootNavigationSplitView: some View {
        if isTwoColumnMode {
            return AnyView(
                NavigationSplitView {
                    sidebarColumn
                } detail: {
                    twoColumnDetail
                }
            )
        } else {
            return AnyView(
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarColumn
                } content: {
                    contentColumn
                } detail: {
                    detailColumn
                }
            )
        }
    }

    private var sidebarColumn: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
            .environmentObject(folderStore)
            .environmentObject(libraryManager)
            .environmentObject(searchManager)
            .applyManagedObjectContext(libraryManager.viewContext)
    }

    private var contentColumn: some View {
        ContentColumnView(isTwoColumnMode: isTwoColumnMode)
            .environmentObject(folderStore)
            .environmentObject(searchManager)
            .environmentObject(libraryManager)
            .navigationSplitViewColumnWidth(
                min: isTwoColumnMode ? 0 : 260,
                ideal: isTwoColumnMode ? 0 : 380,
                max: isTwoColumnMode ? 0 : 800
            )
    }

    private var twoColumnDetail: some View {
        DetailColumnView()
            .environmentObject(folderStore)
            .environmentObject(searchManager)
            .environmentObject(libraryManager)
            .environmentObject(transcriptionService)
            .navigationSplitViewColumnWidth(min: 420, ideal: 760)
    }

    private var detailColumn: some View {
        DetailColumnView()
            .environmentObject(folderStore)
            .environmentObject(searchManager)
            .environmentObject(libraryManager)
            .environmentObject(transcriptionService)
            .navigationSplitViewColumnWidth(min: 420, ideal: 760)
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
                        if processingQueueManager.activeTaskCount > 0 {
                            Button {
                                showTaskPopover.toggle()
                            } label: {
                                ZStack {
                                    ProgressView(value: processingQueueManager.overallProgress)
                                        .progressViewStyle(.circular)
                                        .controlSize(.small)
                                        .frame(width: 14, height: 14)

                                    // Badge showing number of active tasks
                                    if processingQueueManager.activeTaskCount > 1 {
                                        Text("\(processingQueueManager.activeTaskCount)")
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
                                .accessibilityValue("\(processingQueueManager.activeTaskCount) active tasks")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                                ProcessingPopoverView(processingManager: processingQueueManager)
                            }
                        }
                    }
                }
            }
            // Removed auto-transcribe on selection change. Transcription must be user-initiated.
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
                    await processingQueueManager.enqueueImport(urls: urls, library: library, context: context)
                }
            }
        case .failure(let error):
            print("Error importing files: \(error)")
        }
    }

    private func handleAutoTranscribe() {
        guard let video = folderStore.selectedVideo else { return }
        guard !hasTranscript(video) else { return }
        guard libraryManager.currentLibrary != nil else { return }
        processingQueueManager.enqueueTranscription(for: [video])
    }
    
    private func updateColumnVisibility() {
        columnVisibility = isTwoColumnMode ? .doubleColumn : .all
    }
    
    private var isTwoColumnMode: Bool {
        if folderStore.selectedVideo != nil { return false }
        if folderStore.isSearchMode { return true }
        guard let folder = folderStore.selectedTopLevelFolder else { return false }
        if folder.isSmartFolder,
           let name = folder.name,
           ["All Videos", "Recent", "Favorites"].contains(name) {
            return true
        }
        return false
    }
    
}

private struct RootContainerView<Content: View>: View {
    let content: Content
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    @ObservedObject var transcriptionService: SpeechTranscriptionService
    @ObservedObject var processingQueueManager: ProcessingQueueManager
    @Binding var showingImportPicker: Bool
    @Binding var showingCreateFolder: Bool
    @Binding var showTaskPopover: Bool
    let updateColumnVisibility: () -> Void
    let handleAutoTranscribe: () -> Void
    let handleVideoImport: (Result<[URL], Error>) -> Void
    
    var body: some View {
        content
            .modifier(RootImportModifier(
                folderStore: folderStore,
                showingImportPicker: $showingImportPicker,
                showingCreateFolder: $showingCreateFolder,
                handleVideoImport: handleVideoImport
            ))
            .modifier(RootSearchModifier(
                folderStore: folderStore,
                searchManager: searchManager
            ))
            .modifier(RootEventsModifier(
                folderStore: folderStore,
                searchManager: searchManager,
                libraryManager: libraryManager,
                updateColumnVisibility: updateColumnVisibility,
                handleAutoTranscribe: handleAutoTranscribe
            ))
            .modifier(RootAlertModifier(libraryManager: libraryManager))
    }
}

private struct RootImportModifier: ViewModifier {
    @ObservedObject var folderStore: FolderNavigationStore
    @Binding var showingImportPicker: Bool
    @Binding var showingCreateFolder: Bool
    let handleVideoImport: (Result<[URL], Error>) -> Void

    func body(content: Content) -> some View {
        content
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
    }
}

private struct RootSearchModifier: ViewModifier {
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager

    func body(content: Content) -> some View {
        content
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
    }
}

private struct RootEventsModifier: ViewModifier {
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    let updateColumnVisibility: () -> Void
    let handleAutoTranscribe: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(folderStore.selectedVideo?.title ?? libraryManager.currentLibrary?.name ?? "Pangolin")
            .onAppear(perform: updateColumnVisibility)
            .onChange(of: folderStore.isSearchMode) { _, _ in updateColumnVisibility() }
            .onChange(of: folderStore.selectedTopLevelFolder?.id) { _, _ in updateColumnVisibility() }
            .onChange(of: folderStore.selectedVideo?.id) { _, _ in updateColumnVisibility() }
            .onChange(of: folderStore.selectedVideo?.id) { _, _ in
                handleAutoTranscribe()
            }
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
    }
}

private struct RootAlertModifier: ViewModifier {
    @ObservedObject var libraryManager: LibraryManager

    func body(content: Content) -> some View {
        content.pangolinAlert(error: $libraryManager.error)
    }
}


// MARK: - Content Column View
private struct ContentColumnView: View {
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var libraryManager: LibraryManager
    let isTwoColumnMode: Bool

    var body: some View {
        Group {
            if isTwoColumnMode {
                EmptyView()
            } else {
                // Normal Mode: Show folder content list
                FolderContentView()
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            }
        }
        .frame(minWidth: isTwoColumnMode ? 0 : nil, maxWidth: isTwoColumnMode ? 0 : nil)
    }
}

// MARK: - Detail Column View
private struct DetailColumnView: View {
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService

    var body: some View {
        Group {
            if isTwoColumnMode {
                if folderStore.isSearchMode {
                    SearchResultsView()
                        .environmentObject(searchManager)
                        .environmentObject(folderStore)
                        .environmentObject(libraryManager)
                } else {
                    FolderContentView()
                        .environmentObject(folderStore)
                        .environmentObject(libraryManager)
                }
            } else if let selectedVideo = folderStore.selectedVideo {
                DetailView(video: selectedVideo)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
            } else {
                ContentUnavailableView(
                    "No video selected",
                    systemImage: "video",
                    description: Text("Select a video to view details.")
                )
            }
        }
    }
    
    private var isTwoColumnMode: Bool {
        if folderStore.selectedVideo != nil { return false }
        if folderStore.isSearchMode { return true }
        guard let folder = folderStore.selectedTopLevelFolder else { return false }
        if folder.isSmartFolder,
           let name = folder.name,
           ["All Videos", "Recent", "Favorites"].contains(name) {
            return true
        }
        return false
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
