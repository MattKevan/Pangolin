import SwiftUI
import CoreData

struct TranscriptionView: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcript")
                    .font(.title2)
                    .fontWeight(.bold)

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
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            "No transcript available",
                            systemImage: "doc.text",
                            description: Text("Tap 'Transcribe' to create a transcript of this video's audio.")
                        )
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if let errorMessage = transcriptionErrorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("Transcription Error")
                                .font(.headline)
                        }

                        Text(errorMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                Spacer()
            }
            .padding()
        }
    }
    
    private func displayLanguageName(for languageIdentifier: String) -> String {
        return Locale.current.localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
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
