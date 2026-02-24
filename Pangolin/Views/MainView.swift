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
    @EnvironmentObject var videoFileManager: VideoFileManager
    @StateObject private var folderStore: FolderNavigationStore
    @StateObject private var searchManager = SearchManager()
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared
    
    @State private var showingImportPicker = false
    
    // Popover state for task indicator
    @State private var showTaskPopover = false
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
            handleAutoTranscribe: handleAutoTranscribe,
            handleVideoImport: handleVideoImport
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
        DetailColumnView()
            .environmentObject(folderStore)
            .environmentObject(searchManager)
            .environmentObject(libraryManager)
            .environmentObject(transcriptionService)
            .navigationSplitViewColumnWidth(min: 420, ideal: 760)
            .toolbar {
                if folderStore.isSearchMode {
                    ToolbarItem(placement: .navigation) {
                        ToggleSidebarButton()
                    }

                    ToolbarItem(placement: .principal) {
                        TextField("Search videos, transcripts, and summaries", text: $searchManager.searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 320, idealWidth: 460, maxWidth: 640)
                            .focused($isSearchFieldFocused)
                            .onSubmit {
                                let trimmedQuery = searchManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmedQuery.isEmpty else { return }
                                if folderStore.selectedSidebarItem != .search {
                                    folderStore.selectedSidebarItem = .search
                                }
                                searchManager.performManualSearch()
                            }
                    }
                } else {
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
                            NotificationCenter.default.post(name: .triggerCreateFolder, object: nil)
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .help("Add Folder")
                        .disabled(libraryManager.currentLibrary == nil)
                    }

                    // Trailing actions
                    ToolbarItemGroup(placement: .primaryAction) {
                        // Task Queue Progress Indicator
                        if processingQueueManager.activeTaskCount > 0 || videoFileManager.failedTransferCount > 0 {
                            Button {
                                showTaskPopover.toggle()
                            } label: {
                                let hasActiveTasks = processingQueueManager.activeTaskCount > 0
                                let transferIssueCount = videoFileManager.failedTransferCount
                                let badgeCount = transferIssueCount > 0 ? transferIssueCount : max(0, processingQueueManager.activeTaskCount - 1)

                                ZStack(alignment: .topTrailing) {
                                    if hasActiveTasks {
                                        ZStack {
                                            Circle()
                                                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                                                .frame(width: 16, height: 16)

                                            Circle()
                                                .trim(from: 0, to: max(0.02, min(1.0, processingQueueManager.overallProgress)))
                                                .stroke(
                                                    Color.accentColor,
                                                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                                )
                                                .rotationEffect(.degrees(-90))
                                                .frame(width: 16, height: 16)
                                        }
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
                                .accessibilityValue("\(processingQueueManager.activeTaskCount) active tasks, \(videoFileManager.failedTransferCount) transfer issues")
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
                if isSearchMode {
                    DispatchQueue.main.async {
                        isSearchFieldFocused = true
                    }
                } else {
                    isSearchFieldFocused = false
                }
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
}

private struct RootContainerView<Content: View>: View {
    let content: Content
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
    let handleAutoTranscribe: () -> Void
    let handleVideoImport: (Result<[URL], Error>) -> Void
    
    var body: some View {
        content
            .modifier(RootImportModifier(
                showingImportPicker: $showingImportPicker,
                handleVideoImport: handleVideoImport
            ))
            .modifier(RootEventsModifier(
                folderStore: folderStore,
                searchManager: searchManager,
                libraryManager: libraryManager,
                showingImportPicker: $showingImportPicker,
                handleAutoTranscribe: handleAutoTranscribe
            ))
            .modifier(RootAlertModifier(libraryManager: libraryManager))
    }
}

private struct RootImportModifier: ViewModifier {
    @Binding var showingImportPicker: Bool
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
    }
}

private struct RootEventsModifier: ViewModifier {
    @ObservedObject var folderStore: FolderNavigationStore
    @ObservedObject var searchManager: SearchManager
    @ObservedObject var libraryManager: LibraryManager
    @Binding var showingImportPicker: Bool
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
            if folderStore.isSearchMode {
                SearchResultsView()
                    .environmentObject(searchManager)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            } else if isShowingSmartFolderContent {
                FolderContentView()
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
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

    private var isShowingSmartFolderContent: Bool {
        guard let folder = folderStore.currentFolder else { return false }
        return folder.isSmartFolder
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
