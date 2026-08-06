import os
import Foundation
import Speech
import AVFoundation
import AudioToolbox
import NaturalLanguage
import Translation
import FoundationModels


class SpeechTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var isSummarizing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    
    var speechAnalyzer: SpeechAnalyzer?
    var activeFlow: TranscriptionFlowKind?
    
    let minAnalysisTimeoutSeconds: TimeInterval = 60
    let analysisTimeoutMultiplier: Double = 3.0
    let maxAnalysisTimeoutSeconds: TimeInterval = 600
    private var shouldPreferAssetPipelineTranscode = true
    private let transcodePreferenceLock = NSLock()

    // Session cache: locales we’ve verified/installed during this app run
    private var preparedLocales = Set<String>()
    private let preparedLocalesLock = NSLock()

    // MARK: - Public API

    func transcribeVideo(_ video: Video, libraryManager: LibraryManager, preferredLocale: Locale? = nil) async {
        let videoTitle = video.title ?? "Unknown"
        Logger.transcription.info("Started transcribeVideo for \(videoTitle)")
        // Claim the flow atomically so transcribe/translate/summarize/flashcards
        // can never run concurrently and clobber each other's state.
        guard await claimFlow(.transcription) else { return }
        await setErrorMessage(nil)
        await setProgress(0.0)
        await setStatus("Starting transcription...")
        
        do {
            // Use the async method to get accessible video file URL, downloading if needed
            await setStatus("Accessing video file...")
            try Task.checkCancellation()
            
            let videoURL: URL
            do {
                videoURL = try await resolvedVideoURL(for: video)
                Logger.transcription.info("Transcription: Got accessible video URL: \(videoURL)")
            } catch {
                Logger.transcription.error("Transcription: Failed to get accessible video URL: \(error)")
                throw TranscriptionError.videoFileNotFound
            }
            
            await setStatus("Checking permissions...")
            try Task.checkCancellation()
            try await requestSpeechRecognitionPermission()
            await setProgress(0.1)
            
            // Determine locale to use
            let usedLocale: Locale
            if let preferredLocale {
                if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) {
                    usedLocale = equivalent
                } else {
                    throw TranscriptionError.languageNotSupported(preferredLocale)
                }
                Logger.transcription.info("Using preferred locale: \(usedLocale.identifier)")
                await setProgress(0.2)
            } else {
                await setStatus("Extracting audio sample...")
                try Task.checkCancellation()
                let sampleAudioURL = try await extractAudio(from: videoURL, duration: 30.0)
                defer { try? FileManager.default.removeItem(at: sampleAudioURL) }
                await setProgress(0.2)
                
                await setStatus("Detecting language...")
                usedLocale = try await detectLanguage(from: sampleAudioURL)
                Logger.transcription.info("DETECTED: Language locale is \(usedLocale.identifier)")
                await setProgress(0.3)
            }
            
            // Ensure model is present for the final chosen locale
            await setStatus("Preparing language model (\(usedLocale.identifier))...")
            try Task.checkCancellation()
            try await prepareModelIfNeeded(for: usedLocale)
            await setProgress(max(await getProgressOnMain(), 0.35))
            
            await setStatus("Transcribing main audio...")
            try Task.checkCancellation()
            guard let videoID = video.id else {
                throw TranscriptionError.analysisFailed("Video ID missing for timed transcript generation.")
            }

            let transcriptionOutput = try await performTranscription(
                fullAudioURL: videoURL,
                locale: usedLocale,
                videoID: videoID
            )
            await setProgress(0.9)
            
            await setStatus("Saving transcript...")
            await MainActor.run {
                guard let persistedVideo = fetchVideo(with: videoID) else { return }
                persistedVideo.transcriptText = transcriptionOutput.plainText
                persistedVideo.transcriptLanguage = usedLocale.identifier
                persistedVideo.transcriptDateGenerated = Date()
            }
            
            // Persist to disk (best effort)
            do {
                try await MainActor.run {
                    guard let persistedVideo = fetchVideo(with: videoID) else { return }
                    try libraryManager.ensureTextArtifactDirectories()
                    if let transcriptURL = libraryManager.transcriptURL(for: persistedVideo) {
                        try libraryManager.writeTextAtomically(transcriptionOutput.plainText, to: transcriptURL)
                    }
                    if let timedURL = libraryManager.timedTranscriptURL(for: persistedVideo) {
                        try libraryManager.writeTimedTranscriptAtomically(transcriptionOutput.timedTranscript, to: timedURL)
                    }
                }
            } catch {
                Logger.transcription.warning("Failed to write transcript to disk: \(error)")
            }
            
            // Automatic translation enqueueing is handled by ProcessingQueueManager
            // after this transcription task completes.
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Transcription complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            Logger.transcription.error("Transcription error: \(error)")
        }
        
        await releaseFlow(.transcription)
    }

    func translateVideo(_ video: Video, libraryManager: LibraryManager, targetLanguage: Locale.Language? = nil) async {
        guard let videoID = video.id else {
            await setErrorMessage("Video metadata is missing. Please re-import this video.")
            return
        }
        let initialState = await MainActor.run { () -> (title: String, transcript: String?, transcriptLanguage: String?) in
            guard let persistedVideo = fetchVideo(with: videoID) else {
                return ("Unknown", nil, nil)
            }
            return (persistedVideo.title ?? "Unknown", persistedVideo.transcriptText, persistedVideo.transcriptLanguage)
        }
        Logger.transcription.info("Started translateVideo for \(initialState.title)")
        guard let transcriptText = initialState.transcript,
              !transcriptText.isEmpty else { return }
        // Claim the flow atomically so transcribe/translate/summarize/flashcards
        // can never run concurrently and clobber each other's state.
        guard await claimFlow(.translation) else { return }
        await setErrorMessage(nil)
        await setProgress(0.0)
        await setStatus("Starting translation...")
        
        do {
            let timedTranscript = try await MainActor.run { () throws -> TimedTranscript in
                guard let persistedVideo = fetchVideo(with: videoID),
                      let timedTranscriptURL = libraryManager.existingTimedTranscriptURL(for: persistedVideo),
                      FileManager.default.fileExists(atPath: timedTranscriptURL.path) else {
                    throw TranscriptionError.translationFailed("Timed transcript not found. Please transcribe this video again.")
                }
                return try libraryManager.readTimedTranscript(from: timedTranscriptURL)
            }

            let computationResult = try await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    throw TranscriptionError.translationFailed("Translation service unavailable.")
                }
                return try await self.computeTranslation(
                    transcriptText: transcriptText,
                    timedTranscript: timedTranscript,
                    transcriptLanguageIdentifier: initialState.transcriptLanguage,
                    targetLanguage: targetLanguage
                )
            }.value

            if computationResult.translationSkipped {
                await setStatus("Source already matches target language.")
            }

            await setProgress(0.3)
            let translationOutput = computationResult.output
            let translatedText = translationOutput.plainText
            let targetCode = computationResult.targetLanguageIdentifier
            
            await setProgress(0.9)
            await setStatus("Saving translation...")

            await MainActor.run {
                guard let persistedVideo = fetchVideo(with: videoID) else { return }
                persistedVideo.translatedText = translatedText
                persistedVideo.translatedLanguage = targetCode
                persistedVideo.translationDateGenerated = Date()
                if let resolvedSourceLanguage = computationResult.resolvedSourceLanguageIdentifier {
                    persistedVideo.transcriptLanguage = resolvedSourceLanguage
                }
            }
            
            // Persist to disk (best effort)
            do {
                try await MainActor.run {
                    guard let persistedVideo = fetchVideo(with: videoID) else { return }
                    try libraryManager.ensureTextArtifactDirectories()
                    if let url = libraryManager.translationURL(for: persistedVideo, languageCode: targetCode) {
                        try libraryManager.writeTextAtomically(translatedText, to: url)
                    }
                    if let timedURL = libraryManager.timedTranslationURL(for: persistedVideo, languageCode: targetCode) {
                        try libraryManager.writeTimedTranslationAtomically(translationOutput.timedTranslation, to: timedURL)
                    }
                }
            } catch {
                Logger.transcription.warning("Failed to write translation to disk: \(error)")
            }
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Translation complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            Logger.transcription.error("Translation error: \(error)")
        }
        
        await releaseFlow(.translation)
    }

    // MARK: - Summarization

    func summarizeVideo(_ video: Video, libraryManager: LibraryManager, customPrompt: String? = nil) async {
        guard let videoID = video.id else {
            await setErrorMessage("Video metadata is missing. Please re-import this video.")
            return
        }
        let initialState = await MainActor.run { () -> (title: String, translated: String?, transcript: String?) in
            guard let persistedVideo = fetchVideo(with: videoID) else {
                return ("Unknown", nil, nil)
            }
            return (persistedVideo.title ?? "Unknown", persistedVideo.translatedText, persistedVideo.transcriptText)
        }
        Logger.transcription.info("Started summarizeVideo for \(initialState.title)")
        // Use translated text if available, otherwise use original transcript
        let textToSummarize: String
        if let translatedText = initialState.translated, !translatedText.isEmpty {
            textToSummarize = translatedText
        } else if let transcriptText = initialState.transcript, !transcriptText.isEmpty {
            textToSummarize = transcriptText
        } else {
            await setErrorMessage("No transcript available to summarize.")
            return
        }
        // Claim the flow atomically so transcribe/translate/summarize/flashcards
        // can never run concurrently and clobber each other's state.
        guard await claimFlow(.summarization) else { return }
        await setErrorMessage(nil)
        await setProgress(0.0)
        await setStatus("Preparing Apple Intelligence...")
        
        do {
            let finalSummary = try await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    throw TranscriptionError.summarizationFailed("Summarization service unavailable.")
                }
                let model = SystemLanguageModel.default
                switch model.availability {
                case .available:
                    break
                case .unavailable(.deviceNotEligible):
                    throw TranscriptionError.summarizationFailed("This device doesn't support Apple Intelligence.")
                case .unavailable(.appleIntelligenceNotEnabled):
                    throw TranscriptionError.summarizationFailed("Apple Intelligence is not enabled. Please enable it in System Settings.")
                case .unavailable(.modelNotReady):
                    throw TranscriptionError.summarizationFailed("Apple Intelligence model is not ready. Please try again later.")
                case .unavailable(let reason):
                    throw TranscriptionError.summarizationFailed("Apple Intelligence is unavailable: \(reason)")
                }

                await setStatus("Chunking transcript...")
                let maxContextTokens = 4096
                let targetChunkTokens = 3000
                let chunks = self.splitTextIntoChunksByBudget(textToSummarize, targetTokens: targetChunkTokens, hardLimit: maxContextTokens)
                guard !chunks.isEmpty else {
                    throw TranscriptionError.summarizationFailed("No content available after chunking.")
                }

                var chunkSummaries: [String] = []
                for (index, chunk) in chunks.enumerated() {
                    await setStatus("Summarizing chunk \(index + 1) of \(chunks.count)...")
                    await setProgress(0.1 + (0.6 * Double(index) / Double(max(1, chunks.count))))

                    let chunkSummary = try await self.summarizeChunk(chunk, customPrompt: customPrompt)
                    chunkSummaries.append(chunkSummary)
                }

                await setStatus("Combining summaries...")
                await setProgress(0.8)
                return try await self.reduceSummaries(chunkSummaries, customPrompt: customPrompt)
            }.value

            await setStatus("Saving summary...")
            await setProgress(0.95)
            await MainActor.run {
                guard let persistedVideo = fetchVideo(with: videoID) else { return }
                persistedVideo.transcriptSummary = finalSummary
                persistedVideo.summaryDateGenerated = Date()
            }
            
            // Persist to disk (best effort)
            do {
                try await MainActor.run {
                    guard let persistedVideo = fetchVideo(with: videoID) else { return }
                    try libraryManager.ensureTextArtifactDirectories()
                    if let url = libraryManager.summaryURL(for: persistedVideo) {
                        try libraryManager.writeTextAtomically(finalSummary, to: url)
                    }
                }
            } catch {
                Logger.transcription.warning("Failed to write summary to disk: \(error)")
            }
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Summary complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            Logger.transcription.error("Summarization error: \(error)")
        }
        
        await releaseFlow(.summarization)
    }

    // MARK: - Flashcards

    func generateFlashcards(
        for video: Video,
        libraryManager: LibraryManager,
        sourceMode: FlashcardsSourceMode = .autoSystemLanguage,
        targetCount: Int = 12,
        customPrompt: String? = nil
    ) async {
        guard let videoID = video.id else {
            await setErrorMessage("Video metadata is missing. Please re-import this video.")
            return
        }

        let initialState = await MainActor.run { () -> (title: String, transcriptLanguage: String?, translatedLanguage: String?) in
            guard let persistedVideo = fetchVideo(with: videoID) else {
                return ("Unknown", nil, nil)
            }
            return (
                persistedVideo.title ?? "Unknown",
                persistedVideo.transcriptLanguage,
                persistedVideo.translatedLanguage
            )
        }
        Logger.transcription.info("Started generateFlashcards for \(initialState.title)")
        // Claim the flow atomically so transcribe/translate/summarize/flashcards
        // can never run concurrently and clobber each other's state.
        guard await claimFlow(.flashcards) else { return }
        await setErrorMessage(nil)
        await setProgress(0.0)
        await setStatus("Preparing flashcards...")

        do {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            case .unavailable(.deviceNotEligible):
                throw TranscriptionError.flashcardsGenerationFailed("This device doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                throw TranscriptionError.flashcardsGenerationFailed("Apple Intelligence is not enabled. Please enable it in System Settings.")
            case .unavailable(.modelNotReady):
                throw TranscriptionError.flashcardsGenerationFailed("Apple Intelligence model is not ready. Please try again later.")
            case .unavailable(let reason):
                throw TranscriptionError.flashcardsGenerationFailed("Apple Intelligence is unavailable: \(reason)")
            }

            await setProgress(0.05)
            let resolvedSource = try await resolveFlashcardsSource(
                for: videoID,
                libraryManager: libraryManager,
                sourceMode: sourceMode,
                transcriptLanguageIdentifier: initialState.transcriptLanguage,
                translatedLanguageIdentifier: initialState.translatedLanguage
            )

            let boundedCount = max(1, targetCount)
            let generatedCards = try await generateFlashcardCandidates(
                from: resolvedSource.entries,
                targetCount: boundedCount,
                customPrompt: customPrompt
            )

            guard !generatedCards.isEmpty else {
                throw TranscriptionError.flashcardsGenerationFailed("No flashcards were generated from the available content.")
            }

            let sourceLookup = Dictionary(uniqueKeysWithValues: resolvedSource.entries.map { ($0.id, $0) })
            let cards: [Flashcard] = generatedCards.compactMap { candidate in
                guard let source = sourceLookup[candidate.sourceChunkID] else { return nil }
                return Flashcard(
                    front: candidate.front,
                    back: candidate.back,
                    startSeconds: source.startSeconds,
                    endSeconds: source.endSeconds,
                    sourceSnippet: source.text
                )
            }

            guard !cards.isEmpty else {
                throw TranscriptionError.flashcardsGenerationFailed("Generated flashcards did not contain valid source references.")
            }

            let deck = FlashcardDeck(
                videoID: videoID,
                generatedAt: Date(),
                sourceModeUsed: resolvedSource.modeUsed,
                sourceLanguageCode: resolvedSource.sourceLanguageCode,
                cards: Array(cards.prefix(boundedCount))
            )

            await setStatus("Saving flashcards...")
            await setProgress(0.95)
            try await MainActor.run {
                guard let persistedVideo = fetchVideo(with: videoID) else { return }
                try libraryManager.ensureTextArtifactDirectories()
                guard let url = libraryManager.flashcardsURL(for: persistedVideo) else {
                    throw TranscriptionError.flashcardsGenerationFailed("Could not determine flashcards storage path.")
                }
                try libraryManager.writeFlashcardDeckAtomically(deck, to: url)
            }

            await libraryManager.save()
            await setProgress(1.0)
            await setStatus("Flashcards complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            Logger.transcription.error("Flashcards error: \(error)")
        }

        await releaseFlow(.flashcards)
    }

    struct TranslationComputationResult {
        let output: TranslationOutput
        let targetLanguageIdentifier: String
        let resolvedSourceLanguageIdentifier: String?
        let translationSkipped: Bool
    }

    struct FlashcardSourceEntry: Sendable, Hashable {
        let id: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let text: String
    }

    struct ResolvedFlashcardsSource: Sendable {
        let modeUsed: FlashcardsSourceMode
        let sourceLanguageCode: String
        let entries: [FlashcardSourceEntry]
    }

    struct GeneratedFlashcardCandidate: Sendable, Hashable {
        let front: String
        let back: String
        let sourceChunkID: String
    }

    struct FlashcardModelResponse: Decodable {
        struct Card: Decodable {
            let front: String
            let back: String
            let sourceChunkID: String
        }

        let cards: [Card]
    }

    @MainActor
    func fetchVideo(with id: UUID) -> Video? {
        guard let context = LibraryManager.shared.viewContext else {
            return nil
        }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - Model preparation helpers (cache-aware)

    @MainActor
    private func resolvedVideoURL(for video: Video) async throws -> URL {
        try await video.getAccessibleFileURL(downloadIfNeeded: true)
    }

    private func localeKey(_ locale: Locale) -> String {
        locale.identifier
    }
    
    func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    func getShouldPreferAssetPipelineTranscode() -> Bool {
        transcodePreferenceLock.withLock { shouldPreferAssetPipelineTranscode }
    }

    func setShouldPreferAssetPipelineTranscode(_ value: Bool) {
        transcodePreferenceLock.withLock {
            shouldPreferAssetPipelineTranscode = value
        }
    }
    
    // Ensure required assets are installed; download only if needed.
    func prepareModelIfNeeded(for locale: Locale) async throws {
        let key = localeKey(locale)
        if preparedLocalesLock.withLock({ preparedLocales.contains(key) }) { return }
        let recognitionTranscriber = transcriber(for: locale)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [recognitionTranscriber]) {
                // Something missing — download and install
                try await request.downloadAndInstall()
            }
            // Mark prepared for this session (even if request was nil)
            _ = preparedLocalesLock.withLock { preparedLocales.insert(key) }
        } catch {
            throw TranscriptionError.assetInstallationFailed
        }
    }


}
