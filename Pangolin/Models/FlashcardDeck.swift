import Foundation

enum FlashcardsSourceMode: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case autoSystemLanguage
    case transcript
    case translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoSystemLanguage:
            return "Auto"
        case .transcript:
            return "Transcript"
        case .translation:
            return "Translation"
        }
    }

    var description: String {
        switch self {
        case .autoSystemLanguage:
            return "Use transcript in system language, otherwise prefer translation."
        case .transcript:
            return "Always generate cards from the transcript."
        case .translation:
            return "Always generate cards from the translation."
        }
    }
}

struct Flashcard: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let front: String
    let back: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let sourceSnippet: String

    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        sourceSnippet: String
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.sourceSnippet = sourceSnippet
    }
}

struct FlashcardDeck: Codable, Sendable, Hashable {
    let videoID: UUID
    let generatedAt: Date
    let sourceModeUsed: FlashcardsSourceMode
    let sourceLanguageCode: String
    let cards: [Flashcard]
}
