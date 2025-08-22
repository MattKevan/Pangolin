import SwiftUI
import FoundationModels
#if os(macOS)
import AppKit
#endif

struct SummaryView: View {
    @ObservedObject var video: Video
    @StateObject private var transcriptionService = SpeechTranscriptionService()
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Summary")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    if transcriptionService.isSummarizing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if video.transcriptSummary == nil {
                        Button("Generate Summary") {
                            Task {
                                await transcriptionService.summarizeVideo(video, libraryManager: libraryManager)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(video.transcriptText == nil && video.translatedText == nil)
                    } else {
                        Button("Regenerate") {
                            Task {
                                await transcriptionService.summarizeVideo(video, libraryManager: libraryManager)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                if video.transcriptText == nil {
                    ContentUnavailableView(
                        "Transcript Required",
                        systemImage: "doc.text.below.ecg",
                        description: Text("A transcript is required to generate a summary. Go to the Transcript tab and generate one first.")
                    )
                } else if transcriptionService.isSummarizing {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.purple)
                            Text("Generating summary...")
                                .font(.headline)
                        }
                        
                        ProgressView()
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        Text("Using Apple Intelligence to create a comprehensive summary")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                } else if let errorMessage = transcriptionService.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Summary Error")
                                .font(.headline)
                        }
                        
                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        if errorMessage.contains("Apple Intelligence") {
                            Button("Open System Settings") {
                                #if os(macOS)
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppleIntelligence") {
                                    NSWorkspace.shared.open(url)
                                }
                                #endif
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 8)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                } else if let summary = video.transcriptSummary {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Summary")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if let summaryDate = video.summaryDateGenerated {
                                Text("Generated \(summaryDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        ScrollView {
                            Text(.init(summary))
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(maxHeight: 400)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No Summary Available",
                        systemImage: "doc.text.below.ecg",
                        description: Text("Tap 'Generate Summary' to create a summary of this video's transcript.")
                    )
                }
                
                Spacer()
            }
            .padding()
        }
    }
}