import SwiftUI
import NaturalLanguage

struct SummaryView: View {
    @ObservedObject var video: Video
    @StateObject private var summaryService = SummaryService()
    @EnvironmentObject var libraryManager: LibraryManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Summary")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    if summaryService.isGenerating {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if video.transcriptSummary == nil {
                        Button("Generate Summary") {
                            Task {
                                await summaryService.generateSummary(for: video, libraryManager: libraryManager)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(video.transcriptText == nil)
                    } else {
                        Button("Regenerate") {
                            Task {
                                await summaryService.generateSummary(for: video, libraryManager: libraryManager)
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
                } else if summaryService.isGenerating {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.purple)
                            Text("Analyzing transcript...")
                                .font(.headline)
                        }
                        
                        ProgressView()
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        Text("Extracting key points and themes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                } else if let errorMessage = summaryService.errorMessage {
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
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                } else if let summary = video.transcriptSummary {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()
                        
                        ScrollView {
                            Text(summary)
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