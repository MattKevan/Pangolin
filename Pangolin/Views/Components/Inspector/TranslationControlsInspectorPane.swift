import SwiftUI
import Speech
#if os(macOS)
import AppKit
#endif

struct TranslationControlsInspectorPane: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var outputSelection: Locale? = nil
    @State private var supportedLocales: [Locale] = []
    @State private var systemSupportedLocale: Locale? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation Controls")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("From")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sourceLanguageLabel)
                    .font(.callout)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("To")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    if let systemLocale = systemSupportedLocale {
                        Button {
                            outputSelection = systemLocale
                        } label: {
                            HStack {
                                Text("System")
                                Spacer()
                                if outputSelection?.identifier == systemLocale.identifier {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                    }

                    ForEach(sortedSupportedLocales, id: \.identifier) { locale in
                        Button {
                            outputSelection = locale
                        } label: {
                            HStack {
                                Text(displayName(for: locale))
                                Spacer()
                                if outputSelection?.identifier == locale.identifier {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(outputSelectionLabel)
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

            if isTranslationActive {
                HStack(spacing: 8) {
                    ProgressView(value: translationProgress)
                        .progressViewStyle(.linear)
                    Text("Translating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = translationErrorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Last error", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if let error = parseTranslationError(from: errorMessage),
                           case .translationModelsNotInstalled = error {
                            Button("Open Settings") {
                                openTranslationSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Retry") {
                            processingQueueManager.enqueueTranslation(for: [video], targetLocale: outputSelection, force: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            translationActionButton
        }
        .task {
            let locales = await Array(SpeechTranscriber.supportedLocales)
            await MainActor.run {
                supportedLocales = locales
            }

            if let systemEquivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current),
               locales.contains(where: { $0.identifier == systemEquivalent.identifier }) {
                await MainActor.run {
                    systemSupportedLocale = systemEquivalent
                    outputSelection = systemEquivalent
                }
            } else {
                await MainActor.run {
                    systemSupportedLocale = nil
                    outputSelection = locales.first
                }
            }
        }
    }

    private var sortedSupportedLocales: [Locale] {
        supportedLocales.sorted { lhs, rhs in
            displayName(for: lhs) < displayName(for: rhs)
        }
    }

    @ViewBuilder
    private var translationActionButton: some View {
        if video.translatedText == nil {
            Button("Translate") {
                processingQueueManager.enqueueTranslation(for: [video], targetLocale: outputSelection)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(video.transcriptText == nil || outputSelection == nil || supportedLocales.isEmpty || isTranslationActive)
        } else {
            Button("Regenerate") {
                processingQueueManager.enqueueTranslation(for: [video], targetLocale: outputSelection, force: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(video.transcriptText == nil || outputSelection == nil || supportedLocales.isEmpty || isTranslationActive)
        }
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var sourceLanguageLabel: String {
        guard let language = video.transcriptLanguage else {
            return "No transcript"
        }
        return Locale.current.localizedString(forIdentifier: language) ?? language
    }

    private var outputSelectionLabel: String {
        if let outputSelection {
            if let systemLocale = systemSupportedLocale,
               outputSelection.identifier == systemLocale.identifier {
                return "System"
            }
            return displayName(for: outputSelection)
        } else if systemSupportedLocale != nil {
            return "System"
        }
        return "—"
    }

    private func openTranslationSettings() {
        #if os(macOS)
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(settingsURL)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
        #endif
    }

    private func parseTranslationError(from message: String) -> TranscriptionError? {
        if message.contains("Translation models") && message.contains("not installed") {
            return .translationModelsNotInstalled("", "")
        } else if message.contains("language") && message.contains("not supported") {
            return .languageNotSupported(Locale.current)
        }
        return nil
    }

    private var translationTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .translate)
    }

    private var isTranslationActive: Bool {
        translationTask?.status.isActive == true
    }

    private var translationProgress: Double {
        translationTask?.progress ?? 0.0
    }

    private var translationErrorMessage: String? {
        translationTask?.errorMessage
    }
}
