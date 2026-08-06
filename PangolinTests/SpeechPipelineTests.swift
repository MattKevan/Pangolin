import Testing
import Foundation
import AVFoundation
import Speech
import CoreData
@testable import Pangolin

// MARK: - Summarization pipeline
//
// The chunking/token budget logic that feeds Apple Intelligence summarization.
// summarizeChunk/reduceSummaries themselves require a live LanguageModelSession
// and are exercised by the app smoke pass; everything deterministic is here.

struct SummarizationPipelineTests {
    @Test("estimateTokens is utf8-length / 4 with a floor of 1")
    func estimateTokensFloorsAndScales() {
        let service = SpeechTranscriptionService()
        #expect(service.estimateTokens(for: "") == 1)
        #expect(service.estimateTokens(for: "abcd") == 1)
        #expect(service.estimateTokens(for: "aaaaaaaa") == 2)
        // "é" is 2 UTF-8 bytes, so 8 chars = 16 bytes -> 4 tokens.
        #expect(service.estimateTokens(for: "éééééééé") == 4)
    }

    @Test("splitTextIntoChunksByBudget returns no chunks for empty text")
    func emptyTextProducesNoChunks() {
        let service = SpeechTranscriptionService()
        #expect(service.splitTextIntoChunksByBudget("", targetTokens: 100, hardLimit: 200) == [])
    }

    @Test("short text stays a single chunk")
    func shortTextIsOneChunk() {
        let service = SpeechTranscriptionService()
        let chunks = service.splitTextIntoChunksByBudget(
            "A short paragraph of content.", targetTokens: 100, hardLimit: 200
        )
        #expect(chunks.count == 1)
    }

    @Test("long text splits into multiple chunks that are non-empty")
    func longTextSplitsIntoNonEmptyChunks() {
        let service = SpeechTranscriptionService()
        let longText = Array(repeating: "This sentence has enough words to count toward a token budget. ", count: 40).joined()
        let chunks = service.splitTextIntoChunksByBudget(longText, targetTokens: 20, hardLimit: 100)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test("a single sentence over the hard limit is recursively split to fit")
    func oversizeSentenceIsHardSplit() {
        let service = SpeechTranscriptionService()
        let longSentence = String(repeating: "a", count: 800)  // ~200 tokens, over hardLimit 50
        let chunks = service.splitTextIntoChunksByBudget(longSentence, targetTokens: 40, hardLimit: 50)
        // 800 chars -> split in half (400), then the safety pass halves each
        // 400-char chunk again (estimateTokens(400) = 100 > 50) -> 4 x 200 chars.
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.count == 200 })
        #expect(chunks.joined().filter { !$0.isWhitespace }.count == 800)
    }

    @Test("splitIntoSentences honors sentence boundaries")
    func sentencesSplitOnBoundaries() {
        let service = SpeechTranscriptionService()
        let sentences = service.splitIntoSentences("First sentence. Second sentence! Is this a third?")
        #expect(sentences.count == 3)
    }

    @Test("summaryInstructions uses the default prompt when none is given")
    func summaryInstructionsDefaultAndCustom() {
        let service = SpeechTranscriptionService()
        #expect(service.summaryInstructions(from: nil) == "Summarize the content clearly with headings and bullet points.")
        #expect(service.summaryInstructions(from: "Make it punchy.") == "Make it punchy.")
        #expect(service.summaryInstructions(from: "  padded  ") == "padded")
    }

    @Test("language-model reuse errors are classified by message")
    func initializationReuseErrorClassification() {
        let service = SpeechTranscriptionService()
        let reuse = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid reuse after initialization failure"])
        let unrelated = NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "network unavailable"])
        #expect(service.isLanguageModelInitializationReuseError(reuse))
        #expect(!service.isLanguageModelInitializationReuseError(unrelated))
    }

    @Test("context-window errors are classified by message")
    func contextWindowErrorClassification() {
        let service = SpeechTranscriptionService()
        let overflow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "exceeded context window size"])
        let unrelated = NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "model not ready"])
        #expect(service.isLanguageModelContextWindowExceededError(overflow))
        #expect(!service.isLanguageModelContextWindowExceededError(unrelated))
    }
}

