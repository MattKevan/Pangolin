import SwiftUI
import Speech

struct TranscriptionControlsInspectorPane: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var inputSelection: Locale? = nil
    @State private var supportedLocales: [Locale] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript Controls")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    Button {
                        inputSelection = nil
                    } label: {
                        HStack {
                            Label("Auto Detect", systemImage: "sparkles")
                            Spacer()
                            if inputSelection == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    Divider()

                    ForEach(sortedSupportedLocales, id: \.identifier) { locale in
                        Button {
                            inputSelection = locale
                        } label: {
                            HStack {
                                Text(displayName(for: locale))
                                Spacer()
                                if inputSelection?.identifier == locale.identifier {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(inputSelectionLabel)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(supportedLocales.isEmpty)
            }

            if let errorMessage = transcriptionErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last error", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Retry") {
                        processingQueueManager.enqueueTranscription(for: [video], preferredLocale: inputSelection, force: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isTranscriptionRunningForVideo {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            transcriptionActionButton
        }
        .task(id: video.id) {
            await refreshLanguageControls(for: video.transcriptLanguage)
        }
    }

    private var sortedSupportedLocales: [Locale] {
        supportedLocales.sorted { lhs, rhs in
            displayName(for: lhs) < displayName(for: rhs)
        }
    }

    @ViewBuilder
    private var transcriptionActionButton: some View {
        if video.transcriptText == nil {
            Button("Transcribe") {
                processingQueueManager.enqueueTranscription(for: [video], preferredLocale: inputSelection)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(supportedLocales.isEmpty || isTranscriptionRunningForVideo)
        } else {
            Button("Regenerate") {
                processingQueueManager.enqueueTranscription(for: [video], preferredLocale: inputSelection, force: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(supportedLocales.isEmpty || isTranscriptionRunningForVideo)
        }
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var inputSelectionLabel: String {
        if let inputSelection {
            return displayName(for: inputSelection)
        }
        return "Auto Detect"
    }

    private var transcriptionTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .transcribe)
    }

    private var isTranscriptionRunningForVideo: Bool {
        transcriptionTask?.status == .processing
    }

    private var transcriptionErrorMessage: String? {
        transcriptionTask?.errorMessage
    }

    private func refreshLanguageControls(for transcriptLanguageIdentifier: String?) async {
        let locales = await Array(SpeechTranscriber.supportedLocales)
        await MainActor.run {
            supportedLocales = locales
        }

        guard let transcriptLanguageIdentifier, !transcriptLanguageIdentifier.isEmpty else {
            await MainActor.run {
                // Default to per-video auto-detect when no transcript metadata exists.
                inputSelection = nil
            }
            return
        }

        if let matched = locales.first(where: { $0.identifier == transcriptLanguageIdentifier }) {
            await MainActor.run {
                inputSelection = matched
            }
            return
        }

        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: transcriptLanguageIdentifier)),
           locales.contains(where: { $0.identifier == equivalent.identifier }) {
            await MainActor.run {
                inputSelection = equivalent
            }
            return
        }

        await MainActor.run {
            inputSelection = nil
        }
    }
}
