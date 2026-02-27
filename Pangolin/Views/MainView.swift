// Views/MainView.swift

import SwiftUI
import CoreData

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var videoFileManager: VideoFileManager
    @StateObject private var folderStore: FolderNavigationStore
    @StateObject private var searchManager = SearchManager()
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared
    
    @State private var showingImportPicker = false
    @State private var showingURLImportSheet = false
    
    // Popover state for task indicator
    @State private var showTaskPopover = false
    @State private var isSearchFieldPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    
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
            showingImportPicker: $showingImportPicker,
            showingURLImportSheet: $showingURLImportSheet,
            handleAutoTranscribe: handleAutoTranscribe,
            handleVideoImport: handleVideoImport,
            handleURLImport: handleURLImport
        )
    }

    private var rootNavigationSplitView: some View {
        NavigationSplitView {
            sidebarColumn
        } detail: {
            detailColumn
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

    private var detailColumn: some View {
        configuredDetailColumn
    }

    @ViewBuilder
    private var configuredDetailColumn: some View {
        let baseDetailColumn = DetailColumnView()
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
                            Image(systemName: "video.badge.plus")
                        }
                        .help("Import videos")
                        .disabled(libraryManager.currentLibrary == nil)

                        Button {
                            showingURLImportSheet = true
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                        .help("Import from URL")
                        .disabled(libraryManager.currentLibrary == nil)
                    }

                    // Trailing actions
                    ToolbarItemGroup(placement: .primaryAction) {
                        // Task Queue Progress Indicator
                        if processingQueueManager.visibleActiveTaskCount > 0 || processingQueueManager.failedTasks > 0 || videoFileManager.failedTransferCount > 0 {
                            Button {
                                showTaskPopover.toggle()
                            } label: {
                                let hasActiveTasks = processingQueueManager.visibleActiveTaskCount > 0
                                let failedProcessingCount = processingQueueManager.failedTasks
                                let transferIssueCount = videoFileManager.failedTransferCount
                                let nonActiveIssueCount = transferIssueCount + failedProcessingCount
                                let badgeCount = nonActiveIssueCount > 0 ? nonActiveIssueCount : max(0, processingQueueManager.visibleActiveTaskCount - 1)

                                ZStack(alignment: .topTrailing) {
                                    if hasActiveTasks {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: 16, height: 16)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 3)
                                    } else {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 3)
                                    }

                                    if badgeCount > 0 {
                                        Text("\(min(badgeCount, 99))")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 12, height: 12)
                                            .background(Color.red)
                                            .clipShape(Circle())
                                            .offset(x: 4, y: -2)
                                    }
                                }
                                .frame(minWidth: 24, minHeight: 22, alignment: .center)
                                .contentShape(Rectangle())
                                .accessibilityLabel("Background tasks")
                                .accessibilityValue("\(processingQueueManager.visibleActiveTaskCount) active tasks, \(processingQueueManager.failedTasks) failed tasks, \(videoFileManager.failedTransferCount) transfer issues")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                                ProcessingPopoverView(processingManager: processingQueueManager)
                            }
                        }
                    }
                }
            }
            .onChange(of: folderStore.isSearchMode) { _, isSearchMode in
                isSearchFieldPresented = isSearchMode
                if isSearchMode {
                    DispatchQueue.main.async {
                        isSearchFieldFocused = true
                    }
                } else {
                    isSearchFieldFocused = false
                }
            }
            .onChange(of: searchManager.searchText) { _, _ in
                guard folderStore.isSearchMode else { return }
                // Keep the search field active while results/search state updates
                // re-render the detail column as the user types.
                Task { @MainActor in
                    isSearchFieldFocused = true
                }
            }

        if folderStore.isSearchMode {
            baseDetailColumn
                .searchable(
                    text: $searchManager.searchText,
                    isPresented: $isSearchFieldPresented,
                    placement: .toolbarPrincipal,
                    prompt: "Search videos, transcripts, and summaries"
                )
                .searchFocused($isSearchFieldFocused)
                .onSubmit(of: .search) {
                    guard folderStore.isSearchMode else { return }
                    let trimmedQuery = searchManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedQuery.isEmpty else { return }
                    searchManager.performManualSearch()
                }
        } else {
            baseDetailColumn
        }
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

    private func handleURLImport(_ url: URL) async throws {
        guard let library = libraryManager.currentLibrary, let context = libraryManager.viewContext else {
            throw FileSystemError.invalidLibraryPath
        }
        try await processingQueueManager.enqueueRemoteImport(url: url, library: library, context: context)
    }
}

