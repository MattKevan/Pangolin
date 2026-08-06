import os
import Foundation
import SwiftUI
import CoreData
import FoundationModels

extension SpeechTranscriptionService {
    // MARK: - Flashcards

    func resolveFlashcardsSource(
        for videoID: UUID,
        libraryManager: LibraryManager,
        sourceMode: FlashcardsSourceMode,
        transcriptLanguageIdentifier: String?,
        translatedLanguageIdentifier: String?
    ) async throws -> ResolvedFlashcardsSource {
        let transcriptData = try await MainActor.run { () throws -> (languageCode: String, entries: [FlashcardSourceEntry]) in
            guard let persistedVideo = fetchVideo(with: videoID),
                  let timedURL = libraryManager.existingTimedTranscriptURL(for: persistedVideo),
                  FileManager.default.fileExists(atPath: timedURL.path) else {
                throw TranscriptionError.flashcardsGenerationFailed("Timed transcript not found. Please transcribe this video again.")
            }

            let transcript = try libraryManager.readTimedTranscript(from: timedURL)
            let entries = transcript.makeChunkIndex().allEntries.map {
                FlashcardSourceEntry(
                    id: $0.id.uuidString,
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    text: $0.text
                )
            }
            guard !entries.isEmpty else {
                throw TranscriptionError.flashcardsGenerationFailed("Transcript has no timed chunks to build flashcards from.")
            }
            let trimmedTranscriptLanguage = transcriptLanguageIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let languageCode = trimmedTranscriptLanguage.isEmpty ? transcript.localeIdentifier : trimmedTranscriptLanguage
            return (languageCode, entries)
        }

        let translationData: (languageCode: String, entries: [FlashcardSourceEntry])? = try await MainActor.run { () throws -> (String, [FlashcardSourceEntry])? in
            guard let persistedVideo = fetchVideo(with: videoID),
                  let translatedLanguageIdentifier,
                  !translatedLanguageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let timedURL = libraryManager.existingTimedTranslationURL(for: persistedVideo, languageCode: translatedLanguageIdentifier),
                  FileManager.default.fileExists(atPath: timedURL.path) else {
                return nil
            }

            let translation = try libraryManager.readTimedTranslation(from: timedURL)
            let entries = translation.makeChunkIndex().allEntries.map {
                FlashcardSourceEntry(
                    id: $0.id,
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    text: $0.text
                )
            }
            guard !entries.isEmpty else { return nil }
            return (translation.targetLocaleIdentifier, entries)
        }

        switch sourceMode {
        case .transcript:
            return ResolvedFlashcardsSource(
                modeUsed: .transcript,
                sourceLanguageCode: transcriptData.languageCode,
                entries: transcriptData.entries
            )
        case .translation:
            guard let translationData else {
                throw TranscriptionError.flashcardsGenerationFailed("Translation data is unavailable. Generate a translation first or use transcript source.")
            }
            return ResolvedFlashcardsSource(
                modeUsed: .translation,
                sourceLanguageCode: translationData.languageCode,
                entries: translationData.entries
            )
        case .autoSystemLanguage:
            if shouldPreferTranslationForAutoSource(transcriptLanguageIdentifier: transcriptData.languageCode),
               let translationData {
                return ResolvedFlashcardsSource(
                    modeUsed: .translation,
                    sourceLanguageCode: translationData.languageCode,
                    entries: translationData.entries
                )
            }

            if shouldPreferTranslationForAutoSource(transcriptLanguageIdentifier: transcriptData.languageCode),
               translationData == nil {
                await setStatus("Translation unavailable, using transcript for flashcards.")
            }

            return ResolvedFlashcardsSource(
                modeUsed: .transcript,
                sourceLanguageCode: transcriptData.languageCode,
                entries: transcriptData.entries
            )
        }
    }

    func shouldPreferTranslationForAutoSource(transcriptLanguageIdentifier: String?) -> Bool {
        guard let transcriptLanguageIdentifier,
              !transcriptLanguageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        guard let transcriptLanguageCode = normalizedLanguageCode(from: Locale(identifier: transcriptLanguageIdentifier)),
              let systemLanguageCode = normalizedLanguageCode(from: .autoupdatingCurrent) else {
            return false
        }

        return transcriptLanguageCode != systemLanguageCode
    }

