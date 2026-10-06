import Foundation
import Testing
@testable import Pangolin

struct TranscriptContentLoaderTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinTranscriptLoader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTranscript(words: [String]) -> TimedTranscript {
        let timedWords = words.enumerated().map { index, text in
            TimedWord(startSeconds: Double(index), endSeconds: Double(index) + 1, text: text)
        }
        return TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "en_GB",
            generatedAt: Date(timeIntervalSince1970: 0),
            segments: [
                TimedSegment(startSeconds: 0, endSeconds: Double(words.count), text: words.joined(separator: " "), words: timedWords)
            ]
        )
    }

    @Test("Plain text splits into one paragraph per non-empty line")
    func plainTextSplitsIntoLines() {
        let paragraphs = TranscriptContentLoader.plainParagraphs(from: "First line\n\n  Second line  \n")

        #expect(paragraphs.map(\.text) == ["First line", "Second line"])
        #expect(paragraphs.map(\.id) == ["plain-0", "plain-1"])
    }

    @Test("A readable timed transcript becomes timed paragraphs")
    @MainActor
    func timedTranscriptBecomesParagraphs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = TextArtifactStore()
        let url = directory.appendingPathComponent("t.timed.json")
        try artifacts.writeTimedTranscriptAtomically(makeTranscript(words: ["hello", "world."]), to: url)

        let content = TranscriptContentLoader.load(TranscriptSources(timedTranscriptURL: url), artifacts: artifacts)

        guard case .timed(let paragraphs) = content.paragraphs else {
            Issue.record("Expected timed paragraphs")
            return
        }
        #expect(content.label == "Transcript")
        #expect(content.failure == nil)
        #expect(paragraphs.map(\.text) == ["hello world."])
        #expect(paragraphs.first?.startSeconds == 0)
    }

    @Test("Long transcripts are split into several paragraphs")
    @MainActor
    func longTranscriptIsSplit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = TextArtifactStore()
        let url = directory.appendingPathComponent("t.timed.json")
        let words = (0..<200).map { "word\($0)" }
        try artifacts.writeTimedTranscriptAtomically(makeTranscript(words: words), to: url)

        let content = TranscriptContentLoader.load(TranscriptSources(timedTranscriptURL: url), artifacts: artifacts)

        guard case .timed(let paragraphs) = content.paragraphs else {
            Issue.record("Expected timed paragraphs")
            return
        }
        #expect(paragraphs.count > 1)
        #expect(paragraphs.flatMap { $0.text.split(separator: " ").map(String.init) } == words)
    }

    @Test("An unreadable timed file falls back to plain text")
    @MainActor
    func unreadableFileFallsBackToPlainText() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.timed.json")
        try Data("not json".utf8).write(to: url)

        let content = TranscriptContentLoader.load(
            TranscriptSources(timedTranscriptURL: url, plainTranscript: "Fallback"),
            artifacts: TextArtifactStore()
        )

        #expect(content.paragraphs == .plain([PlainParagraph(id: "plain-0", text: "Fallback")]))
        #expect(content.failure == nil)
    }

    @Test("An unreadable timed file with no fallback reports a failure")
    @MainActor
    func unreadableFileWithoutFallbackReportsFailure() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.timed.json")
        try Data("not json".utf8).write(to: url)

        let content = TranscriptContentLoader.load(
            TranscriptSources(timedTranscriptURL: url),
            artifacts: TextArtifactStore()
        )

        #expect(content.paragraphs == .none)
        #expect(content.failure != nil)
    }

    @Test("Translation wins over the transcript when both are present")
    @MainActor
    func translationIsPreferred() {
        let content = TranscriptContentLoader.load(
            TranscriptSources(plainTranslation: "Bonjour", plainTranscript: "Hello"),
            artifacts: TextArtifactStore()
        )

        #expect(content.label == "Translation")
        #expect(content.paragraphs == .plain([PlainParagraph(id: "plain-0", text: "Bonjour")]))
    }

    @Test("No sources gives empty content without a failure")
    @MainActor
    func noSourcesIsEmpty() {
        let content = TranscriptContentLoader.load(TranscriptSources(), artifacts: TextArtifactStore())

        #expect(content == .empty)
    }
}
