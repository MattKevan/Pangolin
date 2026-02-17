import SwiftUI
import Speech

struct TranscriptionControlsInspectorPane: View {
    private enum InputMode: String, CaseIterable, Identifiable {
        case autoDetect
        case manual

        var id: String { rawValue }
    }

    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var inputMode: InputMode = .autoDetect
    @State private var inputSelection: Locale? = nil
    @State private var supportedLocales: [Locale] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $inputMode) {
                    Text(autoDetectOptionLabel).tag(InputMode.autoDetect)
                    Text("Select language").tag(InputMode.manual)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if inputMode == .manual {
                    Menu {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(supportedLocales.isEmpty)
                }

                if inputMode == .autoDetect {
                    Text(autoDetectStatusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage = transcriptionErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last error", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if inputMode == .autoDetect {
                            Button("Use selected language") {
                                inputMode = .manual
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button(retryButtonTitle) {
                            processingQueueManager.enqueueTranscription(for: [video], preferredLocale: selectedPreferredLocale, force: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            

            transcriptionActionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        Button("Transcribe") {
            processingQueueManager.enqueueTranscription(
                for: [video],
                preferredLocale: selectedPreferredLocale,
                force: video.transcriptText != nil
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!canStartTranscription)
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var inputSelectionLabel: String {
        if let inputSelection {
            return displayName(for: inputSelection)
        }
        return "Choose language"
    }

    private var selectedPreferredLocale: Locale? {
        inputMode == .manual ? inputSelection : nil
    }

    private var canStartTranscription: Bool {
        guard !isTranscriptionRunningForVideo else { return false }
        if inputMode == .manual {
            return inputSelection != nil && !supportedLocales.isEmpty
        }
        return true
    }

    private var autoDetectOptionLabel: String {
        "Auto-detect language"
    }

    private var autoDetectStatusLabel: String {
        guard let detectedIdentifier = video.transcriptLanguage,
              !detectedIdentifier.isEmpty else {
            return "Language will be detected automatically for this video."
        }

        let localized = Locale.current.localizedString(forIdentifier: detectedIdentifier) ?? detectedIdentifier
        return "Detected for this video: \(localized)"
    }

    private var retryButtonTitle: String {
        inputMode == .manual ? "Retry with selected language" : "Retry auto-detect"
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
        let resolvedSelection: Locale? = await {
            guard let transcriptLanguageIdentifier, !transcriptLanguageIdentifier.isEmpty else {
                return nil
            }

            if let matched = locales.first(where: { $0.identifier == transcriptLanguageIdentifier }) {
                return matched
            }

            if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: transcriptLanguageIdentifier)),
               locales.contains(where: { $0.identifier == equivalent.identifier }) {
                return equivalent
            }

            return nil
        }()

        await MainActor.run {
            supportedLocales = locales
            inputMode = .autoDetect
            inputSelection = resolvedSelection ?? locales.first
        }
    }
}
