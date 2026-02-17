import Foundation
import Testing
@testable import Pangolin

struct TimedTranslationTests {
    @Test("TimedTranslation Codable roundtrip")
    func timedTranslationCodableRoundtrip() throws {
        let translation = TimedTranslation(
            videoID: UUID(),
            sourceLocaleIdentifier: "es",
            targetLocaleIdentifier: "en",
            generatedAt: Date(timeIntervalSince1970: 23456),
            chunks: [
                TimedTranslationChunk(
                    id: "c-0-0-1000",
                    startSeconds: 0,
                    endSeconds: 1,
                    sourceText: "hola",
                    targetText: "hello"
                ),
                TimedTranslationChunk(
                    id: "c-1-1000-2000",
                    startSeconds: 1,
                    endSeconds: 2,
                    sourceText: "mundo",
                    targetText: "world"
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(translation)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TimedTranslation.self, from: data)

        #expect(decoded == translation)
    }

    @Test("ChunkIndex finds active chunk at boundaries")
    func chunkIndexActiveChunkBoundaries() {
        let translation = TimedTranslation(
            videoID: UUID(),
            sourceLocaleIdentifier: "es",
            targetLocaleIdentifier: "en",
            generatedAt: Date(),
            chunks: [
                TimedTranslationChunk(
                    id: "c-0-0-1000",
                    startSeconds: 0,
                    endSeconds: 1,
                    sourceText: "hola mundo",
                    targetText: "hello world"
                ),
                TimedTranslationChunk(
                    id: "c-1-1200-2000",
                    startSeconds: 1.2,
                    endSeconds: 2.0,
                    sourceText: "adios",
                    targetText: "bye"
                )
            ]
        )

        let index = translation.makeChunkIndex()
        #expect(index.activeChunk(at: 0.0)?.id == "c-0-0-1000")
        #expect(index.activeChunk(at: 0.9)?.id == "c-0-0-1000")
        #expect(index.activeChunk(at: 1.5)?.id == "c-1-1200-2000")
        #expect(index.activeChunk(at: 2.2) == nil)
    }

    @Test("Out-of-order mapped translation responses preserve source chunk order")
    func outOfOrderResponseMappingPreservesChunkOrder() throws {
        let sourceChunks: [TimedTranslation.SourceChunk] = [
            .init(id: "c-0-0-1000", startSeconds: 0, endSeconds: 1, text: "hola"),
            .init(id: "c-1-1000-2000", startSeconds: 1, endSeconds: 2, text: "mundo")
        ]

        let mapped = try SpeechTranscriptionService.assembleTimedTranslationChunks(
            sourceChunks: sourceChunks,
            translatedTextsByID: [
                "c-1-1000-2000": "world",
                "c-0-0-1000": "hello",
            ]
        )

        #expect(mapped.count == 2)
        #expect(mapped[0].id == "c-0-0-1000")
        #expect(mapped[0].targetText == "hello")
        #expect(mapped[1].id == "c-1-1000-2000")
        #expect(mapped[1].targetText == "world")
    }

    @Test("Sentence source chunking honors punctuation and pause boundaries")
    func sentenceSourceChunkingHonorsBoundaries() {
        let transcript = TimedTranscript(
            videoID: UUID(),
            localeIdentifier: "es-ES",
            generatedAt: Date(),
            segments: [
                TimedSegment(
                    startSeconds: 0,
                    endSeconds: 3,
                    text: "Hola mundo. Esto va",
                    words: [
                        TimedWord(startSeconds: 0.0, endSeconds: 0.4, text: "Hola"),
                        TimedWord(startSeconds: 0.4, endSeconds: 0.9, text: "mundo."),
                        TimedWord(startSeconds: 1.0, endSeconds: 1.4, text: "Esto"),
                        TimedWord(startSeconds: 1.4, endSeconds: 1.8, text: "va"),
                    ]
                ),
                TimedSegment(
                    startSeconds: 3,
                    endSeconds: 6,
                    text: "sin pausa grande",
                    words: [
                        TimedWord(startSeconds: 3.2, endSeconds: 3.6, text: "sin"),
                        TimedWord(startSeconds: 3.6, endSeconds: 4.0, text: "pausa"),
                        TimedWord(startSeconds: 5.6, endSeconds: 6.0, text: "grande"),
                    ]
                )
            ]
        )

        let chunks = TimedTranslation.sentenceSourceChunks(from: transcript, pauseBoundaryThreshold: 1.0)

        #expect(chunks.count == 4)
        #expect(chunks[0].text == "Hola mundo.")
        #expect(chunks[1].text == "Esto va")
        #expect(chunks[2].text == "sin pausa")
        #expect(chunks[3].text == "grande")

        // Deterministic chunk IDs are used for request/response mapping.
        #expect(chunks.last?.id.hasPrefix("c-") == true)
    }
}
