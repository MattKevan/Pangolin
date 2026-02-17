import Foundation

struct TimedWord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String

    init(
        id: UUID = UUID(),
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        text: String
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

struct TimedSegment: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
    let words: [TimedWord]

    init(
        id: UUID = UUID(),
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        text: String,
        words: [TimedWord]
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.words = words
    }
}

struct TimedTranscript: Codable, Sendable, Hashable {
    let videoID: UUID
    let localeIdentifier: String
    let generatedAt: Date
    let segments: [TimedSegment]

    struct FlatIndex: Sendable {
        struct Entry: Identifiable, Hashable, Sendable {
            let segmentIndex: Int
            let wordIndex: Int
            let word: TimedWord

            var id: UUID { word.id }
            var startSeconds: TimeInterval { word.startSeconds }
            var endSeconds: TimeInterval { word.endSeconds }
        }

        private let entries: [Entry]

        init(transcript: TimedTranscript) {
            var built: [Entry] = []
            built.reserveCapacity(transcript.segments.reduce(0) { $0 + $1.words.count })
            for (segmentIndex, segment) in transcript.segments.enumerated() {
                for (wordIndex, word) in segment.words.enumerated() {
                    built.append(Entry(segmentIndex: segmentIndex, wordIndex: wordIndex, word: word))
                }
            }
            self.entries = built.sorted { lhs, rhs in
                if lhs.startSeconds == rhs.startSeconds {
                    return lhs.endSeconds < rhs.endSeconds
                }
                return lhs.startSeconds < rhs.startSeconds
            }
        }

        var allEntries: [Entry] {
            entries
        }

        func activeWord(at time: TimeInterval) -> Entry? {
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

    func makeFlatIndex() -> FlatIndex {
        FlatIndex(transcript: self)
    }
}
