import SwiftUI
import Speech
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TranscriptionControlsInspectorPane: View {
    @Environment(LibraryManager.self) private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    private let processingQueueManager = ProcessingQueueManager.shared

    @AppStorage(VideoPagePreferences.preferredTranslationLocaleIdentifierKey)
    private var preferredTranslationLocaleIdentifier = ""

    @State private var translationLocales: [Locale] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.headline)

            languageStatus
            progressSection
            actionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: video.id) {
            await refreshControls()
        }
    }

    private var languageStatus: some View {
        Text(autoDetectStatusLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private var autoDetectStatusLabel: String {
        guard let detectedIdentifier = video.transcriptLanguage,
              !detectedIdentifier.isEmpty else {
            return "Language not detected yet. Change the default in Settings."
        }

        return "Language: \(Locale.current.localizedString(forIdentifier: detectedIdentifier) ?? detectedIdentifier)"
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
        !isTranscriptionActive
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

    private func refreshControls() async {
        let locales = await Array(SpeechTranscriber.supportedLocales)
        let resolved = VideoPagePreferences().resolvedPreferredTranslationLocale(from: locales, systemLocale: .current)

        await MainActor.run {
            translationLocales = locales
            if let resolved {
                preferredTranslationLocaleIdentifier = resolved.identifier
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
