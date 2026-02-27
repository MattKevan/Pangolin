import Foundation
import Testing
@testable import Pangolin

struct FlashcardDeckTests {
    @Test("FlashcardDeck Codable roundtrip")
    func flashcardDeckCodableRoundtrip() throws {
        let deck = FlashcardDeck(
            videoID: UUID(),
            generatedAt: Date(timeIntervalSince1970: 1234),
            sourceModeUsed: .translation,
            sourceLanguageCode: "en",
            cards: [
                Flashcard(
                    front: "What is Pangolin?",
                    back: "A local-first video transcription and study app.",
                    startSeconds: 12.0,
                    endSeconds: 20.0,
                    sourceSnippet: "Pangolin helps you transcribe and summarize videos."
                ),
                Flashcard(
                    front: "How are flashcards linked?",
                    back: "Each card stores source timestamps for quick seek.",
                    startSeconds: 45.0,
                    endSeconds: 52.0,
                    sourceSnippet: "Cards include a view link to relevant moments."
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(deck)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FlashcardDeck.self, from: data)

        #expect(decoded == deck)
    }
}
