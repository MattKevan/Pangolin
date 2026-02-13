import SwiftUI
import Speech
#if os(macOS)
import AppKit
#endif
import CoreData

struct TranscriptionView: View {
    @ObservedObject var video: Video
    @EnvironmentObject var transcriptionService: SpeechTranscriptionService
    @EnvironmentObject var libraryManager: LibraryManager
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
    // Source (input) language selection: nil means Auto Detect
    @State private var inputSelection: Locale? = nil
    @State private var supportedLocales: [Locale] = []
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                
                // Language Controls
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        // Input picker (Auto Detect + supported locales)
                        Menu {
                            // Auto Detect option
                            Button {
                                inputSelection = nil // Auto Detect
                            } label: {
                                HStack {
                                    Label("Auto Detect", systemImage: "sparkles")
                                    Spacer()
                                    if inputSelection == nil {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            Divider()
                            ForEach(sortedSupportedLocales, id: \.identifier) { locale in
                                Button {
                                    inputSelection = locale
                                } label: {
                                    HStack {
                                        Text(displayName(for: locale))
                                        Spacer()
                                        if inputSelection?.identifier == locale.identifier {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("Language")
                                    .foregroundStyle(.secondary)
                                Text(inputSelectionLabel)
                                    .fontWeight(.medium)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .disabled(supportedLocales.isEmpty)
                        .help("Choose the source language. Auto Detect uses a short sample to detect it.")
                    }
                }
                .padding(.bottom, 4)
                
                HStack {
                    Text("Transcript")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                     if video.transcriptText == nil {
                        Button("Transcribe") {
                            processingQueueManager.enqueueTranscription(for: [video], preferredLocale: inputSelection)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(supportedLocales.isEmpty || isTranscriptionRunningForVideo)
                    } else {
                        Button("Regenerate") {
                            processingQueueManager.enqueueTranscription(for: [video], preferredLocale: inputSelection, force: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTranscriptionRunningForVideo)
                    }
                }
            
                
                
            
            
                if isTranscriptionRunningForVideo {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let transcriptText = video.transcriptText {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if let language = video.transcriptLanguage {
                                Label(displayLanguageName(for: language), systemImage: "globe")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if let dateGenerated = video.transcriptDateGenerated {
                                Text("Generated \(dateGenerated, formatter: DateFormatter.shortDate)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        ScrollView {
                            Text(transcriptText)
                                .font(.system(size: 17))
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 720, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.horizontal, 12)
                        }
                    }
                } else if !isTranscribing && transcriptionErrorMessage == nil {
                    ContentUnavailableView(
                        "No transcript available",
                        systemImage: "doc.text",
                        description: Text("Tap 'Transcribe' to create a transcript of this video's audio.")
                    )
                    .font(.title3)
                    .multilineTextAlignment(.leading)
                }
                
                Spacer()
            }
            .padding()
        }
        .task {
            // Load supported locales using the beta API
            let locales = await Array(SpeechTranscriber.supportedLocales)
            await MainActor.run {
                supportedLocales = locales
            }
            // Initialize Input picker:
            // If this video already has a detected language, map it to a supported Locale; else Auto Detect (nil)
            if let langID = video.transcriptLanguage {
                if let matched = locales.first(where: { $0.identifier == langID }) {
                    inputSelection = matched
                } else if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: langID)),
                          locales.contains(where: { $0.identifier == equivalent.identifier }) {
                    inputSelection = equivalent
                } else {
                    inputSelection = nil // Auto
                }
            } else {
                inputSelection = nil // Auto
            }
        }
    }
    
    // MARK: - Helpers
    
    private var sortedSupportedLocales: [Locale] {
        supportedLocales.sorted { lhs, rhs in
            let ln = displayName(for: lhs)
            let rn = displayName(for: rhs)
            return ln < rn
        }
    }
    
    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
    
    private var inputSelectionLabel: String {
        if let inputSelection {
            return displayName(for: inputSelection)
        } else {
            return "Auto Detect"
        }
    }
    
    private func displayLanguageName(for languageIdentifier: String) -> String {
        return Locale.current.localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
    }
    
    private func parseTranscriptionError(from message: String) -> TranscriptionError? {
        if message.contains("permission") {
            return .permissionDenied
        } else if message.contains("language") && message.contains("not supported") {
            return .languageNotSupported(Locale.current)
        } else if message.contains("SpeechTranscriber") && message.contains("not available") {
            return .analysisFailed("SpeechTranscriber not available")
        } else if message.contains("extract audio") {
            return .audioExtractionFailed
        } else if message.contains("locate the video file") {
            return .videoFileNotFound
        } else if message.contains("No speech was detected") {
            return .noSpeechDetected
        } else if message.contains("download") && message.contains("assets") {
            return .assetInstallationFailed
        }
        return nil
    }
    
    private func syncInputPickerToDetectedLanguage() {
        // After a successful transcription, align the input picker with the detected language
        guard let langID = video.transcriptLanguage, !langID.isEmpty else { return }
        if let matched = supportedLocales.first(where: { $0.identifier == langID }) {
            inputSelection = matched
        }
    }

    private var transcriptionTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .transcribe)
    }

    private var isTranscriptionRunningForVideo: Bool {
        transcriptionTask?.status == .processing
    }

    private var isTranscribing: Bool {
        transcriptionTask?.status.isActive == true
    }

    private var transcriptionErrorMessage: String? {
        transcriptionTask?.errorMessage
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Previews (PreviewProvider fallback for older toolchains)

#if DEBUG
private extension LibraryManager {
    // Debug-only helper to set the current library for previews
    func setPreviewCurrentLibrary(_ library: Library) {
        self.currentLibrary = library
        self.isLibraryOpen = true
    }
}
#endif

struct TranscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        // In-memory Core Data stack for preview
        let model = NSManagedObjectModel.mergedModel(from: [Bundle.main]) ?? NSManagedObjectModel()
        let container = NSPersistentContainer(name: "Library", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores(completionHandler: { _, error in
            if let error = error {
                print("Preview store load error: \(error)")
            }
        })
        let context = container.viewContext
        
        // Minimal Library + Video
        let libraryEntity = NSEntityDescription.entity(forEntityName: "Library", in: context)!
        let videoEntity = NSEntityDescription.entity(forEntityName: "Video", in: context)!
        
        let library = Library(entity: libraryEntity, insertInto: context)
        library.id = UUID()
        library.name = "Preview Library"
        library.libraryPath = FileManager.default.temporaryDirectory.path
        library.createdDate = Date()
        library.lastOpenedDate = Date()
        library.version = "1.0.0"
        
        let video = Video(entity: videoEntity, insertInto: context)
        video.id = UUID()
        video.title = "Sample Talk: Swift Concurrency Deep Dive"
        video.relativePath = "sample.mov"
        video.dateAdded = Date()
        video.duration = 3605
        video.fileSize = 123_456_789
        video.transcriptText = """
        Welcome to the Swift Concurrency deep dive. In this session, we'll explore async/await, actors, \
        and structured concurrency. We'll start with the basics and move to advanced patterns...
        """
        video.transcriptLanguage = "en-US"
        video.transcriptDateGenerated = Date()
        
        // Shared service
        let transcriptionService = SpeechTranscriptionService()
        
        // LibraryManager environment
        let libraryManager = LibraryManager.shared
        #if DEBUG
        libraryManager.setPreviewCurrentLibrary(library)
        #endif
        
        return TranscriptionView(video: video)
            .environmentObject(libraryManager)
            .environmentObject(transcriptionService)
            .frame(minWidth: 600, minHeight: 500)
            .previewDisplayName("TranscriptionView")
    }
}
