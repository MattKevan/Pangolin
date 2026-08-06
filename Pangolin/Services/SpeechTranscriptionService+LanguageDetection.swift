import os
import Foundation
import Speech
import AVFoundation
import NaturalLanguage
import CoreData


extension SpeechTranscriptionService {
    struct LanguageProbeResult {
        let probeLocale: Locale
        let detectedLanguageCode: String
        let supportedDetectedLocale: Locale?
        let confidence: Double
        let transcriptLength: Int

        var score: Double {
            // Confidence drives ranking; transcript length is a secondary signal.
            confidence + min(Double(transcriptLength) / 500.0, 0.25)
        }
    }

    func detectLanguage(from sampleAudioURL: URL) async throws -> Locale {
        let confidenceThreshold = 0.45

        // Fallback to system-equivalent supported locale.
        let supportedSystemLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let supportedLocaleIDs = Set(supportedLocales.map(\.identifier))

        // Probe a small, robust set to avoid false positives from a single-locale pass.
        var probeLocales: [Locale] = [supportedSystemLocale]

        if let englishLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")),
           !probeLocales.contains(where: { $0.identifier == englishLocale.identifier }) {
            probeLocales.append(englishLocale)
        }

        if let spanishLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "es-ES")),
           !probeLocales.contains(where: { $0.identifier == spanishLocale.identifier }) {
            probeLocales.append(spanishLocale)
        }

        var probeResults: [LanguageProbeResult] = []
        var foundRecognizableSpeech = false

        for (index, probeLocale) in probeLocales.enumerated() {
            do {
                await setStatus("Detecting language (\(index + 1)/\(probeLocales.count))...")
                try await prepareModelIfNeeded(for: probeLocale)

                let preliminaryOutput = try await performTranscription(
                    fullAudioURL: sampleAudioURL,
                    locale: probeLocale,
                    videoID: UUID()
                )

                if containsRecognizableSpeech(preliminaryOutput.plainText) {
                    foundRecognizableSpeech = true
                }

                if let result = await languageProbeResult(
                    from: preliminaryOutput.plainText,
                    probeLocale: probeLocale,
                    supportedLocaleIDs: supportedLocaleIDs
                ) {
                    probeResults.append(result)
                }
            } catch {
                // Non-fatal per probe: continue with remaining probes.
                continue
            }
        }

        guard foundRecognizableSpeech, !probeResults.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }

        if let bestSupported = probeResults
            .filter({ $0.supportedDetectedLocale != nil })
            .max(by: { $0.score < $1.score }),
           let supportedLocale = bestSupported.supportedDetectedLocale,
           bestSupported.confidence >= confidenceThreshold {
            Logger.transcription.info(
                "DETECTED: Chose \(supportedLocale.identifier) via probe \(bestSupported.probeLocale.identifier) (confidence: \(bestSupported.confidence), textLen: \(bestSupported.transcriptLength))"
            )
            return supportedLocale
        }

        if let bestAny = probeResults.max(by: { $0.score < $1.score }) {
            if bestAny.confidence < confidenceThreshold {
                throw TranscriptionError.noSpeechDetected
            }
            throw TranscriptionError.languageNotSupported(Locale(identifier: bestAny.detectedLanguageCode))
        }

        throw TranscriptionError.noSpeechDetected
    }

    func languageProbeResult(
        from text: String,
        probeLocale: Locale,
        supportedLocaleIDs: Set<String>
    ) async -> LanguageProbeResult? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsRecognizableSpeech(normalizedText) else { return nil }

        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(normalizedText)

        guard let (detectedLanguage, confidence) = languageRecognizer.languageHypotheses(withMaximum: 3)
            .max(by: { $0.value < $1.value }) else { return nil }

        let detectedLanguageCode = detectedLanguage.rawValue
        let detectedLocale = Locale(identifier: detectedLanguageCode)
        let supportedDetectedLocale: Locale?
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: detectedLanguage.rawValue)),
           supportedLocaleIDs.contains(supported.identifier) {
            supportedDetectedLocale = supported
        } else {
            supportedDetectedLocale = nil
        }

        return LanguageProbeResult(
            probeLocale: probeLocale,
            detectedLanguageCode: detectedLocale.identifier,
            supportedDetectedLocale: supportedDetectedLocale,
            confidence: confidence,
            transcriptLength: normalizedText.count
        )
    }

    func containsRecognizableSpeech(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let letterCount = trimmed.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if CharacterSet.letters.contains(scalar) {
                partialResult += 1
            }
        }
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count

        // Works for space-delimited and non-space-delimited writing systems.
        return letterCount >= 8 || (letterCount >= 4 && wordCount >= 2)
    }

}
