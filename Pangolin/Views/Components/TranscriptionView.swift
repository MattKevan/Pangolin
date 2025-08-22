import SwiftUI
import Speech
#if os(macOS)
import AppKit
#endif

struct TranscriptionView: View {
    @ObservedObject var video: Video
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    // Use system current locale as the initial selection for speech recognition language
    @State var selectedLocale: Locale = Locale.current
    @State private var supportedLocales: [Locale] = []
    @State private var showTranslation = false
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Language", selection: $selectedLocale) {
                    // Use the beta SpeechTranscriber.supportedLocales
                    ForEach(supportedLocales.sorted(by: { Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier < Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier }), id: \.self) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale as Locale)
                    }
                }
                .pickerStyle(.menu)
                .padding(.bottom, 4)
                .labelsHidden()
                
                HStack {
                    Text("Transcript")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    if transcriptionService.isTranscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if video.transcriptText == nil {
                        Button("Generate Transcript") {
                            Task {
                                await transcriptionService.transcribeVideo(video, libraryManager: libraryManager)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Regenerate") {
                            Task {
                                await transcriptionService.transcribeVideo(video, libraryManager: libraryManager)
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        if video.translatedText == nil {
                            Button("Translate") {
                                Task {
                                    await transcriptionService.translateVideo(video, libraryManager: libraryManager)
                                }
                            }
                            .buttonStyle(.bordered)
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
                        
                        // Show recovery suggestion if available
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
                            // Show "Open Settings" button for translation model errors
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
                                    await transcriptionService.transcribeVideo(video, libraryManager: libraryManager)
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
                            
                            // Translation toggle if both transcript and translation exist
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
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                        .padding()
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                } else if !transcriptionService.isTranscribing && transcriptionService.errorMessage == nil {
                    ContentUnavailableView(
                        "No Transcript Available",
                        systemImage: "doc.text",
                        description: Text("Tap 'Generate Transcript' to create a transcript of this video's audio.")
                    )
                }
                
                Spacer()
            }
            .padding()
        }
        .task {
            // Load supported locales using the beta API
            supportedLocales = await Array(SpeechTranscriber.supportedLocales)
        }
    }
    
    private func displayLanguageName(for languageIdentifier: String) -> String {
        return Locale.current.localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
    }
    
    private func openTranslationSettings() {
        #if os(macOS)
        // Open System Settings to Language & Region section
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(settingsURL)
        } else {
            // Fallback to general System Settings
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
        #endif
    }
    
    private func parseTranscriptionError(from message: String) -> TranscriptionError? {
        // Simple parsing to extract error type from message
        // In a real implementation, you might want to pass the actual error object
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
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
