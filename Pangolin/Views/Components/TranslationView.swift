//
//  TranslationView.swift
//  Pangolin
//
//  Created by Matt on 10/09/2025.
//

import SwiftUI

struct TranslationView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var chunkIndex: TimedTranslation.ChunkIndex?
    @State private var activeChunkID: String?
    @State private var loadError: String?

    private struct InlineToken: Identifiable {
        let id: String
        let chunkID: String
        let seekSeconds: TimeInterval
        let text: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadTimedTranslation()
            updateActiveChunk(for: playerViewModel.currentTime)
        }
        .onChange(of: video.id) { _, _ in
            loadTimedTranslation()
        }
        .onChange(of: video.translationDateGenerated) { _, _ in
            loadTimedTranslation()
        }
        .onChange(of: video.translatedLanguage) { _, _ in
            loadTimedTranslation()
        }
        .onChange(of: isTranslationActive) { _, isActive in
            if !isActive {
                loadTimedTranslation()
            }
        }
        .onChange(of: playerViewModel.currentTime) { _, newTime in
            updateActiveChunk(for: newTime)
        }
    }

    @ViewBuilder
    private var content: some View {
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
                        Text("Suggestion:")
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
        } else if let chunkIndex {
            syncedTranslationContent(chunkIndex: chunkIndex)
        } else if let translatedText = video.translatedText,
                  !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(translatedText)
                    .font(.system(size: 17))
                    .lineSpacing(14)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    //.padding(.horizontal, 12)
            }
        } else if let loadError {
            ContentUnavailableView(
                "Timed translation unavailable",
                systemImage: "exclamationmark.bubble",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity, minHeight: 320)
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
    }

    @ViewBuilder
    private func syncedTranslationContent(chunkIndex: TimedTranslation.ChunkIndex) -> some View {
        ScrollViewReader { proxy in
            let inlineTokens = makeInlineTokens(from: chunkIndex.allEntries)
            ScrollView {
                TranscriptWordWrapLayout(horizontalSpacing: 0, verticalSpacing: 8) {
                    ForEach(inlineTokens) { token in
                        Text(token.text)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 0)
                            .padding(.vertical, 2)
                            .background(activeChunkID == token.chunkID ? Color.accentColor.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playerViewModel.seek(to: token.seekSeconds, in: video)
                            }
                            .id(token.id)
                    }
                }
                .font(.system(size: 17))
                .lineSpacing(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
            }
            .onChange(of: activeChunkID) { _, chunkID in
                guard let chunkID else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(chunkID, anchor: .center)
                }
            }
        }
    }

    private func loadTimedTranslation() {
        guard let languageCode = video.translatedLanguage,
              !languageCode.isEmpty,
              let url = libraryManager.timedTranslationURL(for: video, languageCode: languageCode),
              FileManager.default.fileExists(atPath: url.path) else {
            chunkIndex = nil
            loadError = nil
            activeChunkID = nil
            return
        }

        do {
            let translation = try libraryManager.readTimedTranslation(from: url)
            chunkIndex = translation.makeChunkIndex()
            loadError = nil
            updateActiveChunk(for: playerViewModel.currentTime)
        } catch {
            chunkIndex = nil
            loadError = "Failed to load timed translation: \(error.localizedDescription)"
            activeChunkID = nil
        }
    }

    private func updateActiveChunk(for time: TimeInterval) {
        activeChunkID = chunkIndex?.activeChunk(at: time)?.id
    }

    private func makeInlineTokens(from entries: [TimedTranslation.ChunkIndex.Entry]) -> [InlineToken] {
        var tokens: [InlineToken] = []
        tokens.reserveCapacity(entries.count * 6)

        for entry in entries {
            let words = entry.text
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }

            guard !words.isEmpty else { continue }

            for (index, word) in words.enumerated() {
                let tokenID = index == 0 ? entry.id : "\(entry.id)-\(index)"
                tokens.append(
                    InlineToken(
                        id: tokenID,
                        chunkID: entry.id,
                        seekSeconds: entry.startSeconds,
                        text: word + " "
                    )
                )
            }
        }

        return tokens
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
