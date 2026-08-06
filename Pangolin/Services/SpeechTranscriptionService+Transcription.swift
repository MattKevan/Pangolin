import os
import Foundation
import Speech
import AVFoundation
import NaturalLanguage
import Translation
import FoundationModels
import CoreData
import SwiftUI


extension SpeechTranscriptionService {
    func performTranscription(fullAudioURL: URL, locale: Locale, videoID: UUID) async throws -> TranscriptionOutput {
        // Ensure model is prepared (fast if already installed or prepared this session)
        try await prepareModelIfNeeded(for: locale)

        // If video, extract audio; if audio already, use directly
        let fileExtension = fullAudioURL.pathExtension.lowercased()
        let audioExtensions = ["m4a", "mp3", "wav", "aac", "caf", "aiff"]
        let asset = AVURLAsset(url: fullAudioURL)
        let duration = try await asset.load(.duration)

        let audioURLToTranscribe: URL
        if audioExtensions.contains(fileExtension) {
            audioURLToTranscribe = fullAudioURL
        } else {
            audioURLToTranscribe = try await extractAudio(from: fullAudioURL, duration: CMTimeGetSeconds(duration))
        }

        // Diagnostics: log source format and size
        if let sourceFile = try? AVAudioFile(forReading: audioURLToTranscribe) {
            Logger.transcription.info("Source audio format: \(sourceFile.processingFormat)")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURLToTranscribe.path),
           let size = attrs[FileAttributeKey.size] as? NSNumber {
            Logger.transcription.info("Source audio size (bytes): \(size)")
        }
        let formatTranscriber = transcriber(for: locale)
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [formatTranscriber]) else {
            throw TranscriptionError.analysisFailed("No compatible audio format available for the speech analyzer.")
        }
        Logger.transcription.info("Analyzer target format: \(targetFormat)")

        // Convert to analyzer's preferred format (typically PCM). If decoding fails for the
        // intermediate source file, fall back to using the source format directly.
        var workingAudioURL: URL?
        var convertedPCMURL: URL?
        let preferAssetPipeline = getShouldPreferAssetPipelineTranscode()
        if preferAssetPipeline {
            Logger.transcription.info("Using preferred asset-pipeline transcode path")
            do {
                let pcmURL = try await transcodeAudioWithAssetPipeline(from: audioURLToTranscribe, to: targetFormat)
                convertedPCMURL = pcmURL
                workingAudioURL = pcmURL
                let recoveredFile = try AVAudioFile(forReading: pcmURL)
                Logger.transcription.info("Asset-pipeline transcode format: \(recoveredFile.processingFormat)")
            } catch {
                Logger.transcription.warning("Preferred asset-pipeline transcode failed; retrying direct converter path...")
                let pcmURL = try convertAudio(audioURLToTranscribe, to: targetFormat)
                convertedPCMURL = pcmURL
                workingAudioURL = pcmURL
            }
        } else {
            do {
                let pcmURL = try convertAudio(audioURLToTranscribe, to: targetFormat)
                convertedPCMURL = pcmURL
                workingAudioURL = pcmURL
                if let attrs = try? FileManager.default.attributesOfItem(atPath: pcmURL.path),
                   let size = attrs[FileAttributeKey.size] as? NSNumber {
                    Logger.transcription.info("Converted PCM size (bytes): \(size)")
                }
            } catch let conversionError as TranscriptionError {
                switch conversionError {
                case .analysisFailed(let reason) where reason.contains("Audio conversion source read failed"):
                    Logger.transcription.warning("Conversion decode failed; attempting asset-pipeline transcode fallback...")
                    let recoveredPCMURL = try await transcodeAudioWithAssetPipeline(from: audioURLToTranscribe, to: targetFormat)
                    convertedPCMURL = recoveredPCMURL
                    workingAudioURL = recoveredPCMURL
                    let recoveredFile = try AVAudioFile(forReading: recoveredPCMURL)
                    Logger.transcription.warning("Asset-pipeline fallback succeeded: \(recoveredFile.processingFormat)")
                    setShouldPreferAssetPipelineTranscode(true)
                default:
                    throw conversionError
                }
            }
        }
        guard let workingAudioURL else {
            throw TranscriptionError.analysisFailed("Failed to prepare working audio URL for transcription.")
        }