// MARK: - Translation pipeline

struct TranslationPipelineTests {
    @Test("mapTranslationError classifies unsupported, not-installed, and generic failures")
    func translationErrorMapping() {
        let service = SpeechTranscriptionService()
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "fr")

        func mapped(_ description: String) -> Error {
            service.mapTranslationError(
                NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: description]),
                sourceLanguage: source,
                targetLanguage: target
            )
        }

        guard case .translationNotSupported = mapped("pair not supported") as? TranscriptionError else {
            Issue.record("expected .translationNotSupported")
            return
        }
        guard case .translationModelsNotInstalled = mapped("models notInstalled for this pair") as? TranscriptionError else {
            Issue.record("expected .translationModelsNotInstalled for notInstalled")
            return
        }
        guard case .translationModelsNotInstalled = mapped("error Code=16") as? TranscriptionError else {
            Issue.record("expected .translationModelsNotInstalled for Code=16")
            return
        }
        guard case .translationFailed = mapped("something else went wrong") as? TranscriptionError else {
            Issue.record("expected .translationFailed fallback")
            return
        }
    }
}

// MARK: - Transcription pipeline

struct TranscriptionPipelineTests {
    @Test("seconds(from:) clamps negative and non-finite CMTime to zero")
    func secondsFromCMTimeClamps() {
        let service = SpeechTranscriptionService()
        #expect(service.seconds(from: CMTime(seconds: 5, preferredTimescale: 600)) == 5)
        #expect(service.seconds(from: CMTime(seconds: -3, preferredTimescale: 600)) == 0)
        // Invalid CMTime (timescale 0) is non-finite -> clamped to 0.
        #expect(service.seconds(from: CMTime(value: 1, timescale: 0)) == 0)
    }

    @Test("timedWords extracts speech-attributed runs into proportionally timed words")
    func timedWordsFromAttributedString() {
        let service = SpeechTranscriptionService()
        var attributed = AttributedString("hello world")
        if let range = attributed.range(of: "hello") {
            // The write path uses the same key type the service reads
            // (timedWords: attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]).
            attributed[range][AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 600),
                end: CMTime(seconds: 2, preferredTimescale: 600)
            )
        }

        let words = service.timedWords(from: attributed)
        #expect(words.count == 1)
        #expect(words.first?.text == "hello")
        #expect(words.first?.startSeconds == 1)
        #expect(words.first?.endSeconds == 2)
    }

    @Test("detectLanguageFromText recognizes clear languages")
    func detectLanguageFromClearText() {
        let service = SpeechTranscriptionService()
        #expect(service.detectLanguageFromText("This is a sample English sentence.").languageCode?.identifier == "en")
        #expect(service.detectLanguageFromText("Ceci est une phrase en français.").languageCode?.identifier == "fr")
    }
}

// MARK: - Language detection heuristics

struct LanguageDetectionPipelineTests {
    @Test("containsRecognizableSpeech requires a minimum of letters or words")
    func recognizableSpeechThresholds() {
        let service = SpeechTranscriptionService()
        #expect(!service.containsRecognizableSpeech(""))
        #expect(!service.containsRecognizableSpeech("ab"))            // too few letters
        #expect(service.containsRecognizableSpeech("abcdefgh"))       // 8 letters, single word
        #expect(service.containsRecognizableSpeech("abcd efgh"))      // 2 words with 4+ letters
    }
}

// MARK: - Audio format comparison

struct AudioFormatPipelineTests {
    @Test("formatsMatch compares sample rate, channels, format, and interleaving")
    func formatsMatchEquality() {
        let service = SpeechTranscriptionService()
        let lhs = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let same = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let differentRate = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let differentChannels = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

        #expect(service.formatsMatch(lhs, same))
        #expect(!service.formatsMatch(lhs, differentRate))
        #expect(!service.formatsMatch(lhs, differentChannels))
    }
}