    func normalizedLanguageCode(from locale: Locale) -> String? {
        let code = locale.language.languageCode?.identifier
            ?? locale.identifier.split(separator: "-").first.map(String.init)
            ?? locale.identifier.split(separator: "_").first.map(String.init)
        return code?.lowercased()
    }

    func generateFlashcardCandidates(
        from entries: [FlashcardSourceEntry],
        targetCount: Int,
        customPrompt: String?
    ) async throws -> [GeneratedFlashcardCandidate] {
        let batches = flashcardBatches(from: entries, maxCharactersPerBatch: 6_000)
        guard !batches.isEmpty else {
            throw TranscriptionError.flashcardsGenerationFailed("No content available to generate flashcards.")
        }

        let maxBatchesToProcess = max(1, min(batches.count, targetCount))
        var collected: [GeneratedFlashcardCandidate] = []
        var dedupe = Set<String>()

        for index in 0..<maxBatchesToProcess {
            let batch = batches[index]
            let remainingBatches = maxBatchesToProcess - index
            let remainingSlots = max(1, targetCount - collected.count)
            let batchTarget = max(1, remainingSlots / max(1, remainingBatches))

            await setStatus("Generating flashcards batch \(index + 1) of \(maxBatchesToProcess)...")
            await setProgress(0.1 + (0.75 * Double(index) / Double(max(1, maxBatchesToProcess))))

            let generated = try await generateFlashcardCandidatesForBatch(
                batch,
                desiredCount: batchTarget,
                customPrompt: customPrompt
            )

            for item in generated {
                let key = "\(item.front.lowercased())\n\(item.back.lowercased())"
                if dedupe.contains(key) { continue }
                dedupe.insert(key)
                collected.append(item)
                if collected.count >= targetCount {
                    return collected
                }
            }
        }

        return collected
    }

