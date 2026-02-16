import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SummaryControlsInspectorPane: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var didCopyRendered = false
    @State private var didCopyMarkdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary Controls")
                .font(.headline)

            if isSummarizing {
                HStack(spacing: 8) {
                    ProgressView(value: summaryProgress)
                        .progressViewStyle(.linear)
                    Text("Summarizing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = summaryErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last error", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if errorMessage.contains("Apple Intelligence") {
                            Button("Open Settings") {
                                openAppleIntelligenceSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Retry") {
                            processingQueueManager.enqueueSummarization(for: [video], force: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canGenerateSummary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            summaryActionButton

            if let summary = video.transcriptSummary, !summary.isEmpty {
                Divider()
                Text("Share & Copy")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ShareLink(item: summary) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button {
                    copyToPasteboard(renderedPlainText(fromMarkdown: summary))
                    flashCopiedRendered()
                } label: {
                    Label("Copy Rendered", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copyToPasteboard(summary)
                    flashCopiedMarkdown()
                } label: {
                    Label("Copy Markdown", systemImage: "chevron.left.slash.chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if didCopyRendered {
                    Text("Copied rendered text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if didCopyMarkdown {
                    Text("Copied markdown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canGenerateSummary: Bool {
        video.transcriptText != nil || video.translatedText != nil
    }

    @ViewBuilder
    private var summaryActionButton: some View {
        if video.transcriptSummary == nil {
            Button("Generate") {
                processingQueueManager.enqueueSummarization(for: [video])
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canGenerateSummary || isSummarizing)
        } else {
            Button("Regenerate") {
                processingQueueManager.enqueueSummarization(for: [video], force: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canGenerateSummary || isSummarizing)
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

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func renderedPlainText(fromMarkdown markdown: String) -> String {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
            return String(attributed.characters)
        }
        return markdown
    }

    private func flashCopiedRendered() {
        didCopyRendered = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopyRendered = false
        }
    }

    private func flashCopiedMarkdown() {
        didCopyMarkdown = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopyMarkdown = false
        }
    }

    private func openAppleIntelligenceSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppleIntelligence") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
