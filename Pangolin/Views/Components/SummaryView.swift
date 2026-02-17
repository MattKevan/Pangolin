import SwiftUI
import MarkdownUI

struct SummaryView: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                

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
                    "Transcript required",
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
           
            .cornerRadius(8)
        } else if let errorMessage = summaryErrorMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Summary error")
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
                

                Markdown(summary)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    
            }
        } else {
            VStack {
                Spacer(minLength: 0)
                ContentUnavailableView(
                    "No summary available",
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
