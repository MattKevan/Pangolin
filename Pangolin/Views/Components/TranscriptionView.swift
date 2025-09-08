import SwiftUI
import Speech
#if os(macOS)
import AppKit
#endif
import CoreData

struct TranscriptionView: View {
    @ObservedObject var video: Video
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    
    // Source (input) language selection: nil means Auto Detect
    @State private var inputSelection: Locale? = nil
    // Target (output) language selection
    @State private var outputSelection: Locale? = nil
    
    // Back-compat: keep the existing single selectedLocale for now (not used anymore for control)
    @State var selectedLocale: Locale = Locale.current
    
    @State private var supportedLocales: [Locale] = []
    @State private var showTranslation = false
    @EnvironmentObject var libraryManager: LibraryManager
    
    // Cache the system-equivalent supported locale once loaded
    @State private var systemSupportedLocale: Locale? = nil
    
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
                                Text("Input")
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
                        
                        // Output picker (System + supported locales)
                        Menu {
                            if let systemLocale = systemSupportedLocale {
                                Button {
                                    outputSelection = systemLocale
                                } label: {
                                    HStack {
                                        Text("System")
                                        Spacer()
                                        if outputSelection?.identifier == systemLocale.identifier {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                Divider()
                            }
                            ForEach(sortedSupportedLocales, id: \.identifier) { locale in
                                Button {
                                    outputSelection = locale
                                } label: {
                                    HStack {
                                        Text(displayName(for: locale))
                                        Spacer()
                                        if outputSelection?.identifier == locale.identifier {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("Output")
                                    .foregroundStyle(.secondary)
                                Text(outputSelectionLabel)
                                    .fontWeight(.medium)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .disabled(supportedLocales.isEmpty)
                        .help("Choose the translation target language.")
                    }
                }
                .padding(.bottom, 4)
                
                HStack {
                    Text("Transcript")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    if transcriptionService.isTranscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if video.transcriptText == nil {
                        Button("Transcribe") {
                            Task {
                                await transcriptionService.transcribeVideo(video, libraryManager: libraryManager, preferredLocale: inputSelection)
                                // After transcription, reflect detected language into the input picker
                                syncInputPickerToDetectedLanguage()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(supportedLocales.isEmpty)
                    } else {
                        Button("Regenerate") {
                            Task {
                                await transcriptionService.transcribeVideo(video, libraryManager: libraryManager, preferredLocale: inputSelection)
                                syncInputPickerToDetectedLanguage()
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        if video.translatedText == nil {
                            Button("Translate") {
                                Task {
                                    let targetLanguage = outputSelection?.language
                                    await transcriptionService.translateVideo(video, libraryManager: libraryManager, targetLanguage: targetLanguage)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(outputSelection == nil)
                        }
                    }
                }
            
                if transcriptionService.isTranscribing {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(.blue)
                            Text("Transcribing audio...")
                                .font(.headline)
                        }
                        
                        ProgressView(value: transcriptionService.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        Text(transcriptionService.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                if let errorMessage = transcriptionService.errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Transcription Error")
                                .font(.headline)
                        }
                        
                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        if let error = parseTranscriptionError(from: errorMessage),
                           let suggestion = error.recoverySuggestion {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("💡 Suggestion:")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            if let error = parseTranscriptionError(from: errorMessage),
                               case .translationModelsNotInstalled = error {
                                Button("Open System Settings") {
                                    openTranslationSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            Spacer()
                            Button("Try Again") {
                                Task {
                                    await transcriptionService.transcribeVideo(video, libraryManager: libraryManager, preferredLocale: inputSelection)
                                    syncInputPickerToDetectedLanguage()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            
                if let transcriptText = video.transcriptText {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if let language = showTranslation ? video.translatedLanguage : video.transcriptLanguage {
                                Label(displayLanguageName(for: language), systemImage: "globe")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if video.transcriptText != nil && video.translatedText != nil {
                                Picker("View", selection: $showTranslation) {
                                    Text("Original").tag(false)
                                    Text("Translation").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 140)
                            }
                            
                            if let dateGenerated = showTranslation ? video.translationDateGenerated : video.transcriptDateGenerated {
                                Text("Generated \(dateGenerated, formatter: DateFormatter.shortDate)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        ScrollView {
                            Text(showTranslation && video.translatedText != nil ? video.translatedText! : transcriptText)
                                .id(showTranslation ? "translation" : "original")
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if !transcriptionService.isTranscribing && transcriptionService.errorMessage == nil {
                    // Center the empty state and make the title smaller
                    VStack {
                        ContentUnavailableView(
                            "No transcript available",
                            systemImage: "doc.text",
                            description: Text("Tap 'Generate Transcript' to create a transcript of this video's audio.")
                        )
                        .font(.title3) // smaller than default title
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
            // Initialize Output picker to a supported equivalent of the system locale
            if let systemEquivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current),
               locales.contains(where: { $0.identifier == systemEquivalent.identifier }) {
                await MainActor.run {
                    systemSupportedLocale = systemEquivalent
                    outputSelection = systemEquivalent
                }
            } else {
                await MainActor.run {
                    systemSupportedLocale = nil
                    outputSelection = locales.first
                }
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
    
    private var outputSelectionLabel: String {
        if let outputSelection {
            if let systemLocale = systemSupportedLocale,
               outputSelection.identifier == systemLocale.identifier {
                return "System"
            }
            return displayName(for: outputSelection)
        } else if systemSupportedLocale != nil {
            return "System"
        } else {
            return "—"
        }
    }
    
    private func displayLanguageName(for languageIdentifier: String) -> String {
        return Locale.current.localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
    }
    
    private func openTranslationSettings() {
        #if os(macOS)
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(settingsURL)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
        #endif
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
        } else if message.contains("Translation models") && message.contains("not installed") {
            return .translationModelsNotInstalled("", "")
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
        Welcome to the Swift Concurrency deep dive. In this session, we’ll explore async/await, actors, \
        and structured concurrency. We’ll start with the basics and move to advanced patterns...
        """
        video.transcriptLanguage = "en-US"
        video.transcriptDateGenerated = Date()
        
        // LibraryManager environment
        let libraryManager = LibraryManager.shared
        #if DEBUG
        libraryManager.setPreviewCurrentLibrary(library)
        #endif
        
        return TranscriptionView(video: video)
            .environmentObject(libraryManager)
            .frame(minWidth: 600, minHeight: 500)
            .previewDisplayName("TranscriptionView")
    }
}
