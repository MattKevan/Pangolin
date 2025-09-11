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
                        // Native circular ProgressView indicator (service-only), hidden when idle
                        if isAnyTaskActive {
                            Button {
                                showTaskPopover.toggle()
                            } label: {
                                ZStack {
                                    if currentProgress > 0 && currentProgress < 1 {
                                        ProgressView(value: currentProgress)
                                            .progressViewStyle(.circular)
                                            .controlSize(.small)
                                            .frame(width: 14, height: 14)
                                    } else {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .controlSize(.small)
                                            .frame(width: 14, height: 14)
                                    }
                                }
                                .frame(width: 20, height: 20) // hit target
                                .accessibilityLabel(currentTaskTitle)
                                .accessibilityValue("\(Int(currentProgress * 100)) percent")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showTaskPopover, arrowEdge: .top) {
                                TaskPopoverView(
                                    title: currentTaskTitle,
                                    message: transcriptionService.statusMessage,
                                    progress: currentProgress
                                )
                                .padding()
                                .frame(minWidth: 240)
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
            CreateFolderView(parentFolderID: folderStore.currentFolderID)
        }
        .navigationTitle(libraryManager.currentLibrary?.name ?? "Pangolin")
        .pangolinAlert(error: $libraryManager.error)
    }
    
    // MARK: - Indicator logic (service-only)
    
    private var isAnyTaskActive: Bool {
        transcriptionService.isTranscribing || transcriptionService.isSummarizing
    }
    
    private var currentProgress: Double {
        min(max(transcriptionService.progress, 0.0), 1.0)
    }
    
    private var currentTaskTitle: String {
        if transcriptionService.isSummarizing {
            return "Summary"
        } else {
            let lower = transcriptionService.statusMessage.lowercased()
            if lower.contains("translat") {
                return "Translation"
            }
            return "Transcription"
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
                    let importer = VideoImporter()
                    await importer.importFiles(urls, to: library, context: context)
                }
            }
        case .failure(let error):
            print("Error importing files: \(error)")
        }
    }
}

// MARK: - Task Popover

private struct TaskPopoverView: View {
    let title: String
    let message: String
    let progress: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.headline)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            HStack {
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var iconName: String {
        switch title {
        case "Summary": return "doc.text.below.ecg"
        case "Translation": return "globe.badge.chevron.backward"
        default: return "waveform"
        }
    }
    
    private var iconColor: Color {
        switch title {
        case "Summary": return .purple
        case "Translation": return .green
        default: return .blue
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