        defer {
            if let convertedPCMURL {
                try? FileManager.default.removeItem(at: convertedPCMURL)
            }
        }

        let probeAudioFile = try AVAudioFile(forReading: workingAudioURL)
        let audioDurationSeconds = Double(probeAudioFile.length) / probeAudioFile.fileFormat.sampleRate
        let analysisTimeout = min(
            maxAnalysisTimeoutSeconds,
            max(minAnalysisTimeoutSeconds, audioDurationSeconds * analysisTimeoutMultiplier)
        )

        var lastError: Error?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let audioFile = try AVAudioFile(forReading: workingAudioURL)
            let transcriber = transcriber(for: locale)
            let audioFormat = audioFile.processingFormat
            Logger.transcription.info("Analyzer input format for attempt \(attempt + 1): \(audioFormat)")

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            await MainActor.run {
                self.speechAnalyzer = analyzer
            }

            await setStatus("Preparing speech analyzer...")
            let prepareStart = Date()
            try await analyzer.prepareToAnalyze(in: audioFormat)
            Logger.transcription.info("prepareToAnalyze: \(Date().timeIntervalSince(prepareStart))s")

            let resultsTask = Task { () -> TranscriptionOutput in
                try await collectFinalResults(from: transcriber, videoID: videoID, locale: locale)
            }

