import SwiftUI

struct TranscriptionView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var chunkIndex: TimedTranscript.ChunkIndex?
    @State private var inlineTokens: [InlineToken] = []
    @State private var chunkParagraphs: [ChunkParagraph] = []
    @State private var paragraphIDByChunkID: [UUID: String] = [:]
    @State private var useChunkListLayout = false
    @State private var activeChunkID: UUID?
    @State private var loadError: String?

    private struct InlineToken: Identifiable {
        let id: String
        let chunkID: UUID
        let seekSeconds: TimeInterval
        let text: String
    }

    private struct ChunkParagraph: Identifiable {
        let id: String
        let chunkIDs: [UUID]
        let startSeconds: TimeInterval
        let text: String
    }

    private static let chunkListLayoutThreshold = 900
    private static let chunkParagraphWordTarget = 96
    private static let chunkParagraphMaxChunks = 12
    private static let paragraphSentenceTerminators: Set<Character> = [".", "?", "!", ";", ":"]

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
                ScrollView {
                    if useChunkListLayout {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(chunkParagraphs) { paragraph in
                                Text(paragraph.text)
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 0)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        (activeChunkID.map { paragraph.chunkIDs.contains($0) } ?? false)
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        playerViewModel.seek(to: paragraph.startSeconds, in: video)
                                    }
                                    .id(paragraph.id)
                            }
                        }
                        .font(.system(size: 17))
                        .lineSpacing(8)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                    } else {
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
                        //.textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                    }
                }
                .onChange(of: activeChunkID) { _, chunkID in
                    guard let chunkID else { return }
                    let targetID = useChunkListLayout
                        ? (paragraphIDByChunkID[chunkID] ?? chunkID.uuidString)
                        : chunkID.uuidString
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(targetID, anchor: .center)
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
                "Transcript unavailable",
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
            inlineTokens = []
            chunkParagraphs = []
            paragraphIDByChunkID = [:]
            useChunkListLayout = false
            loadError = nil
            activeChunkID = nil
            return
        }

        do {
            let transcript = try libraryManager.readTimedTranscript(from: url)
            let loadedChunkIndex = transcript.makeChunkIndex()
            let entries = loadedChunkIndex.allEntries
            let shouldUseChunkList = entries.count > Self.chunkListLayoutThreshold

            chunkIndex = loadedChunkIndex
            useChunkListLayout = shouldUseChunkList
            inlineTokens = shouldUseChunkList ? [] : makeInlineTokens(from: entries)
            if shouldUseChunkList {
                let paragraphResult = makeChunkParagraphs(from: entries)
                chunkParagraphs = paragraphResult.paragraphs
                paragraphIDByChunkID = paragraphResult.paragraphIDByChunkID
            } else {
                chunkParagraphs = []
                paragraphIDByChunkID = [:]
            }
            loadError = nil
            updateActiveChunk(for: playerViewModel.currentTime)
        } catch {
            chunkIndex = nil
            inlineTokens = []
            chunkParagraphs = []
            paragraphIDByChunkID = [:]
            useChunkListLayout = false
            loadError = "Failed to load timed transcript: \(error.localizedDescription)"
            activeChunkID = nil
        }
    }

    private func updateActiveChunk(for time: TimeInterval) {
        let nextActiveChunkID = chunkIndex?.activeChunk(at: time)?.id
        guard nextActiveChunkID != activeChunkID else { return }
        activeChunkID = nextActiveChunkID
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

    private func makeChunkParagraphs(from entries: [TimedTranscript.ChunkIndex.Entry]) -> (
        paragraphs: [ChunkParagraph],
        paragraphIDByChunkID: [UUID: String]
    ) {
        var paragraphs: [ChunkParagraph] = []
        var paragraphIDByChunkID: [UUID: String] = [:]
        var currentEntries: [TimedTranscript.ChunkIndex.Entry] = []
        var currentWordCount = 0

        func flushParagraph() {
            guard let first = currentEntries.first else { return }
            let id = first.id.uuidString
            let chunkIDs = currentEntries.map(\.id)
            let text = currentEntries
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                currentEntries.removeAll(keepingCapacity: true)
                currentWordCount = 0
                return
            }

            for chunkID in chunkIDs {
                paragraphIDByChunkID[chunkID] = id
            }

            paragraphs.append(
                ChunkParagraph(
                    id: id,
                    chunkIDs: chunkIDs,
                    startSeconds: first.startSeconds,
                    text: text
                )
            )
            currentEntries.removeAll(keepingCapacity: true)
            currentWordCount = 0
        }

        for entry in entries {
            currentEntries.append(entry)
            currentWordCount += entry.text.split(whereSeparator: \.isWhitespace).count

            let endsSentence = entry.text.last.map { Self.paragraphSentenceTerminators.contains($0) } ?? false
            let reachedWordTarget = currentWordCount >= Self.chunkParagraphWordTarget
            let reachedChunkLimit = currentEntries.count >= Self.chunkParagraphMaxChunks

            if reachedChunkLimit || (reachedWordTarget && endsSentence) {
                flushParagraph()
            }
        }

        flushParagraph()
        return (paragraphs, paragraphIDByChunkID)
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