    func flashcardBatches(
        from entries: [FlashcardSourceEntry],
        maxCharactersPerBatch: Int
    ) -> [[FlashcardSourceEntry]] {
        var batches: [[FlashcardSourceEntry]] = []
        var currentBatch: [FlashcardSourceEntry] = []
        var currentCharCount = 0

        for entry in entries {
            let lineLength = entry.id.count + entry.text.count + 12
            if !currentBatch.isEmpty && currentCharCount + lineLength > maxCharactersPerBatch {
                batches.append(currentBatch)
                currentBatch = []
                currentCharCount = 0
            }
            currentBatch.append(entry)
            currentCharCount += lineLength
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }

    func generateFlashcardCandidatesForBatch(
        _ batch: [FlashcardSourceEntry],
        desiredCount: Int,
        customPrompt: String?
    ) async throws -> [GeneratedFlashcardCandidate] {
        try await generateFlashcardCandidatesForBatch(
            batch,
            desiredCount: desiredCount,
            customPrompt: customPrompt,
            retryDepth: 0
        )
    }

    func generateFlashcardCandidatesForBatch(
        _ batch: [FlashcardSourceEntry],
        desiredCount: Int,
        customPrompt: String?,
        retryDepth: Int
    ) async throws -> [GeneratedFlashcardCandidate] {
        let instructions = Instructions(flashcardsInstructions(from: customPrompt))

        let sourceLines = batch.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Generate \(max(1, desiredCount)) flashcards from these timed source chunks.
        Use only sourceChunkID values exactly as provided in brackets.

        Source chunks:
        \(sourceLines)
        """

        let responseText: String
        do {
            responseText = try await respondWithFreshLanguageModelSession(
                prompt: prompt,
                instructions: instructions
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard isLanguageModelContextWindowExceededError(error) else {
                throw error
            }

            let maxRetryDepth = 6
            guard retryDepth < maxRetryDepth else {
                throw TranscriptionError.flashcardsGenerationFailed(
                    "Flashcards content exceeds the model context window. Try fewer cards or a shorter custom prompt."
                )
            }

            if batch.count > 1 {
                let midpoint = max(1, batch.count / 2)
                let left = Array(batch[..<midpoint])
                let right = Array(batch[midpoint...])
                let leftTarget = max(1, desiredCount / 2)
                let rightTarget = max(1, desiredCount - leftTarget)

                let leftCards = try await generateFlashcardCandidatesForBatch(
                    left,
                    desiredCount: leftTarget,
                    customPrompt: customPrompt,
                    retryDepth: retryDepth + 1
                )
                let rightCards = try await generateFlashcardCandidatesForBatch(
                    right,
                    desiredCount: rightTarget,
                    customPrompt: customPrompt,
                    retryDepth: retryDepth + 1
                )

                return Array((leftCards + rightCards).prefix(max(1, desiredCount)))
            }

            guard let only = batch.first else {
                throw TranscriptionError.flashcardsGenerationFailed("No content available to generate flashcards.")
            }
            let shortenedBatch = [
                FlashcardSourceEntry(
                    id: only.id,
                    startSeconds: only.startSeconds,
                    endSeconds: only.endSeconds,
                    text: String(only.text.prefix(max(120, only.text.count / 2)))
                )
            ]
            return try await generateFlashcardCandidatesForBatch(
                shortenedBatch,
                desiredCount: max(1, desiredCount),
                customPrompt: customPrompt,
                retryDepth: retryDepth + 1
            )
        }

        let decoded = try decodeFlashcardModelResponse(from: responseText)
        let validIDs = Set(batch.map(\.id))
        let mapped = decoded.cards.compactMap { card -> GeneratedFlashcardCandidate? in
            let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceChunkID = card.sourceChunkID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty, validIDs.contains(sourceChunkID) else {
                return nil
            }
            return GeneratedFlashcardCandidate(front: front, back: back, sourceChunkID: sourceChunkID)
        }

        return mapped
    }

    func flashcardsInstructions(from customPrompt: String?) -> String {
        let userPrompt = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customSection = userPrompt.isEmpty
            ? "Prefer concise Q/A cards that emphasize key ideas and facts."
            : userPrompt

        return """
        You generate Anki-style flashcards from transcript chunks.
        Return JSON only, no markdown, no prose.
        The JSON format must be:
        {
          "cards": [
            {
              "front": "Question or prompt",
              "back": "Answer",
              "sourceChunkID": "chunk-id"
            }
          ]
        }
        Keep each front/back concise and specific.
        Use only sourceChunkID values that appear in the provided source.
        \(customSection)
        """
    }

    func decodeFlashcardModelResponse(from responseText: String) throws -> FlashcardModelResponse {
        let decoder = JSONDecoder()
        let candidates = flashcardJSONCandidates(from: responseText)

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }

            if let decoded = try? decoder.decode(FlashcardModelResponse.self, from: data) {
                return decoded
            }

            if let decodedCards = try? decoder.decode([FlashcardModelResponse.Card].self, from: data) {
                return FlashcardModelResponse(cards: decodedCards)
            }
        }

        throw TranscriptionError.flashcardsGenerationFailed("Model returned an invalid flashcards format.")
    }

    func flashcardJSONCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ candidate: String?) {
            guard let candidate else { return }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            candidates.append(trimmed)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        append(trimmed)

        if let codeBlock = extractJSONCodeBlock(from: text) {
            append(codeBlock)
        }

        let objects = extractAllJSONObjectStrings(from: text)
        for object in objects {
            append(object)
        }

        return candidates
    }

    func extractJSONCodeBlock(from text: String) -> String? {
        guard let openFenceRange = text.range(of: "```json") ?? text.range(of: "```"),
              let closeFenceRange = text.range(of: "```", range: openFenceRange.upperBound..<text.endIndex) else {
            return nil
        }
        let body = text[openFenceRange.upperBound..<closeFenceRange.lowerBound]
        return String(body)
    }

    func extractAllJSONObjectStrings(from text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var inString = false
        var escape = false
        var objectStart: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]

            if inString {
                if escape {
                    escape = false
                } else if char == "\\" {
                    escape = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    if depth == 0 {
                        objectStart = index
                    }
                    depth += 1
                } else if char == "}" {
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let start = objectStart {
                            objects.append(String(text[start...index]))
                            objectStart = nil
                        }
                    }
                }
            }

            index = text.index(after: index)
        }

        return objects
    }

}