private struct RootContainerView<Content: View>: View {
    let content: Content
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleAutoTranscribe: () -> Void
    let handleVideoImport: (Result<[URL], Error>) -> Void
    let handleURLImport: (URL) async throws -> Void
    
    var body: some View {
        content
            .modifier(RootImportModifier(
                showingImportPicker: $showingImportPicker,
                showingURLImportSheet: $showingURLImportSheet,
                handleVideoImport: handleVideoImport,
                handleURLImport: handleURLImport
            ))
            .modifier(RootEventsModifier(
                folderStore: folderStore,
                searchManager: searchManager,
                libraryManager: libraryManager,
                showingImportPicker: $showingImportPicker,
                showingURLImportSheet: $showingURLImportSheet,
                handleAutoTranscribe: handleAutoTranscribe
            ))
            .modifier(RootAlertModifier(libraryManager: libraryManager))
    }
}

private struct RootImportModifier: ViewModifier {
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleVideoImport: (Result<[URL], Error>) -> Void
    let handleURLImport: (URL) async throws -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.movie, .video, .folder],
                allowsMultipleSelection: true
            ) { result in
                handleVideoImport(result)
            }
            .sheet(isPresented: $showingURLImportSheet) {
                ImportFromURLSheet(onImport: handleURLImport)
            }
    }
}

private struct RootEventsModifier: ViewModifier {
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
    @Binding var showingURLImportSheet: Bool
    let handleAutoTranscribe: () -> Void

    func body(content: Content) -> some View {
        let configuredContent = content
            .navigationTitle(folderStore.isSearchMode ? "" : (folderStore.selectedVideo?.title ?? libraryManager.currentLibrary?.name ?? "Pangolin"))
            .onAppear {
                StoragePolicyManager.shared.setProtectedSelectedVideoID(folderStore.selectedVideo?.id)
                handleAutoTranscribe()
            }
            .onChange(of: folderStore.selectedVideo?.id) { _, newVideoID in
                StoragePolicyManager.shared.setProtectedSelectedVideoID(newVideoID)
                handleAutoTranscribe()
            }
            .onChange(of: folderStore.selectedSidebarItem) { _, newSelection in
                if case .search = newSelection {
                    searchManager.activateSearch()
                } else {
                    searchManager.deactivateSearch()
                }
            }
        configuredContent
            .onReceive(NotificationCenter.default.publisher(for: .triggerSearch)) { _ in
                // Activate search mode when Cmd+F is pressed
                folderStore.selectedSidebarItem = .search
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerImportVideos)) { _ in
                showingImportPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerImportFromURL)) { _ in
                showingURLImportSheet = true
            }
    }
}

private struct RootAlertModifier: ViewModifier {
    @ObservedObject var libraryManager: LibraryManager

    @ViewBuilder
    func body(content: Content) -> some View {
        if libraryManager.isLibraryOpen {
            content.pangolinAlert(error: $libraryManager.error)
        } else {
            content
        }
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
            switch folderStore.currentDetailSurface {
            case .searchResults:
                SearchResultsView()
                    .environmentObject(searchManager)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            case .smartCollectionTable(_):
                FolderContentView()
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            case .videoDetail:
                if let selectedVideo = folderStore.selectedVideo {
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
            case .empty:
                ContentUnavailableView(
                    "No video selected",
                    systemImage: "video",
                    description: Text("Select a video to view details.")
                )
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
