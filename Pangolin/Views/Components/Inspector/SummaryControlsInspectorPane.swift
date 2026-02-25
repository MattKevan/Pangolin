import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
struct LineSpacedTextEditor: UIViewRepresentable {
    @Binding var text: String
    var lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style,
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
        uiView.attributedText = NSAttributedString(string: text, attributes: attributes)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: LineSpacedTextEditor

        init(_ parent: LineSpacedTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
#else
struct LineSpacedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var lineSpacing: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body, options: [:])
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: style,
            .font: NSFont.preferredFont(forTextStyle: .body, options: [:]),
            .foregroundColor: NSColor.labelColor
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LineSpacedTextEditor

        init(_ parent: LineSpacedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                parent.text = textView.string
            }
        }
    }
}
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
        Button {
            runSummarization(force: true)
        } label: {
            Text("Summarise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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

            LineSpacedTextEditor(text: selectedPromptBinding, lineSpacing: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 88)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(isSummarizing)
                .padding(2)
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

    private var resolvedSummaryPrompt: String? {
        switch selectedStyle {
        case .shortBullets:
            let trimmed = shortBulletsPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultShortBulletsPrompt : trimmed
        case .articleRewrite:
            let trimmed = articleRewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultArticleRewritePrompt : trimmed
        case .customPrompt:
            let trimmedCustom = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedCustom.isEmpty ? nil : trimmedCustom
        }
    }

    private func runSummarization(force: Bool) {
        processingQueueManager.enqueueSummarization(
            for: [video],
            force: force,
            customPrompt: resolvedSummaryPrompt
        )
    }
}
