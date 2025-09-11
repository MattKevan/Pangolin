//
//  TranslationView.swift
//  Pangolin
//
//  Created by Matt on 10/09/2025.
//


import SwiftUI
import Speech
#if os(macOS)
import AppKit
#endif
import CoreData

struct TranslationView: View {
    @ObservedObject var video: Video
    @EnvironmentObject var transcriptionService: SpeechTranscriptionService
    @EnvironmentObject var libraryManager: LibraryManager
    
    // Target (output) language selection
    @State private var outputSelection: Locale? = nil
    @State private var supportedLocales: [Locale] = []
    
    // Cache the system-equivalent supported locale once loaded
    @State private var systemSupportedLocale: Locale? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                
                // Language Controls
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        // Source language display (read-only)
                        HStack(spacing: 6) {
                            Text("From")
                                .foregroundStyle(.secondary)
                            Text(sourceLanguageLabel)
                                .fontWeight(.medium)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        
                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)
                        
                        // Target language picker
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
                            HStack(spacing: 6) {
                                Text("To")
                                    .foregroundStyle(.secondary)
                                Text(outputSelectionLabel)
                                    .fontWeight(.medium)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .disabled(supportedLocales.isEmpty)
                        .help("Choose the translation target language.")
                    }
                }
                .padding(.bottom, 4)
                
                HStack {
                    Text("Translation")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    if transcriptionService.isTranscribing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if video.transcriptText == nil {
                        // No transcript available
                        Text("Transcript required")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if video.translatedText == nil {
                        Button("Translate") {
                            Task {
                                let targetLanguage = outputSelection?.language
                                await transcriptionService.translateVideo(video, libraryManager: libraryManager, targetLanguage: targetLanguage)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(outputSelection == nil || supportedLocales.isEmpty)
                    } else {
                        Button("Regenerate") {
                            Task {
                                let targetLanguage = outputSelection?.language
                                await transcriptionService.translateVideo(video, libraryManager: libraryManager, targetLanguage: targetLanguage)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                if video.transcriptText == nil {
                    ContentUnavailableView(
                        "Transcript Required",
                        systemImage: "doc.text.below.ecg",
                        description: Text("A transcript is required before translation. Go to the Transcript tab and generate one first.")
                    )
                } else if transcriptionService.isTranscribing {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(.green)
                            Text("Translating text...")
                                .font(.headline)
                        }
                        
                        ProgressView(value: transcriptionService.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        Text("Using Apple's translation service")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                } else if let errorMessage = transcriptionService.errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Translation Error")
                                .font(.headline)
                        }
                        
                        Text(errorMessage)
                            .font(.body)
                            .foregroundColor(.primary)
                        
                        if let error = parseTranslationError(from: errorMessage),
                           let suggestion = error.recoverySuggestion {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("💡 Suggestion:")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            if let error = parseTranslationError(from: errorMessage),
                               case .translationModelsNotInstalled = error {
                                Button("Open System Settings") {
                                    openTranslationSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            Spacer()
                            Button("Try Again") {
                                Task {
                                    let targetLanguage = outputSelection?.language
                                    await transcriptionService.translateVideo(video, libraryManager: libraryManager, targetLanguage: targetLanguage)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                } else if let translatedText = video.translatedText {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if let language = video.translatedLanguage {
                                Label(displayLanguageName(for: language), systemImage: "globe")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if let dateGenerated = video.translationDateGenerated {
                                Text("Generated \(dateGenerated, formatter: DateFormatter.shortDate)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                        
                        ScrollView {
                            Text(translatedText)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No translation available",
                        systemImage: "globe.badge.chevron.backward",
                        description: Text(outputSelection == nil ? 
                            "Select a target language and tap 'Translate' to create a translation." : 
                            "Tap 'Translate' to create a translation to \(displayName(for: outputSelection!)).")
                    )
                    .font(.title3)
                    .multilineTextAlignment(.center)
                }
                
                Spacer()
            }
            .padding()
        }
        .task {
            // Load supported locales
            let locales = await Array(SpeechTranscriber.supportedLocales)
            await MainActor.run {
                supportedLocales = locales
            }
            
            // Initialize Output picker to a supported equivalent of the system locale
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
    
    // MARK: - Helpers
    
    private var sortedSupportedLocales: [Locale] {
        supportedLocales.sorted { lhs, rhs in
            let ln = displayName(for: lhs)
            let rn = displayName(for: rhs)
            return ln < rn
        }
    }
    
    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
    
    private var sourceLanguageLabel: String {
        if let language = video.transcriptLanguage {
            return displayLanguageName(for: language)
        } else {
            return "No transcript"
        }
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
        } else {
            return "—"
        }
    }
    
    private func displayLanguageName(for languageIdentifier: String) -> String {
        return Locale.current.localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
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
}
