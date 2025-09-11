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
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    
    @State private var showInspector = false
    @State private var showingCreateFolder = false
    @State private var showingImportPicker = false
    
    @State private var searchText = ""
    @State private var selectedInspectorTab: InspectorTab = .transcript
    
    // Prevent duplicate auto-triggers during rapid selection changes
    @State private var isAutoTranscribing = false
    
    // Processing UI
    @State private var showingProcessingPanel = false
    
    // Observe the global processing queue
    @StateObject private var processingQueueManager = ProcessingQueueManager.shared

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
                    // Leading actions
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
                        // Show when queue has active tasks OR service is doing ad-hoc work; hide when complete.
                        if showProcessingIndicator {
                            CircularProgressButton(
                                progress: indicatorProgress,
                                activeTaskCount: indicatorActiveCount,
                                processingManager: processingQueueManager,
                                onViewAllTapped: {
                                    showingProcessingPanel = true
                                }
                            )
                            .frame(width: 24, height: 24)
                            .accessibilityLabel("Processing")
                            .accessibilityValue("\(Int(indicatorProgress * 100)) percent")
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
                .onChange(of: folderStore.selectedVideo) { _, newVideo in
                    guard let video = newVideo else { return }
                    // Only auto-trigger if there's no transcript yet and we're not already busy
                    if video.transcriptText == nil && !transcriptionService.isTranscribing && !isAutoTranscribing {
                        isAutoTranscribing = true
                        Task {
                            await transcriptionService.transcribeVideo(video, libraryManager: libraryManager)
                            await MainActor.run { isAutoTranscribing = false }
                        }
                    }
                }
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
        .sheet(isPresented: $showingProcessingPanel) {
            BulkProcessingView(
                processingManager: processingQueueManager,
                isPresented: $showingProcessingPanel
            )
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
        .pangolinAlert(error: $libraryManager.error)
    }
    
    // MARK: - Indicator logic (queue + ad-hoc service)
    
    private var showProcessingIndicator: Bool {
        (processingQueueManager.activeTasks > 0) ||
        transcriptionService.isTranscribing ||
        transcriptionService.isSummarizing
    }
    
    private var indicatorProgress: Double {
        if processingQueueManager.activeTasks > 0 {
            return processingQueueManager.overallProgress
        } else {
            return min(max(transcriptionService.progress, 0.0), 1.0)
        }
    }
    
    private var indicatorActiveCount: Int {
        if processingQueueManager.activeTasks > 0 {
            return processingQueueManager.activeTasks
        } else if transcriptionService.isTranscribing || transcriptionService.isSummarizing {
            return 1
        } else {
            return 0
        }
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
