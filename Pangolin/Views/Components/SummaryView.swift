import SwiftUI
import FoundationModels
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MarkdownUI

struct SummaryView: View {
    @ObservedObject var video: Video
    @EnvironmentObject var transcriptionService: SpeechTranscriptionService
    @EnvironmentObject var libraryManager: LibraryManager
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
    // Share sheet presentation (iOS/iPadOS)
    @State private var isPresentingShare = false
    @State private var shareItems: [Any] = []
    
    // Copy feedback
    @State private var didCopyRendered = false
    @State private var didCopyMarkdown = false
    
    var body: some View {
        // Single scroll view only; avoid nested ScrollViews
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding()
        }
        .overlay(shareSheetPresenter)
    }
    
    // MARK: - Header
    
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text("Summary")
                .font(.title2)
                .fontWeight(.bold)
            
            Spacer()
            
            if isSummarizing {
                ProgressView()
                    .scaleEffect(0.8)
            } else if video.transcriptSummary == nil {
                Button {
                    processingQueueManager.enqueueSummarization(for: [video])
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(video.transcriptText == nil && video.translatedText == nil)
            } else {
                Button {
                    processingQueueManager.enqueueSummarization(for: [video], force: true)
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            if let summary = video.transcriptSummary, !summary.isEmpty {
                toolbarControls(summary: summary)
            }
        }
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var content: some View {
        if video.transcriptText == nil && video.translatedText == nil {
            ContentUnavailableView(
                "Transcript Required",
                systemImage: "doc.text.below.ecg",
                description: Text("A transcript is required to generate a summary. Go to the Transcript tab and generate one first.")
            )
        } else if isSummarizing {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.purple)
                    Text("Generating summary...")
                        .font(.headline)
                }
                
                ProgressView(value: summaryProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                
                Text("Using Apple Intelligence to create a comprehensive summary")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(nsColorCompatible: .controlBackgroundColor))
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
                
                if errorMessage.contains("Apple Intelligence") {
                    openSettingsButton
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
                
                // Let the outer scroll view handle scrolling; do not nest another ScrollView
                Markdown(summary)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColorCompatible: .textBackgroundColor))
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
                description: Text("Tap 'Generate' to create a summary of this video's transcript.")
            )
        }
    }
    
    // MARK: - Toolbar Controls
    
    @ViewBuilder
    private func toolbarControls(summary: String) -> some View {
        HStack(spacing: 10) {
            #if os(macOS)
            ShareButtonMac(itemsProvider: { [summary] })
            #else
            Button {
                presentShareIOS(items: [summary])
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .accessibilityLabel("Share")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Share")
            #endif
            
            Text("•").foregroundColor(.secondary)
            
            Button {
                let plain = renderedPlainText(fromMarkdown: summary)
                copyToPasteboard(plain)
                flashCopiedRendered()
            } label: {
                Image(systemName: "doc.on.doc")
                    .accessibilityLabel("Copy")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy rendered text")
            
            Button {
                copyToPasteboard(summary)
                flashCopiedMarkdown()
            } label: {
                Image(systemName: "chevron.left.slash.chevron.right")
                    .accessibilityLabel("Copy as Markdown")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy as Markdown")
            
            if didCopyRendered {
                Text("Copied")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if didCopyMarkdown {
                Text("Copied Markdown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
    }
    
    // MARK: - Settings Button (macOS)
    
    @ViewBuilder
    private var openSettingsButton: some View {
        #if os(macOS)
        Button("Open System Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppleIntelligence") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.bordered)
        .padding(.top, 8)
        #else
        EmptyView()
        #endif
    }
    
    // MARK: - Share Presentation (native)
    
    #if !os(macOS)
    private func presentShareIOS(items: [Any]) {
        guard !items.isEmpty else { return }
        self.shareItems = items
        self.isPresentingShare = true
    }
    #endif
    
    @ViewBuilder
    private var shareSheetPresenter: some View {
        #if os(macOS)
        EmptyView()
        #else
        ShareSheetHostIOS(items: shareItems, isPresented: $isPresentingShare)
            .allowsHitTesting(false)
        #endif
    }
    
    // MARK: - Clipboard
    
    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
    
    private func renderedPlainText(fromMarkdown markdown: String) -> String {
        let normalized = markdown
        if let attributed = try? AttributedString(markdown: normalized, options: .init(interpretedSyntax: .full)) {
            return String(attributed.characters)
        } else {
            return normalized
        }
    }
    
    // MARK: - Copy feedback timers
    
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

// MARK: - macOS Share Button Host (unchanged)

#if os(macOS)
private struct ShareButtonMac: NSViewRepresentable {
    let itemsProvider: () -> [Any]
    
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.title = ""
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.share(_:))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.toolTip = "Share"
        return button
    }
    
    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.itemsProvider = itemsProvider
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(itemsProvider: itemsProvider)
    }
    
    final class Coordinator: NSObject {
        var itemsProvider: () -> [Any]
        init(itemsProvider: @escaping () -> [Any]) {
            self.itemsProvider = itemsProvider
        }
        
        @objc func share(_ sender: NSButton) {
            let items = itemsProvider()
            guard !items.isEmpty else { return }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
#endif

#if !os(macOS)
private struct ShareSheetHostIOS: UIViewControllerRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, !items.isEmpty else { return }
        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                isPresented = false
            }
            if let pop = activityVC.popoverPresentationController {
                pop.sourceView = uiViewController.view
                pop.sourceRect = CGRect(x: uiViewController.view.bounds.midX, y: uiViewController.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            uiViewController.present(activityVC, animated: true)
        }
    }
}
#endif

private extension Color {
    init(nsColorCompatible: NSColorCompatible) {
        #if os(macOS)
        switch nsColorCompatible {
        case .controlBackgroundColor:
            self = Color(NSColor.controlBackgroundColor)
        case .textBackgroundColor:
            self = Color(NSColor.textBackgroundColor)
        }
        #else
        switch nsColorCompatible {
        case .controlBackgroundColor:
            self = Color(UIColor.systemGroupedBackground)
        case .textBackgroundColor:
            self = Color(UIColor.systemBackground)
        }
        #endif
    }
}

#if os(macOS)
private enum NSColorCompatible {
    case controlBackgroundColor
    case textBackgroundColor
}
#else
private enum NSColorCompatible {
    case controlBackgroundColor
    case textBackgroundColor
}
#endif
