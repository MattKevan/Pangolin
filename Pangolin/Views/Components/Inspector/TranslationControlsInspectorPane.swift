import SwiftUI
import Speech

struct TranslationControlsInspectorPane: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var outputSelection: Locale? = nil
    @State private var supportedLocales: [Locale] = []
    @State private var systemSupportedLocale: Locale? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation")
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

            translationActionButton
        }
        .task(id: video.id) {
            await refreshTranslationControls()
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
            Button {
                processingQueueManager.enqueueTranslation(for: [video], targetLocale: outputSelection)
            } label: {
                Text("Translate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(video.transcriptText == nil || outputSelection == nil || supportedLocales.isEmpty || isTranslationActive)
        } else {
            Button {
                processingQueueManager.enqueueTranslation(for: [video], targetLocale: outputSelection, force: true)
            } label: {
                Text("Translate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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

    private var translationTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .translate)
    }

    private var isTranslationActive: Bool {
        translationTask?.status.isActive == true
    }

    private var translationProgress: Double {
        translationTask?.progress ?? 0.0
    }

    private func refreshTranslationControls() async {
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
