import SwiftUI

struct FlashcardsControlsInspectorPane: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var sourceMode: FlashcardsSourceMode = .autoSystemLanguage
    @State private var cardCount: Int = 12
    @State private var selectedPromptStyle: PromptStyle = .quickRecall
    @State private var quickRecallPrompt = FlashcardsControlsInspectorPane.defaultQuickRecallPrompt
    @State private var deepDivePrompt = FlashcardsControlsInspectorPane.defaultDeepDivePrompt
    @State private var customPrompt = ""

    private enum PromptStyle: String, CaseIterable, Identifiable {
        case quickRecall
        case deepDive
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quickRecall:
                return "Quick recall Q&A"
            case .deepDive:
                return "Concept deep-dive"
            case .custom:
                return "Custom prompt"
            }
        }
    }

    private static let defaultQuickRecallPrompt = """
    Generate concise flashcards in question-and-answer format.
    Prioritize high-signal facts, definitions, and key decisions.
    Keep each answer short enough for fast review.
    """

    private static let defaultDeepDivePrompt = """
    Generate conceptual flashcards that explain why things matter.
    Focus on relationships, cause/effect, and nuanced understanding.
    Keep the front focused and the back clear and concrete.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flashcards")
                .font(.headline)

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView(value: flashcardsProgress)
                        .progressViewStyle(.linear)
                    Text("Generating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            sourceControls
            countControls
            promptControls

            if let errorMessage = flashcardsErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last error", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        runGeneration(force: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canGenerate || isGenerating)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                runGeneration(force: true)
            } label: {
                Text("Generate flashcards")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate || isGenerating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(FlashcardsSourceMode.allCases) { mode in
                    sourceSelectionRow(mode)
                }
            }
        }
    }

    private var countControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Card count")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $cardCount, in: 4...40) {
                Text("\(cardCount) cards")
            }
            .disabled(isGenerating)
        }
    }

    private var promptControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt style")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(PromptStyle.allCases) { style in
                    styleSelectionRow(style)
                }
            }

            Text("Custom prompt")
                .font(.caption)
                .foregroundStyle(.secondary)

            LineSpacedTextEditor(text: selectedPromptBinding, lineSpacing: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 88)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(isGenerating)
                .padding(2)
        }
    }

    @ViewBuilder
    private func sourceSelectionRow(_ mode: FlashcardsSourceMode) -> some View {
        let isSelected = sourceMode == mode

        Button {
            sourceMode = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .foregroundStyle(.primary)
                    Text(mode.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectionRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func styleSelectionRow(_ style: PromptStyle) -> some View {
        let isSelected = selectedPromptStyle == style

        Button {
            selectedPromptStyle = style
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(style.title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectionRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func selectionRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var selectedPromptBinding: Binding<String> {
        switch selectedPromptStyle {
        case .quickRecall:
            return $quickRecallPrompt
        case .deepDive:
            return $deepDivePrompt
        case .custom:
            return $customPrompt
        }
    }

    private var resolvedPrompt: String? {
        switch selectedPromptStyle {
        case .quickRecall:
            let trimmed = quickRecallPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultQuickRecallPrompt : trimmed
        case .deepDive:
            let trimmed = deepDivePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultDeepDivePrompt : trimmed
        case .custom:
            let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private var canGenerate: Bool {
        video.transcriptText != nil
    }

    private var flashcardsTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .generateFlashcards)
    }

    private var isGenerating: Bool {
        flashcardsTask?.status.isActive == true
    }

    private var flashcardsProgress: Double {
        flashcardsTask?.progress ?? 0.0
    }

    private var flashcardsErrorMessage: String? {
        flashcardsTask?.errorMessage
    }

    private func runGeneration(force: Bool) {
        processingQueueManager.enqueueFlashcards(
            for: [video],
            force: force,
            count: cardCount,
            sourceMode: sourceMode,
            customPrompt: resolvedPrompt
        )
    }
}
