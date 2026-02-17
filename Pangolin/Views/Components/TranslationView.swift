//
//  TranslationView.swift
//  Pangolin
//
//  Created by Matt on 10/09/2025.
//


import SwiftUI

struct TranslationView: View {
    @ObservedObject var video: Video
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
               
                
                if video.transcriptText == nil {
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            "Transcript required",
                            systemImage: "doc.text.below.ecg",
                            description: Text("A transcript is required before translation. Go to the Transcript tab and generate one first.")
                        )
                        .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if isTranslationActive {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Translating")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if let errorMessage = translationErrorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Translation error")
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
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                } else if let translatedText = video.translatedText {
                    VStack(alignment: .leading, spacing: 12) {
                       
                        
                        ScrollView {
                            Text(translatedText)
                                .font(.system(size: 17))
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 720, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.horizontal, 12)
                        }
                    }
                } else {
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            "No translation available",
                            systemImage: "globe.badge.chevron.backward",
                            description: Text("Use the controls inspector to create a translation.")
                        )
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
                
                Spacer()
            }
            .padding()
        }
    }
    
    // MARK: - Helpers
    
    private func displayLanguageName(for languageIdentifier: String) -> String {
        return Locale.current.localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
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

    private var translationErrorMessage: String? {
        translationTask?.errorMessage
    }
}
