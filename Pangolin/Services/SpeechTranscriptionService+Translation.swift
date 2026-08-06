import os
import Foundation
import Translation
import SwiftUI
import CoreData

extension SpeechTranscriptionService {
    // MARK: - Translation

    func computeTranslation(
        transcriptText: String,
        timedTranscript: TimedTranscript,
        transcriptLanguageIdentifier: String?,
        targetLanguage: Locale.Language?
    ) async throws -> TranslationComputationResult {
        // Determine source language from stored metadata when available.
        var sourceLanguage: Locale.Language
        var resolvedSourceLanguageIdentifier: String?

        if let transcriptLanguageIdentifier, !transcriptLanguageIdentifier.isEmpty {
            let sourceLocale = Locale(identifier: transcriptLanguageIdentifier)
            sourceLanguage = sourceLocale.language
            if sourceLanguage.languageCode?.identifier.isEmpty ?? true {
                sourceLanguage = detectLanguageFromText(transcriptText)
                resolvedSourceLanguageIdentifier = sourceLanguage.languageCode?.identifier
            }
        } else {
            sourceLanguage = detectLanguageFromText(transcriptText)
            resolvedSourceLanguageIdentifier = sourceLanguage.languageCode?.identifier
        }

        let chosenTargetLanguage: Locale.Language = targetLanguage ?? Locale.current.language

        guard let sourceLangCode = sourceLanguage.languageCode,
              let targetLangCode = chosenTargetLanguage.languageCode else {
            throw TranscriptionError.translationNotSupported(
                sourceLanguage.languageCode?.identifier ?? "unknown",
                chosenTargetLanguage.languageCode?.identifier ?? "unknown"
            )
        }

        let sourceCode = sourceLangCode.identifier
        let targetCode = targetLangCode.identifier
        guard !sourceCode.isEmpty && !targetCode.isEmpty else {
            throw TranscriptionError.translationNotSupported(sourceCode, targetCode)
        }

        let sourceChunks = TimedTranslation.sentenceSourceChunks(from: timedTranscript)
        guard !sourceChunks.isEmpty else {
            throw TranscriptionError.translationFailed("Timed transcript has no sentence chunks available for translation.")
        }

        let translatedChunks: [TimedTranslationChunk]
        let translationSkipped: Bool
        if sourceCode == targetCode {
            translatedChunks = sourceChunks.map {
                TimedTranslationChunk(
                    id: $0.id,
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    sourceText: $0.text,
                    targetText: $0.text
                )
            }
            translationSkipped = true
        } else {
            translatedChunks = try await translateSentenceChunks(
                sourceChunks,
                from: sourceLanguage,
                to: chosenTargetLanguage
            )
            translationSkipped = false
        }

        let translatedText = translatedChunks
            .map(\.targetText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let timedTranslation = TimedTranslation(
            videoID: timedTranscript.videoID,
            sourceLocaleIdentifier: sourceCode,
            targetLocaleIdentifier: targetCode,
            generatedAt: Date(),
            chunks: translatedChunks
        )

        return TranslationComputationResult(
            output: TranslationOutput(plainText: translatedText, timedTranslation: timedTranslation),
            targetLanguageIdentifier: targetCode,
            resolvedSourceLanguageIdentifier: resolvedSourceLanguageIdentifier,
            translationSkipped: translationSkipped
        )
    }

    func translateSentenceChunks(
        _ sourceChunks: [TimedTranslation.SourceChunk],
        from sourceLanguage: Locale.Language,
        to targetLanguage: Locale.Language
    ) async throws -> [TimedTranslationChunk] {
        await setStatus("Checking translation models...")
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            try await session.prepareTranslation()
        } catch {
            throw mapTranslationError(error, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        }
        await setStatus("Translating \(sourceChunks.count) chunks...")

        let requests = sourceChunks.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        var translatedByID: [String: String] = [:]

        do {
            for try await response in session.translate(batch: requests) {
                guard let clientIdentifier = response.clientIdentifier else { continue }
                translatedByID[clientIdentifier] = response.targetText
            }
        } catch {
            throw mapTranslationError(error, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        }

        return try Self.assembleTimedTranslationChunks(
            sourceChunks: sourceChunks,
            translatedTextsByID: translatedByID
        )
    }

    static func assembleTimedTranslationChunks(
        sourceChunks: [TimedTranslation.SourceChunk],
        translatedTextsByID: [String: String]
    ) throws -> [TimedTranslationChunk] {
        var chunks: [TimedTranslationChunk] = []
        chunks.reserveCapacity(sourceChunks.count)

        for sourceChunk in sourceChunks {
            guard let translated = translatedTextsByID[sourceChunk.id] else {
                throw TranscriptionError.translationFailed("Missing translated text for chunk '\(sourceChunk.id)'.")
            }
            let targetText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetText.isEmpty else {
                throw TranscriptionError.translationFailed("Received empty translation for chunk '\(sourceChunk.id)'.")
            }

            chunks.append(
                TimedTranslationChunk(
                    id: sourceChunk.id,
                    startSeconds: sourceChunk.startSeconds,
                    endSeconds: sourceChunk.endSeconds,
                    sourceText: sourceChunk.text,
                    targetText: targetText
                )
            )
        }

        return chunks
    }

}
