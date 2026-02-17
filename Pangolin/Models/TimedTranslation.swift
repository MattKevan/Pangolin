import Foundation

struct TimedTranslationChunk: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let sourceText: String
    let targetText: String

    init(
        id: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        sourceText: String,
        targetText: String
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.sourceText = sourceText
        self.targetText = targetText
    }
}

struct TimedTranslation: Codable, Sendable, Hashable {
    struct SourceChunk: Sendable, Identifiable, Hashable {
        let id: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let text: String
    }

    let videoID: UUID
    let sourceLocaleIdentifier: String
    let targetLocaleIdentifier: String
    let generatedAt: Date
    let chunks: [TimedTranslationChunk]

    struct ChunkIndex: Sendable {
        struct Entry: Identifiable, Hashable, Sendable {
            let chunk: TimedTranslationChunk
            var id: String { chunk.id }
            var startSeconds: TimeInterval { chunk.startSeconds }
            var endSeconds: TimeInterval { chunk.endSeconds }
            var text: String { chunk.targetText }
        }

        private let entries: [Entry]

        init(translation: TimedTranslation) {
            self.entries = translation.chunks
                .map { Entry(chunk: $0) }
                .sorted { lhs, rhs in
                    if lhs.startSeconds == rhs.startSeconds {
                        return lhs.endSeconds < rhs.endSeconds
                    }
                    return lhs.startSeconds < rhs.startSeconds
                }
        }

        var allEntries: [Entry] {
            entries
        }

        func activeChunk(at time: TimeInterval) -> Entry? {
            guard !entries.isEmpty else { return nil }

            var low = 0
            var high = entries.count - 1
            var candidate: Int?

            while low <= high {
                let mid = (low + high) / 2
                if entries[mid].startSeconds <= time {
                    candidate = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            guard let index = candidate else { return nil }
            let entry = entries[index]
            if entry.endSeconds >= time {
                return entry
            }

            if index + 1 < entries.count {
                let next = entries[index + 1]
                if next.startSeconds <= time && next.endSeconds >= time {
                    return next
                }
            }

            return nil
        }
    }

    static func sentenceSourceChunks(
        from transcript: TimedTranscript,
        pauseBoundaryThreshold: TimeInterval = 1.0,
        maxWordsWithoutBoundary: Int = 40
    ) -> [SourceChunk] {
        let words = transcript.segments
            .flatMap(\.words)
            .sorted { lhs, rhs in
                if lhs.startSeconds == rhs.startSeconds {
                    return lhs.endSeconds < rhs.endSeconds
                }
                return lhs.startSeconds < rhs.startSeconds
            }
        guard !words.isEmpty else { return [] }

        let sentenceTerminators: Set<Character> = [".", "?", "!", "…"]
        let trailingPunctuationToIgnore = CharacterSet(charactersIn: "\"'”’)]}")
        let boundedSafetyCap = max(1, maxWordsWithoutBoundary)

        var built: [SourceChunk] = []
        built.reserveCapacity(words.count / 8)
        var currentWords: [TimedWord] = []
        currentWords.reserveCapacity(24)

        func isSentenceEndingWord(_ wordText: String) -> Bool {
            let trimmed = wordText.trimmingCharacters(in: trailingPunctuationToIgnore)
            guard let last = trimmed.last else { return false }
            return sentenceTerminators.contains(last)
        }

        func makeChunkID(index: Int, startSeconds: TimeInterval, endSeconds: TimeInterval) -> String {
            let startMS = Int((max(0, startSeconds) * 1000).rounded())
            let endMS = Int((max(startSeconds, endSeconds) * 1000).rounded())
            return "c-\(index)-\(startMS)-\(endMS)"
        }

        func flush() {
            guard !currentWords.isEmpty else { return }
            let start = currentWords.first?.startSeconds ?? 0
            let end = max(start, currentWords.last?.endSeconds ?? start)
            let text = currentWords
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                currentWords.removeAll(keepingCapacity: true)
                return
            }

            let id = makeChunkID(index: built.count, startSeconds: start, endSeconds: end)
            built.append(SourceChunk(id: id, startSeconds: start, endSeconds: end, text: text))
            currentWords.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            currentWords.append(word)

            let sentenceEnded = isSentenceEndingWord(word.text)
            let reachedSafetyCap = currentWords.count >= boundedSafetyCap
            let hasPauseAfterWord: Bool = {
                guard index + 1 < words.count else { return false }
                let next = words[index + 1]
                return next.startSeconds - word.endSeconds >= pauseBoundaryThreshold
            }()

            if sentenceEnded || hasPauseAfterWord || reachedSafetyCap {
                flush()
            }
        }

        flush()
        return built
    }

    func makeChunkIndex() -> ChunkIndex {
        ChunkIndex(translation: self)
    }
}
