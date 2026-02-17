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
    @State private var selectedStyle: SummaryStyle = .shortBullets
    @State private var shortBulletsPrompt = SummaryControlsInspectorPane.defaultShortBulletsPrompt
    @State private var articleRewritePrompt = SummaryControlsInspectorPane.defaultArticleRewritePrompt
    @State private var customPrompt = ""

    private enum SummaryStyle: String, CaseIterable, Identifiable {
        case shortBullets
        case articleRewrite
        case customPrompt

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shortBullets:
                return "Short bullet points"
            case .articleRewrite:
                return "Longer article rewrite"
            case .customPrompt:
                return "Custom prompt"
            }
        }
    }

    private static let defaultShortBulletsPrompt = """
    Create a concise summary in Markdown with short bullet points.
    Focus on key points, decisions, and outcomes.
    Keep it brief, high-signal, and easy to skim.
    """

    private static let defaultArticleRewritePrompt = """
    Rewrite this into a longer, narrative article in Markdown.
    Use clear section headings, cohesive paragraphs, and include bullet lists only when they improve clarity.
    Keep it accurate to the source content and avoid invented details.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)

            if isSummarizing {
                HStack(spacing: 8) {
                    ProgressView(value: summaryProgress)
                        .progressViewStyle(.linear)
                    Text("Summarising...")
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
                            Button("Open settings") {
                                openAppleIntelligenceSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Retry") {
                            runSummarization(force: true)
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

            summaryCustomizationControls
            summaryActionButton

            if let summary = video.transcriptSummary, !summary.isEmpty {
                Divider()
                Text("Share & copy")
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
                    Label("Copy rendered", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copyToPasteboard(summary)
                    flashCopiedMarkdown()
                } label: {
                    Label("Copy markdown", systemImage: "chevron.left.slash.chevron.right")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canGenerateSummary: Bool {
        video.transcriptText != nil || video.translatedText != nil
    }

    @ViewBuilder
    private var summaryActionButton: some View {
        Button("Summarise") {
            runSummarization(force: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!canGenerateSummary || isSummarizing)
    }

    private var summaryCustomizationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary style")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(SummaryStyle.allCases) { style in
                    styleSelectionButton(style)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Custom prompt")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: selectedPromptBinding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 88)
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(isSummarizing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var selectedPromptBinding: Binding<String> {
        switch selectedStyle {
        case .shortBullets:
            return $shortBulletsPrompt
        case .articleRewrite:
            return $articleRewritePrompt
        case .customPrompt:
            return $customPrompt
        }
    }

    @ViewBuilder
    private func styleSelectionButton(_ style: SummaryStyle) -> some View {
        let isSelected = selectedStyle == style

        Button {
            selectedStyle = style
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(style.title)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(styleRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func styleRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var resolvedSummaryRequest: (preset: SpeechTranscriptionService.SummaryPreset, customPrompt: String?) {
        switch selectedStyle {
        case .shortBullets:
            let trimmed = shortBulletsPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = trimmed.isEmpty ? Self.defaultShortBulletsPrompt : trimmed
            return (.custom, prompt)
        case .articleRewrite:
            let trimmed = articleRewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = trimmed.isEmpty ? Self.defaultArticleRewritePrompt : trimmed
            return (.custom, prompt)
        case .customPrompt:
            let trimmedCustom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let optionalCustom = trimmedCustom.isEmpty ? nil : trimmedCustom
            return (.custom, optionalCustom)
        }
    }

    private func runSummarization(force: Bool) {
        let request = resolvedSummaryRequest
        processingQueueManager.enqueueSummarization(
            for: [video],
            force: force,
            preset: request.preset,
            customPrompt: request.customPrompt
        )
    }
}
