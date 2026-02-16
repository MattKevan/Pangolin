import SwiftUI
import MarkdownUI

struct SummaryView: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Summary")
                    .font(.title2)
                    .fontWeight(.bold)

                content
            }
            .padding()
        }
    }

    @ViewBuilder
    private var content: some View {
        if video.transcriptText == nil && video.translatedText == nil {
            VStack {
                Spacer(minLength: 0)
                ContentUnavailableView(
                    "Transcript Required",
                    systemImage: "doc.text.below.ecg",
                    description: Text("A transcript is required to generate a summary. Go to the Transcript tab and generate one first.")
                )
                .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if isSummarizing {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.purple)
                    Text("Generating summary...")
                        .font(.headline)
                }

                ProgressView(value: summaryProgress)
                    .progressViewStyle(.linear)

                Text("Using Apple Intelligence to create a comprehensive summary")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
            #else
            .background(.regularMaterial)
            #endif
            .cornerRadius(8)
        } else if let errorMessage = summaryErrorMessage {
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

                Markdown(summary)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    #if os(macOS)
                    .background(Color(NSColor.textBackgroundColor))
                    #else
                    .background(Color(UIColor.systemBackground))
                    #endif
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
        } else {
            VStack {
                Spacer(minLength: 0)
                ContentUnavailableView(
                    "No Summary Available",
                    systemImage: "doc.text.below.ecg",
                    description: Text("Use the controls inspector to generate a summary.")
                )
                .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private var summaryTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .summarize)
    }

    private var isSummarizing: Bool {
        summaryTask?.status.isActive == true
    }

    private var summaryProgress: Double {
        summaryTask?.progress ?? 0.0
    }

    private var summaryErrorMessage: String? {
        summaryTask?.errorMessage
    }
}
