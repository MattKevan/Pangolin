import SwiftUI

struct TranscriptionView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var chunkIndex: TimedTranscript.ChunkIndex?
    @State private var activeChunkID: UUID?
    @State private var loadError: String?

    private struct InlineToken: Identifiable {
        let id: String
        let chunkID: UUID
        let seekSeconds: TimeInterval
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorMessage = transcriptionErrorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Transcription error")
                            .font(.headline)
                    }

                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            content
            Spacer()
        }
        .padding()
        .onAppear {
            loadTimedTranscript()
            updateActiveChunk(for: playerViewModel.currentTime)
        }
        .onChange(of: video.id) { _, _ in
            loadTimedTranscript()
        }
        .onChange(of: video.transcriptDateGenerated) { _, _ in
            loadTimedTranscript()
        }
        .onChange(of: isTranscriptionActiveForVideo) { _, isActive in
            if !isActive {
                loadTimedTranscript()
            }
        }
        .onChange(of: playerViewModel.currentTime) { _, newTime in
            updateActiveChunk(for: newTime)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let chunkIndex {
            ScrollViewReader { proxy in
                let inlineTokens = makeInlineTokens(from: chunkIndex.allEntries)
                ScrollView {
                    TranscriptWordWrapLayout(horizontalSpacing: 0, verticalSpacing: 2) {
                        ForEach(inlineTokens) { token in
                            Text(token.text)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, 0)
                                .padding(.vertical, 1)
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
                    //.textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                }
                .onChange(of: activeChunkID) { _, chunkID in
                    guard let chunkID else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(chunkID.uuidString, anchor: .center)
                    }
                }
            }
        } else if isTranscriptionActiveForVideo {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("Transcribing")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if let loadError {
            ContentUnavailableView(
                "Timed transcript unavailable",
                systemImage: "exclamationmark.bubble",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "doc.text",
                description: Text("Transcript has not been generated for this video.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private func loadTimedTranscript() {
        guard let url = libraryManager.timedTranscriptURL(for: video) else {
            chunkIndex = nil
            loadError = nil
            activeChunkID = nil
            return
        }

        do {
            let transcript = try libraryManager.readTimedTranscript(from: url)
            chunkIndex = transcript.makeChunkIndex()
            loadError = nil
            updateActiveChunk(for: playerViewModel.currentTime)
        } catch {
            chunkIndex = nil
            loadError = "Failed to load timed transcript: \(error.localizedDescription)"
            activeChunkID = nil
        }
    }

    private func updateActiveChunk(for time: TimeInterval) {
        activeChunkID = chunkIndex?.activeChunk(at: time)?.id
    }

    private func makeInlineTokens(from entries: [TimedTranscript.ChunkIndex.Entry]) -> [InlineToken] {
        var tokens: [InlineToken] = []
        tokens.reserveCapacity(entries.count * 6)

        for entry in entries {
            let words = entry.text
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }

            guard !words.isEmpty else { continue }

            for (index, word) in words.enumerated() {
                let tokenID = index == 0 ? entry.id.uuidString : "\(entry.id.uuidString)-\(index)"
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

    private var transcriptionTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .transcribe)
    }

    private var isTranscriptionActiveForVideo: Bool {
        transcriptionTask?.status.isActive == true
    }

    private var transcriptionErrorMessage: String? {
        transcriptionTask?.errorMessage
    }
}