// MARK: - Flashcard pipeline (parsing + batching, the deterministic half)

struct FlashcardPipelineTests {
    private func entry(id: String, text: String) -> SpeechTranscriptionService.FlashcardSourceEntry {
        SpeechTranscriptionService.FlashcardSourceEntry(id: id, startSeconds: 0, endSeconds: 1, text: text)
    }

    @Test("flashcardBatches packs entries up to the character budget")
    func flashcardBatching() {
        let service = SpeechTranscriptionService()
        let firstEntry = entry(id: "1", text: "abc")   // lineLength = 1 + 3 + 12 = 16
        let secondEntry = entry(id: "2", text: "def")
        let thirdEntry = entry(id: "3", text: "ghi")

        #expect(service.flashcardBatches(from: [firstEntry], maxCharactersPerBatch: 20).count == 1)
        // Two entries = 32 chars > 20 -> two batches.
        let twoBatches = service.flashcardBatches(from: [firstEntry, secondEntry], maxCharactersPerBatch: 20)
        #expect(twoBatches.count == 2)
        #expect(twoBatches.flatMap { $0 }.count == 2)
        // Three entries with a large budget -> one batch.
        #expect(service.flashcardBatches(from: [firstEntry, secondEntry, thirdEntry], maxCharactersPerBatch: 100).count == 1)
    }

    @Test("normalizedLanguageCode reduces identifiers to a lowercase language code")
    func normalizedLanguageCodeExtraction() {
        let service = SpeechTranscriptionService()
        #expect(service.normalizedLanguageCode(from: Locale(identifier: "en-US")) == "en")
        #expect(service.normalizedLanguageCode(from: Locale(identifier: "fr_FR")) == "fr")
        #expect(service.normalizedLanguageCode(from: Locale(identifier: "pt-BR")) == "pt")
    }

    @Test("extractJSONCodeBlock returns the fenced body and nil without a fence")
    func jsonCodeBlockExtraction() {
        let service = SpeechTranscriptionService()
        let fenced = "Here is the answer:\n```json\n{\"cards\": []}\n```\nDone."
        let body = service.extractJSONCodeBlock(from: fenced)
        #expect(body?.contains("{\"cards\": []}") == true)
        #expect(service.extractJSONCodeBlock(from: "no fence here") == nil)
    }

    @Test("extractAllJSONObjectStrings handles nesting and multiple objects")
    func jsonObjectExtraction() {
        let service = SpeechTranscriptionService()
        let text = "prefix {\"a\": {\"b\": 1}} suffix {\"c\": 2}"
        let objects = service.extractAllJSONObjectStrings(from: text)
        #expect(objects.count == 2)
        #expect(objects[0].contains("\"b\": 1"))
        #expect(objects[1].contains("\"c\": 2"))
    }

    @Test("flashcardJSONCandidates deduplicates across code blocks and inline objects")
    func flashcardJSONCandidatesDedupe() {
        let service = SpeechTranscriptionService()
        let text = "```json\n{\"a\":1}\n``` trailing {\"a\":1}"
        let candidates = service.flashcardJSONCandidates(from: text)
        // The trimmed whole text, the code-block body, and the inline object,
        // deduplicated (code-block body == inline object).
        #expect(candidates.count == 2)
    }

    @Test("decodeFlashcardModelResponse decodes cards and rejects garbage")
    func flashcardModelDecoding() {
        let service = SpeechTranscriptionService()
        let valid = #"{"cards": [{"front": "Q", "back": "A", "sourceChunkID": "c1"}]}"#
        let decoded = try? service.decodeFlashcardModelResponse(from: valid)
        #expect(decoded?.cards.count == 1)
        #expect(decoded?.cards.first?.front == "Q")
        #expect(decoded?.cards.first?.sourceChunkID == "c1")

        #expect((try? service.decodeFlashcardModelResponse(from: "not json")) == nil)
    }
}
