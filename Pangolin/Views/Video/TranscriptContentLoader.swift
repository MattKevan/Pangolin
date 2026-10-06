//
//  TranscriptContentLoader.swift
//  Pangolin
//

import Foundation

struct TimedParagraph: Identifiable, Sendable, Equatable {
    let id: String
    let entryIDs: [String]
    let startSeconds: TimeInterval
    let text: String
}

struct PlainParagraph: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
}

/// What the transcript view shows, ready to display.
struct TranscriptContent: Sendable, Equatable {
    enum Paragraphs: Sendable, Equatable {
        case timed([TimedParagraph])
        case plain([PlainParagraph])
        case none
    }

    var label = "Transcript"
    var paragraphs = Paragraphs.none
    /// Set when a transcript file exists but could not be read and nothing else could be shown.
    var failure: String?

    static let empty = TranscriptContent()
}

/// Where a video's transcript could come from, captured on the main actor so that
/// reading and parsing can happen elsewhere. Sources are tried in this order.
struct TranscriptSources: Sendable {
    var timedTranslationURL: URL?
    var plainTranslation: String?
    var timedTranscriptURL: URL?
    var plainTranscript: String?
}

enum TranscriptContentLoader {
    private static let paragraphSoftWordTarget = 36
    private static let paragraphHardWordLimit = 56
    private static let paragraphMaxChunks = 6
    private static let paragraphMaxSentences = 2
    private static let sentenceTerminators: Set<Character> = [".", "?", "!", ";", ":"]

    private typealias Entry = (id: String, text: String, startSeconds: TimeInterval, endSeconds: TimeInterval)

    /// Reads and parses the first usable source. Does file I/O, so call it off the main actor.
    nonisolated static func load(_ sources: TranscriptSources, artifacts: TextArtifactStore) -> TranscriptContent {
        var readFailed = false

        if let url = sources.timedTranslationURL {
            do {
                let index = try artifacts.readTimedTranslation(from: url).makeChunkIndex()
                let entries = index.allEntries.map { (id: $0.id, text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
                return TranscriptContent(label: "Translation", paragraphs: .timed(timedParagraphs(from: entries)))
            } catch {
                readFailed = true
            }
        }

        if let text = sources.plainTranslation {
            return TranscriptContent(label: "Translation", paragraphs: .plain(plainParagraphs(from: text)))
        }

        if let url = sources.timedTranscriptURL {
            do {
                let index = try artifacts.readTimedTranscript(from: url).makeChunkIndex()
                let entries = index.allEntries.map { (id: $0.id.uuidString, text: $0.text, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
                return TranscriptContent(label: "Transcript", paragraphs: .timed(timedParagraphs(from: entries)))
            } catch {
                readFailed = true
            }
        }

        if let text = sources.plainTranscript {
            return TranscriptContent(label: "Transcript", paragraphs: .plain(plainParagraphs(from: text)))
        }

        return TranscriptContent(failure: readFailed ? "The transcript file could not be read." : nil)
    }

    nonisolated static func plainParagraphs(from text: String) -> [PlainParagraph] {
        text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, text in
                PlainParagraph(id: "plain-\(index)", text: text)
            }
    }

    /// Groups transcript chunks into readable paragraphs by word, chunk and sentence limits.
    nonisolated private static func timedParagraphs(from entries: [Entry]) -> [TimedParagraph] {
        var paragraphs: [TimedParagraph] = []
        var currentEntries: [Entry] = []
        var currentWordCount = 0
        var currentSentenceCount = 0

        func flush() {
            defer {
                currentEntries.removeAll(keepingCapacity: true)
                currentWordCount = 0
                currentSentenceCount = 0
            }
            guard let first = currentEntries.first else { return }
            let paragraphText = currentEntries
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraphText.isEmpty else { return }

            paragraphs.append(
                TimedParagraph(
                    id: first.id,
                    entryIDs: currentEntries.map(\.id),
                    startSeconds: first.startSeconds,
                    text: paragraphText
                )
            )
        }

        for entry in entries {
            currentEntries.append(entry)
            currentWordCount += entry.text.split(whereSeparator: \.isWhitespace).count

            if let last = entry.text.last, sentenceTerminators.contains(last) {
                currentSentenceCount += 1
            }

            let reachedSoftTarget = currentWordCount >= paragraphSoftWordTarget
            let reachedHardLimit = currentWordCount >= paragraphHardWordLimit
            let reachedChunkLimit = currentEntries.count >= paragraphMaxChunks
            let reachedSentenceLimit = currentSentenceCount >= paragraphMaxSentences

            if reachedHardLimit || reachedChunkLimit || (reachedSoftTarget && reachedSentenceLimit) {
                flush()
            }
        }

        flush()
        return paragraphs
    }
}
