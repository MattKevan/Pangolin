import SwiftUI
import Speech

struct TranscriptionView: View {
    @ObservedObject var video: Video
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                            if let language = video.transcriptLanguage {
                                Label(language, systemImage: "globe")
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
    }
    
    private func parseTranscriptionError(from message: String) -> TranscriptionError? {
        // Simple parsing to extract error type from message
        // In a real implementation, you might want to pass the actual error object
        if message.contains("permission") {
            return .permissionDenied
        } else if message.contains("language") && message.contains("not supported") {
            return .languageNotSupported(Locale.current)
        } else if message.contains("SpeechTranscriber") && message.contains("not available") {
            return .speechTranscriberNotAvailable
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
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}