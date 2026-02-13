// Views/MainView.swift

import SwiftUI
import CoreData

struct MainView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var folderStore: FolderNavigationStore
    @StateObject private var searchManager = SearchManager()
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    @StateObject private var taskQueueManager = TaskQueueManager.shared

    @State private var showingCreateFolder = false
    @State private var showTaskPopover = false
    @State private var selectedDetailTab: DetailContentTab = .transcript
    @State private var isInspectorPresented = true

    init(libraryManager: LibraryManager) {
        self._folderStore = StateObject(wrappedValue: FolderNavigationStore(libraryManager: libraryManager))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
                .environmentObject(folderStore)
                .environmentObject(libraryManager)
                .environmentObject(searchManager)
                .applyManagedObjectContext(libraryManager.viewContext)
        } detail: {
            DetailContentView(selectedTab: $selectedDetailTab)
                .environmentObject(folderStore)
                .environmentObject(searchManager)
                .environmentObject(libraryManager)
                .environmentObject(transcriptionService)
                .navigationSplitViewColumnWidth(min: 520, ideal: 900, max: nil)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    PlatformUtilities.selectVideosForImport { urls in
                        guard !urls.isEmpty else { return }
                        handleVideoImport(.success(urls))
                    }
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

            if folderStore.isSearchMode {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))

                        TextField("Search videos, transcripts, and summaries", text: $searchManager.searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 600)

                        Picker("Scope", selection: $searchManager.searchScope) {
                            ForEach(SearchManager.SearchScope.allCases) { scopeOption in
                                Text(scopeOption.rawValue).tag(scopeOption)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                ToolbarItemGroup(placement: .principal) {
                    toolbarTabButton(.transcript)
                    toolbarTabButton(.translation)
                    toolbarTabButton(.summary)
                    toolbarTabButton(.info)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if taskQueueManager.hasActiveTasks {
                    Button {
                        showTaskPopover.toggle()
                    } label: {
                        ZStack {
                            ProgressView(value: taskQueueManager.overallProgress)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .frame(width: 14, height: 14)

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
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Background tasks")
                        .accessibilityValue("\(taskQueueManager.activeTaskCount) active tasks")
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                        TaskQueuePopoverView()
                    }
                }

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            InspectorVideoPanel(video: folderStore.selectedVideo, allowOpenInNewWindow: true)
                .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
        }
        .onAppear {
            print("🏗️ MAINVIEW: MainView appeared")
        }
        .sheet(isPresented: $showingCreateFolder) {
            CreateFolderView(parentFolderID: nil)
                .environmentObject(folderStore)
        }
        .conditionalSearchable(
            isSearchMode: folderStore.isSearchMode,
            text: $searchManager.searchText,
            scope: $searchManager.searchScope
        )
        .navigationTitle("")
        .onChange(of: folderStore.selectedSidebarItem) { _, newSelection in
            if case .search = newSelection {
                searchManager.activateSearch()
            } else {
                searchManager.deactivateSearch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerSearch"))) { _ in
            folderStore.selectedSidebarItem = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerImport"))) { _ in
            PlatformUtilities.selectVideosForImport { urls in
                guard !urls.isEmpty else { return }
                handleVideoImport(.success(urls))
            }
        }
        .pangolinAlert(error: $libraryManager.error)
    }

    private func handleVideoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let libraryID = libraryManager.currentLibrary?.objectID,
                  let context = libraryManager.viewContext else { return }

            Task {
                let importer = VideoImporter()

                do {
                    let library = try context.existingObject(with: libraryID) as! Library
                    await importer.importFiles(urls, to: library, context: context)
                } catch {
                    print("❌ Failed to fetch library in context: \(error)")
                }
            }
        case .failure(let error):
            print("Error importing files: \(error)")
        }
    }

    @ViewBuilder
    private func toolbarTabButton(_ tab: DetailContentTab) -> some View {
        if selectedDetailTab == tab {
            Button {
                selectedDetailTab = tab
            } label: {
                Text(tab.toolbarTitle)
                    .lineLimit(1)
            }
            .buttonStyle(BorderedProminentButtonStyle())
            .controlSize(.small)
        } else {
            Button {
                selectedDetailTab = tab
            } label: {
                Text(tab.toolbarTitle)
                    .lineLimit(1)
            }
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.small)
        }
    }
}

private struct DetailContentView: View {
    @EnvironmentObject private var folderStore: FolderNavigationStore
    @EnvironmentObject private var searchManager: SearchManager
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var transcriptionService: SpeechTranscriptionService
    @Binding var selectedTab: DetailContentTab

    var body: some View {
        Group {
            if folderStore.isSearchMode {
                SearchResultsView()
                    .environmentObject(searchManager)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
            } else if let selectedVideo = folderStore.selectedVideo {
                DetailView(video: selectedVideo, selectedTab: $selectedTab)
                    .environmentObject(folderStore)
                    .environmentObject(libraryManager)
                    .environmentObject(transcriptionService)
            } else {
                ContentUnavailableView(
                    "No Video Selected",
                    systemImage: "video",
                    description: Text("Select a file from the sidebar tree.")
                )
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func applyManagedObjectContext(_ context: NSManagedObjectContext?) -> some View {
        if let context {
            self.environment(\.managedObjectContext, context)
        } else {
            self
        }
    }

    @ViewBuilder
    func conditionalSearchable(
        isSearchMode: Bool,
        text: Binding<String>,
        scope: Binding<SearchManager.SearchScope>
    ) -> some View {
        self
    }
}
