//
//  TranscriptionSettingsPane.swift
//  Pangolin
//

import SwiftUI
import Speech

struct TranscriptionSettingsPane: View {
    @AppStorage(VideoPagePreferences.transcriptionLocaleIdentifierKey)
    private var transcriptionLocaleIdentifier = ""

    @AppStorage(VideoPagePreferences.autoTranslateEnabledKey)
    private var autoTranslateEnabled = true

    @AppStorage(VideoPagePreferences.preferredTranslationLocaleIdentifierKey)
    private var translationLocaleIdentifier = ""

    @State private var locales: [Locale] = []

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $transcriptionLocaleIdentifier) {
                    Text("Detect automatically").tag("")
                    ForEach(sortedLocales, id: \.identifier) { locale in
                        Text(displayName(for: locale)).tag(locale.identifier)
                    }
                }
            } header: {
                Text("Transcript")
            } footer: {
                Text("The language new transcripts are made in.")
            }

            Section {
                Toggle("Translate new transcripts", isOn: $autoTranslateEnabled)

                Picker("Translate into", selection: $translationLocaleIdentifier) {
                    Text("System language").tag("")
                    ForEach(sortedLocales, id: \.identifier) { locale in
                        Text(displayName(for: locale)).tag(locale.identifier)
                    }
                }
                .disabled(!autoTranslateEnabled)
            } header: {
                Text("Translation")
            } footer: {
                Text("Videos already in the target language are not translated.")
            }
        }
        .formStyle(.grouped)
        .task {
            locales = await Array(SpeechTranscriber.supportedLocales)
        }
    }

    private var sortedLocales: [Locale] {
        locales.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

#Preview {
    TranscriptionSettingsPane()
}
