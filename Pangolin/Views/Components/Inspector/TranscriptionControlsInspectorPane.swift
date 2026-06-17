import SwiftUI
import Speech
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TranscriptionControlsInspectorPane: View {
    private enum InputMode: String, CaseIterable, Identifiable {
        case autoDetect
        case manual

        var id: String { rawValue }
    }

    @EnvironmentObject private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @AppStorage(VideoPagePreferences.autoTranslateEnabledKey)
    private var autoTranslateEnabled = true

    @AppStorage(VideoPagePreferences.preferredTranslationLocaleIdentifierKey)
    private var preferredTranslationLocaleIdentifier = ""

    @State private var inputMode: InputMode = .autoDetect
    @State private var inputSelection: Locale? = nil
    @State private var transcriptionLocales: [Locale] = []
    @State private var translationLocales: [Locale] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.headline)

            transcriptionLanguageSection
            autoTranslateSection
            progressSection
            actionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: video.id) {
            await refreshControls(for: video.transcriptLanguage)
        }
    }

    private var transcriptionLanguageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Language")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $inputMode) {
                Text("Auto-detect language").tag(InputMode.autoDetect)
                Text("Select language").tag(InputMode.manual)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #endif
            .labelsHidden()

            if inputMode == .manual {
                localeMenu(
                    title: inputSelectionLabel,
                    locales: transcriptionLocales,
                    selection: inputSelection
                ) { inputSelection = $0 }
            } else {
                Text(autoDetectStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var autoTranslateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $autoTranslateEnabled) {
                HStack(spacing: 6) {
                    Text("Auto-translate")
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if os(macOS)
                        .help("Automatically translates newly transcribed videos when their language differs from the system language.")
                    #endif
                }
            }

            Divider()

            HStack {
                Text("Language")
                    .foregroundStyle(.secondary)
                Spacer()
                localeMenu(
                    title: preferredTranslationLocaleTitle,
                    locales: translationLocales,
                    selection: preferredTranslationLocale
                ) { locale in
                    preferredTranslationLocaleIdentifier = locale.identifier
                }
                .frame(maxWidth: 220)
            }
        }
        .padding(12)
        .pangolinGlassRoundedRect(cornerRadius: 16)
    }

    @ViewBuilder
    private var progressSection: some View {
        if isTranscriptionActive || isTranslationActive {
            HStack(spacing: 8) {
                ProgressView(value: activeProgress)
                    .progressViewStyle(.linear)
                Text(activeProgressTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                processingQueueManager.enqueueTranscription(
                    for: [video],
                    preferredLocale: selectedPreferredLocale,
                    force: true
                )
            } label: {
                Text("Transcribe again")
                    .frame(maxWidth: .infinity)
            }
            .pangolinGlassButton(prominent: true)
            .controlSize(.large)
            .disabled(!canStartTranscription)

            Button {
                processingQueueManager.enqueueTranslation(
                    for: [video],
                    targetLocale: preferredTranslationLocale ?? Locale.current,
                    force: true
                )
            } label: {
                Text(hasMatchingTranslation ? "Translate again" : "Translate now")
                    .frame(maxWidth: .infinity)
            }
            .pangolinGlassButton()
            .controlSize(.large)
            .disabled(!canStartTranslation)

            Button {
                copyToPasteboard(preferredDisplayText)
            } label: {
                Text("Copy")
                    .frame(maxWidth: .infinity)
            }
            .pangolinGlassButton()
            .controlSize(.large)
            .disabled(preferredDisplayText.isEmpty)

            Button(role: .destructive) {
                Task {
                    try? await libraryManager.clearGeneratedTextArtifacts(for: video)
                }
            } label: {
                Text("Clear")
                    .frame(maxWidth: .infinity)
            }
            .pangolinGlassButton()
            .controlSize(.large)
            .disabled(!hasGeneratedContent)
        }
    }

    private func localeMenu(
        title: String,
        locales: [Locale],
        selection: Locale?,
        onSelect: @escaping (Locale) -> Void
    ) -> some View {
        Menu {
            ForEach(sortedLocales(locales), id: \.identifier) { locale in
                Button {
                    onSelect(locale)
                } label: {
                    HStack {
                        Text(displayName(for: locale))
                        Spacer()
                        if selection?.identifier == locale.identifier {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .pangolinGlassRoundedRect(cornerRadius: 12, interactive: true)
        }
        .disabled(locales.isEmpty)
    }

    private func sortedLocales(_ locales: [Locale]) -> [Locale] {
        locales.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var selectedPreferredLocale: Locale? {
        inputMode == .manual ? inputSelection : nil
    }

    private var inputSelectionLabel: String {
        if let inputSelection {
            return displayName(for: inputSelection)
        }
        return "Choose language"
    }

    private var autoDetectStatusLabel: String {
        guard let detectedIdentifier = video.transcriptLanguage,
              !detectedIdentifier.isEmpty else {
            return "Language will be detected automatically for this video."
        }

        return "Detected for this video: \(Locale.current.localizedString(forIdentifier: detectedIdentifier) ?? detectedIdentifier)"
    }

    private var preferredTranslationLocale: Locale? {
        let trimmed = preferredTranslationLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return translationLocales.first(where: { $0.identifier == trimmed })
            ?? translationLocales.first(where: { normalizedLanguageCode(for: $0.identifier) == normalizedLanguageCode(for: trimmed) })
    }

    private var preferredTranslationLocaleTitle: String {
        if let preferredTranslationLocale {
            return displayName(for: preferredTranslationLocale)
        }
        return "System"
    }

    private var canStartTranscription: Bool {
        guard !isTranscriptionActive else { return false }
        if inputMode == .manual {
            return inputSelection != nil && !transcriptionLocales.isEmpty
        }
        return true
    }

    private var canStartTranslation: Bool {
        guard !isTranslationActive else { return false }
        let transcript = video.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = video.transcriptLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !transcript.isEmpty && !language.isEmpty
    }

    private var transcriptionTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .transcribe)
    }

    private var translationTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .translate)
    }

    private var isTranscriptionActive: Bool {
        transcriptionTask?.status.isActive == true
    }

    private var isTranslationActive: Bool {
        translationTask?.status.isActive == true
    }

    private var activeProgress: Double {
        if isTranslationActive {
            return translationTask?.progress ?? 0
        }
        return transcriptionTask?.progress ?? 0
    }

    private var activeProgressTitle: String {
        if isTranslationActive {
            return "Translating..."
        }
        return "Transcribing..."
    }

    private var hasGeneratedContent: Bool {
        let transcript = video.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let translation = video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = video.transcriptSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !transcript.isEmpty || !translation.isEmpty || !summary.isEmpty
    }

    private var preferredDisplayText: String {
        if shouldPreferTranslation,
           let translation = video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translation.isEmpty {
            return translation
        }

        return video.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var shouldPreferTranslation: Bool {
        guard let translatedLanguage = video.translatedLanguage,
              let preferredTranslationLocale else {
            return false
        }

        return normalizedLanguageCode(for: translatedLanguage) == normalizedLanguageCode(for: preferredTranslationLocale.identifier)
    }

    private var hasMatchingTranslation: Bool {
        shouldPreferTranslation && !(video.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private func normalizedLanguageCode(for identifier: String) -> String? {
        let locale = Locale(identifier: identifier)
        if let code = locale.language.languageCode?.identifier {
            return code.lowercased()
        }
        return identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() }
    }

    private func refreshControls(for transcriptLanguageIdentifier: String?) async {
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

        let resolvedTranslationLocale: Locale? = {
            let preferences = VideoPagePreferences()
            return preferences.resolvedPreferredTranslationLocale(from: locales, systemLocale: .current)
        }()

        await MainActor.run {
            transcriptionLocales = locales
            translationLocales = locales
            inputMode = .autoDetect
            inputSelection = resolvedSelection ?? locales.first
            if let resolvedTranslationLocale {
                preferredTranslationLocaleIdentifier = resolvedTranslationLocale.identifier
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