            do {
                await setStatus("Analyzing audio (\(Int(analysisTimeout))s timeout cap)...")
                let analyzeStart = Date()
                let lastSampleTime = try await analyzeSequenceWithTimeout(analyzer: analyzer, audioFile: audioFile, timeoutSeconds: analysisTimeout)
                Logger.transcription.info("analyzeSequence: \(Date().timeIntervalSince(analyzeStart))s")

                let finalizeStart = Date()
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                Logger.transcription.info("finalizeAndFinish: \(Date().timeIntervalSince(finalizeStart))s")

                let resultsStart = Date()
                let output = try await awaitResultsWithTimeout(resultsTask, timeoutSeconds: max(30, analysisTimeout / 2), analyzer: analyzer)
                Logger.transcription.info("resultsTask completion: \(Date().timeIntervalSince(resultsStart))s")

                if !containsRecognizableSpeech(output.plainText) {
                    throw TranscriptionError.noSpeechDetected
                }
                if !audioExtensions.contains(fileExtension) {
                    try? FileManager.default.removeItem(at: audioURLToTranscribe)
                }
                return output
            } catch {
                lastError = error
                resultsTask.cancel()
                _ = try? await resultsTask.value
                await analyzer.cancelAndFinishNow()
                if attempt == 0 {
                    Logger.transcription.warning("Transcription attempt \(attempt + 1) failed: \(error). Retrying once...")
                    continue
                }
                let desc = String(describing: error)
                if desc.contains("nilError") || desc.contains("Foundation._GenericObjCError") {
                    throw TranscriptionError.analysisFailed("Audio decoding failed during transcription. Try re-encoding the source to uncompressed PCM (WAV/CAF) and retry.")
                }
                if desc.contains("Reporter disconnected") {
                    throw TranscriptionError.analysisFailed("Speech analyzer disconnected during transcription. Please retry.")
                }
                throw error
            }
        }

        throw lastError ?? TranscriptionError.analysisFailed("Transcription failed unexpectedly.")
    }

    func collectFinalResults(from transcriber: SpeechTranscriber, videoID: UUID, locale: Locale) async throws -> TranscriptionOutput {
        var segments: [TimedSegment] = []
        for try await result in transcriber.results {
            if Task.isCancelled {
                throw TranscriptionError.analysisFailed("Transcription cancelled.")
            }
            if result.isFinal {
                let segmentText = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segmentText.isEmpty else { continue }

                let segmentStart = seconds(from: result.range.start)
                let segmentEnd = max(segmentStart, seconds(from: CMTimeRangeGetEnd(result.range)))
                let runWords = timedWords(from: result.text)
                let words = runWords.isEmpty
                    ? Self.proportionalWordTimingTokens(
                        text: segmentText,
                        startSeconds: segmentStart,
                        endSeconds: segmentEnd
                    )
                    : runWords

                segments.append(
                    TimedSegment(
                        startSeconds: segmentStart,
                        endSeconds: segmentEnd,
                        text: segmentText,
                        words: words
                    )
                )
            }
        }
        let plainText = segments.map(\.text).joined(separator: " ")
        let timedTranscript = TimedTranscript(
            videoID: videoID,
            localeIdentifier: locale.identifier,
            generatedAt: Date(),
            segments: segments
        )
        return TranscriptionOutput(plainText: plainText, timedTranscript: timedTranscript)
    }

    func timedWords(from text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            guard let runTimeRange = run.attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                continue
            }

            let runText = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !runText.isEmpty else { continue }

            let start = seconds(from: runTimeRange.start)
            let end = max(start, seconds(from: CMTimeRangeGetEnd(runTimeRange)))
            words.append(contentsOf: Self.proportionalWordTimingTokens(text: runText, startSeconds: start, endSeconds: end))
        }
        return words.sorted { lhs, rhs in
            if lhs.startSeconds == rhs.startSeconds {
                return lhs.endSeconds < rhs.endSeconds
            }
            return lhs.startSeconds < rhs.startSeconds
        }
    }

    func seconds(from time: CMTime) -> TimeInterval {
        let value = CMTimeGetSeconds(time)
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    static func proportionalWordTimingTokens(
        text: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval
    ) -> [TimedWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let start = max(0, startSeconds)
        let end = max(start, endSeconds)
        let duration = end - start
        if duration == 0 {
            return tokens.map { TimedWord(startSeconds: start, endSeconds: end, text: $0) }
        }

        let weights = tokens.map { max(1, $0.count) }
        let totalWeight = max(1, weights.reduce(0, +))
        var cursor = start
        var words: [TimedWord] = []
        words.reserveCapacity(tokens.count)

        for index in tokens.indices {
            let tokenEnd: TimeInterval
            if index == tokens.indices.last {
                tokenEnd = end
            } else {
                let fraction = Double(weights[index]) / Double(totalWeight)
                tokenEnd = min(end, max(cursor, cursor + (duration * fraction)))
            }

            words.append(
                TimedWord(
                    startSeconds: cursor,
                    endSeconds: tokenEnd,
                    text: tokens[index]
                )
            )
            cursor = tokenEnd
        }

        return words
    }

    func awaitResultsWithTimeout(_ task: Task<TranscriptionOutput, Error>, timeoutSeconds: TimeInterval, analyzer: SpeechAnalyzer) async throws -> TranscriptionOutput {
        try await withThrowingTaskGroup(of: TranscriptionOutput.self) { group in
            group.addTask {
                return try await task.value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                task.cancel()
                await analyzer.cancelAndFinishNow()
                throw TranscriptionError.analysisFailed("Transcription results stalled (timeout).")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func analyzeSequenceWithTimeout(analyzer: SpeechAnalyzer, audioFile: AVAudioFile, timeoutSeconds: TimeInterval) async throws -> CMTime? {
        try await withThrowingTaskGroup(of: CMTime?.self) { group in
            group.addTask {
                return try await analyzer.analyzeSequence(from: audioFile)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                await analyzer.cancelAndFinishNow()
                throw TranscriptionError.analysisFailed("Transcription analysis stalled (timeout).")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func cancelCurrentTranscription() async {
        let analyzer = await MainActor.run { self.speechAnalyzer }
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        await setErrorMessage("Transcription cancelled.")
    }

    func mapTranslationError(
        _ error: Error,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language
    ) -> Error {
        let sourceCode = sourceLanguage.languageCode?.identifier ?? "unknown"
        let targetCode = targetLanguage.languageCode?.identifier ?? "unknown"

        if let translationError = error as? TranslationError,
           String(describing: translationError).contains("notInstalled") {
            return TranscriptionError.translationModelsNotInstalled(sourceCode, targetCode)
        }

        if error.localizedDescription.contains("not supported") {
            return TranscriptionError.translationNotSupported(sourceCode, targetCode)
        }

        if error.localizedDescription.contains("notInstalled") || error.localizedDescription.contains("Code=16") {
            return TranscriptionError.translationModelsNotInstalled(sourceCode, targetCode)
        }

        return TranscriptionError.translationFailed(error.localizedDescription)
    }

    func detectLanguageFromText(_ text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else {
            return Locale.current.language
        }
        return Locale(identifier: code).language
    }
    
}
