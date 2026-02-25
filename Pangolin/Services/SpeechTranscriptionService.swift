import Foundation
import Speech
import AVFoundation
import AudioToolbox
import NaturalLanguage
import Translation
import FoundationModels

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case languageNotSupported(Locale)
    case audioExtractionFailed
    case videoFileNotFound
    case noSpeechDetected
    case assetInstallationFailed
    case analysisFailed(String)
    case translationNotSupported(String, String)
    case translationFailed(String)
    case translationModelsNotInstalled(String, String)
    case summarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission was denied."
        case .languageNotSupported(let locale):
            let localized = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            return "Detected language '\(localized)' (\(locale.identifier)) is not supported for transcription on this device."
        case .audioExtractionFailed:
            return "Failed to extract a usable audio track from the video file."
        case .videoFileNotFound:
            return "The video file could not be found. It may have been moved or deleted."
        case .noSpeechDetected:
            return "No recognizable speech could be detected in the video's audio track."
        case .assetInstallationFailed:
            return "Failed to download required language models. Please check your internet connection."
        case .analysisFailed(let reason):
            return "The transcription analysis failed: \(reason)"
        case .translationNotSupported(let from, let to):
            return "Translation from \(from) to \(to) is not supported on this device."
        case .translationFailed(let reason):
            return "Translation failed: \(reason)"
        case .translationModelsNotInstalled(let from, let to):
            return "Translation models for \(from) to \(to) are not installed on this system."
        case .summarizationFailed(let reason):
            return "Summarization failed: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Please go to System Settings > Privacy & Security > Speech Recognition and grant access to Pangolin."
        case .languageNotSupported:
            return "Try selecting a supported language manually in Transcript Controls, or connect to the internet so additional language assets can be installed."
        case .audioExtractionFailed:
            return "Try converting the video to a standard format like MP4 and re-importing it."
        case .videoFileNotFound:
            return "Please re-import the video into your Pangolin library."
        case .noSpeechDetected:
            return "The audio may be silent/noisy. Verify audio playback, then retry or select the language manually in Transcript Controls."
        case .assetInstallationFailed:
            return "Ensure you have a stable internet connection and sufficient disk space, then try again."
        case .analysisFailed:
            return "This may be a temporary issue with the Speech framework. Please try again later."
        case .translationNotSupported:
            return "Enable translation languages in System Settings > General > Language & Region."
        case .translationFailed:
            return "Check your internet connection and try again. Translation requires network access and may need to download translation models."
        case .translationModelsNotInstalled:
            return "Go to System Settings → General → Language & Region → Translation Languages to download the required translation models, then try again."
        case .summarizationFailed:
            return "Ensure Apple Intelligence is enabled in System Settings and try again. Summarisation requires Apple Intelligence to be active."
        }
    }
}

struct TranscriptionOutput: Sendable {
    let plainText: String
    let timedTranscript: TimedTranscript
}

struct TranslationOutput: Sendable {
    let plainText: String
    let timedTranslation: TimedTranslation
}

class SpeechTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var isSummarizing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    
    private var speechAnalyzer: SpeechAnalyzer?
    private var translationSession: TranslationSession?
    
    private let minAnalysisTimeoutSeconds: TimeInterval = 60
    private let analysisTimeoutMultiplier: Double = 3.0
    private let maxAnalysisTimeoutSeconds: TimeInterval = 600
    private var shouldPreferAssetPipelineTranscode = true
    private let transcodePreferenceLock = NSLock()

    // Session cache: locales we’ve verified/installed during this app run
    private var preparedLocales = Set<String>()
    private let preparedLocalesLock = NSLock()

    // MARK: - Public API

    func transcribeVideo(_ video: Video, libraryManager: LibraryManager, preferredLocale: Locale? = nil) async {
        let videoTitle = video.title ?? "Unknown"
        print("🟢 Started transcribeVideo for \(videoTitle)")
        // Avoid publishing during the same view update cycle that triggered the call.
        await Task.yield()
        guard !(await isTranscribingOnMain()) else { return }
        
        await setTranscribingState(isTranscribing: true, isSummarizing: false)
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
                print("🎬 Transcription: Got accessible video URL: \(videoURL)")
            } catch {
                print("🚨 Transcription: Failed to get accessible video URL: \(error)")
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
                print("🧭 Using preferred locale: \(usedLocale.identifier)")
                await setProgress(0.2)
            } else {
                await setStatus("Extracting audio sample...")
                try Task.checkCancellation()
                let sampleAudioURL = try await extractAudio(from: videoURL, duration: 30.0)
                defer { try? FileManager.default.removeItem(at: sampleAudioURL) }
                await setProgress(0.2)
                
                await setStatus("Detecting language...")
                usedLocale = try await detectLanguage(from: sampleAudioURL)
                print("🧠 DETECTED: Language locale is \(usedLocale.identifier)")
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
                print("⚠️ Failed to write transcript to disk: \(error)")
            }
            
            // Automatic translation enqueueing is handled by ProcessingQueueManager
            // after this transcription task completes.
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Transcription complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            print("🚨 Transcription error: \(error)")
        }
        
        await setTranscribingState(isTranscribing: false, isSummarizing: false)
        
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
        print("🟢 Started translateVideo for \(initialState.title)")
        // Avoid publishing during the same view update cycle that triggered the call.
        await Task.yield()
        guard !(await isTranscribingOnMain()),
              let transcriptText = initialState.transcript,
              !transcriptText.isEmpty else { return }
        
        await setTranscribingState(isTranscribing: true, isSummarizing: false)
        await setErrorMessage(nil)
        await setProgress(0.0)
        await setStatus("Starting translation...")
        
        do {
            let timedTranscript = try await MainActor.run { () throws -> TimedTranscript in
                guard let persistedVideo = fetchVideo(with: videoID),
                      let timedTranscriptURL = libraryManager.timedTranscriptURL(for: persistedVideo),
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
                print("⚠️ Failed to write translation to disk: \(error)")
            }
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Translation complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            print("🚨 Translation error: \(error)")
        }
        
        await setTranscribingState(isTranscribing: false, isSummarizing: false)
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
        print("🟢 Started summarizeVideo for \(initialState.title)")
        // Avoid publishing during the same view update cycle that triggered the call.
        await Task.yield()
        guard !(await isTranscribingOnMain()) else { return }
        
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
        
        await setTranscribingState(isTranscribing: true, isSummarizing: true)
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
                print("⚠️ Failed to write summary to disk: \(error)")
            }
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Summary complete!")
        } catch {
            await setErrorMessage(userVisibleMessage(for: error))
            print("🚨 Summarization error: \(error)")
        }
        
        await setTranscribingState(isTranscribing: false, isSummarizing: false)
    }

    private struct TranslationComputationResult {
        let output: TranslationOutput
        let targetLanguageIdentifier: String
        let resolvedSourceLanguageIdentifier: String?
        let translationSkipped: Bool
    }

    @MainActor
    private func fetchVideo(with id: UUID) -> Video? {
        guard let context = LibraryManager.shared.viewContext else {
            return nil
        }
        let request = Video.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func computeTranslation(
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

    private func translateSentenceChunks(
        _ sourceChunks: [TimedTranslation.SourceChunk],
        from sourceLanguage: Locale.Language,
        to targetLanguage: Locale.Language
    ) async throws -> [TimedTranslationChunk] {
        await setStatus("Checking translation models...")
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        await MainActor.run {
            self.translationSession = session
        }

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

    // MARK: - Model preparation helpers (cache-aware)

    @MainActor
    private func resolvedVideoURL(for video: Video) async throws -> URL {
        try await video.getAccessibleFileURL(downloadIfNeeded: true)
    }

    private func localeKey(_ locale: Locale) -> String {
        locale.identifier
    }
    
    private func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func getShouldPreferAssetPipelineTranscode() -> Bool {
        transcodePreferenceLock.withLock { shouldPreferAssetPipelineTranscode }
    }

    private func setShouldPreferAssetPipelineTranscode(_ value: Bool) {
        transcodePreferenceLock.withLock {
            shouldPreferAssetPipelineTranscode = value
        }
    }
    
    // Returns true if all required assets for the transcriber are already installed.
    private func isModelInstalled(for locale: Locale) async -> Bool {
        let key = localeKey(locale)
        if preparedLocalesLock.withLock({ preparedLocales.contains(key) }) { return true }
        do {
            let t = transcriber(for: locale)
            // If nil, nothing to install — model is present
            let request = try await AssetInventory.assetInstallationRequest(supporting: [t])
            return request == nil
        } catch {
            // If the check itself fails, be conservative and report not installed,
            // the caller may attempt a download (which can also fail with a clear error).
            return false
        }
    }
    
    // Ensure required assets are installed; download only if needed.
    private func prepareModelIfNeeded(for locale: Locale) async throws {
        let key = localeKey(locale)
        if preparedLocalesLock.withLock({ preparedLocales.contains(key) }) { return }
        let t = transcriber(for: locale)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                // Something missing — download and install
                try await request.downloadAndInstall()
            }
            // Mark prepared for this session (even if request was nil)
            _ = preparedLocalesLock.withLock { preparedLocales.insert(key) }
        } catch {
            throw TranscriptionError.assetInstallationFailed
        }
    }

    // MARK: - Private helpers (existing)

    private func requestSpeechRecognitionPermission() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        print("🎙️ Transcription: Speech auth status before request = \(speechAuthorizationStatusLabel(status))")

        if status == .authorized {
            print("✅ Transcription: Speech recognition already authorized")
            return
        }

        if status == .denied || status == .restricted {
            print("🚫 Transcription: Speech recognition blocked (\(speechAuthorizationStatusLabel(status)))")
            throw TranscriptionError.permissionDenied
        }

        let newStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
        print("🎙️ Transcription: Speech auth callback status = \(speechAuthorizationStatusLabel(newStatus))")

        guard newStatus == .authorized else {
            print("🚫 Transcription: Speech recognition not authorized after request (\(speechAuthorizationStatusLabel(newStatus)))")
            throw TranscriptionError.permissionDenied
        }

        print("✅ Transcription: Speech recognition authorized after request")
    }

    private func speechAuthorizationStatusLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    private func extractAudio(from videoURL: URL, duration: TimeInterval? = nil) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed
        }
        if let duration {
            exportSession.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
        let tempAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try await exportSession.export(to: tempAudioURL, as: .m4a)
        return tempAudioURL
    }

    // Fallback transcoder used when AVAudioFile streaming reads fail on extracted audio.
    // This path uses AVAssetReader/Writer to produce analyzer-compatible PCM directly.
    private func transcodeAudioWithAssetPipeline(from sourceURL: URL, to targetFormat: AVAudioFormat) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw TranscriptionError.audioExtractionFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: Int(targetFormat.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !targetFormat.isInterleaved
        ]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw TranscriptionError.audioExtractionFailed
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw TranscriptionError.audioExtractionFailed
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw TranscriptionError.analysisFailed(writer.error?.localizedDescription ?? "Failed to start audio writer.")
        }
        writer.startSession(atSourceTime: .zero)

        guard reader.startReading() else {
            writer.cancelWriting()
            throw TranscriptionError.analysisFailed(reader.error?.localizedDescription ?? "Failed to start audio reader.")
        }

        while reader.status == .reading {
            try Task.checkCancellation()
            if writerInput.isReadyForMoreMediaData {
                if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                    if !writerInput.append(sampleBuffer) {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw TranscriptionError.analysisFailed(writer.error?.localizedDescription ?? "Failed while writing transcoded audio.")
                    }
                } else {
                    break
                }
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if reader.status == .failed || writer.status == .failed {
            throw TranscriptionError.analysisFailed(
                reader.error?.localizedDescription ??
                writer.error?.localizedDescription ??
                "Asset pipeline transcoding failed."
            )
        }

        return outputURL
    }

    private func convertAudio(_ sourceURL: URL, to targetFormat: AVAudioFormat) throws -> URL {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        // If the source already matches what the analyzer wants, skip conversion.
        if formatsMatch(inputFile.processingFormat, targetFormat) {
            return sourceURL
        }

        // Destination temp file (CAF for PCM)
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        // Build an explicit PCM output format to avoid interleaving/processing mismatches.
        guard let outputFormat = AVAudioFormat(
            commonFormat: targetFormat.commonFormat,
            sampleRate: targetFormat.sampleRate,
            channels: targetFormat.channelCount,
            interleaved: targetFormat.isInterleaved
        ) else {
            throw TranscriptionError.audioExtractionFailed
        }

        var outputSettings = outputFormat.settings
        outputSettings[AVFormatIDKey] = kAudioFormatLinearPCM
        outputSettings[AVSampleRateKey] = outputFormat.sampleRate
        outputSettings[AVNumberOfChannelsKey] = outputFormat.channelCount
        outputSettings[AVLinearPCMIsNonInterleaved] = !outputFormat.isInterleaved

        let outputFile = try AVAudioFile(
            forWriting: destURL,
            settings: outputSettings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )

        // Sanity check: ensure the file's processing format matches what we'll write.
        if !formatsMatch(outputFile.processingFormat, outputFormat) {
            throw TranscriptionError.analysisFailed("Output file format mismatch. Expected \(outputFormat), got \(outputFile.processingFormat)")
        }

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else {
            throw TranscriptionError.audioExtractionFailed
        }

        let bufferCapacity: AVAudioFrameCount = 32_768
        var inputFinished = false
        var sourceReadError: Error?

        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if inputFinished {
                outStatus.pointee = .endOfStream
                return nil
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: bufferCapacity)!
            do {
                try inputFile.read(into: buffer, frameCount: bufferCapacity)
            } catch {
                sourceReadError = error
                inputFinished = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                inputFinished = true
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        // Use the file's actual processing format to avoid format mismatches.

        var inputRanDryCount = 0
        let maxInputRanDry = 100
        conversionLoop: while true {
            if Task.isCancelled {
                throw TranscriptionError.analysisFailed("Audio conversion cancelled.")
            }
            var error: NSError?
            // Allocate a fresh buffer each iteration to avoid stale state
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferCapacity) else {
                throw TranscriptionError.analysisFailed("Failed to allocate output buffer.")
            }

            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)

            if let e = error {
                throw TranscriptionError.analysisFailed(e.localizedDescription)
            }

            if outBuffer.frameLength > 0 {
                try outputFile.write(from: outBuffer)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                inputRanDryCount += 1
                if inputRanDryCount > maxInputRanDry {
                    throw TranscriptionError.analysisFailed("Audio conversion stalled (input ran dry).")
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            case .endOfStream:
                break conversionLoop
            case .error:
                throw TranscriptionError.analysisFailed(
                    error?.localizedDescription ?? "Audio conversion failed."
                )
            @unknown default:
                break conversionLoop
            }
        }

        if let sourceReadError {
            throw TranscriptionError.analysisFailed("Audio conversion source read failed: \(sourceReadError.localizedDescription)")
        }

        return destURL
    }

    private func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        return a.sampleRate == b.sampleRate &&
            a.channelCount == b.channelCount &&
            a.commonFormat == b.commonFormat &&
            a.isInterleaved == b.isInterleaved
    }

    private struct LanguageProbeResult {
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

    private func detectLanguage(from sampleAudioURL: URL) async throws -> Locale {
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
            print("🧠 DETECTED: Chose \(supportedLocale.identifier) via probe \(bestSupported.probeLocale.identifier) (confidence: \(bestSupported.confidence), textLen: \(bestSupported.transcriptLength))")
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

    private func languageProbeResult(
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

    private func containsRecognizableSpeech(_ text: String) -> Bool {
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

    private func performTranscription(fullAudioURL: URL, locale: Locale, videoID: UUID) async throws -> TranscriptionOutput {
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
            print("🧪 Source audio format: \(sourceFile.processingFormat)")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioURLToTranscribe.path),
           let size = attrs[FileAttributeKey.size] as? NSNumber {
            print("🧪 Source audio size (bytes): \(size)")
        }
        let formatTranscriber = transcriber(for: locale)
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [formatTranscriber]) else {
            throw TranscriptionError.analysisFailed("No compatible audio format available for the speech analyzer.")
        }
        print("🧪 Analyzer target format: \(targetFormat)")

        // Convert to analyzer's preferred format (typically PCM). If decoding fails for the
        // intermediate source file, fall back to using the source format directly.
        var workingAudioURL: URL?
        var convertedPCMURL: URL?
        let preferAssetPipeline = getShouldPreferAssetPipelineTranscode()
        if preferAssetPipeline {
            print("🧪 Using preferred asset-pipeline transcode path")
            do {
                let pcmURL = try await transcodeAudioWithAssetPipeline(from: audioURLToTranscribe, to: targetFormat)
                convertedPCMURL = pcmURL
                workingAudioURL = pcmURL
                let recoveredFile = try AVAudioFile(forReading: pcmURL)
                print("🧪 Asset-pipeline transcode format: \(recoveredFile.processingFormat)")
            } catch {
                print("⚠️ Preferred asset-pipeline transcode failed; retrying direct converter path...")
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
                    print("🧪 Converted PCM size (bytes): \(size)")
                }
            } catch let conversionError as TranscriptionError {
                switch conversionError {
                case .analysisFailed(let reason) where reason.contains("Audio conversion source read failed"):
                    print("⚠️ Conversion decode failed; attempting asset-pipeline transcode fallback...")
                    let recoveredPCMURL = try await transcodeAudioWithAssetPipeline(from: audioURLToTranscribe, to: targetFormat)
                    convertedPCMURL = recoveredPCMURL
                    workingAudioURL = recoveredPCMURL
                    let recoveredFile = try AVAudioFile(forReading: recoveredPCMURL)
                    print("⚠️ Asset-pipeline fallback succeeded: \(recoveredFile.processingFormat)")
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
            print("🧪 Analyzer input format for attempt \(attempt + 1): \(audioFormat)")

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            await MainActor.run {
                self.speechAnalyzer = analyzer
            }

            await setStatus("Preparing speech analyzer...")
            let prepareStart = Date()
            try await analyzer.prepareToAnalyze(in: audioFormat)
            print("⏱️ prepareToAnalyze: \(Date().timeIntervalSince(prepareStart))s")

            let resultsTask = Task { () -> TranscriptionOutput in
                try await collectFinalResults(from: transcriber, videoID: videoID, locale: locale)
            }

            do {
                await setStatus("Analyzing audio (\(Int(analysisTimeout))s timeout cap)...")
                let analyzeStart = Date()
                let lastSampleTime = try await analyzeSequenceWithTimeout(analyzer: analyzer, audioFile: audioFile, timeoutSeconds: analysisTimeout)
                print("⏱️ analyzeSequence: \(Date().timeIntervalSince(analyzeStart))s")

                let finalizeStart = Date()
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                print("⏱️ finalizeAndFinish: \(Date().timeIntervalSince(finalizeStart))s")

                let resultsStart = Date()
                let output = try await awaitResultsWithTimeout(resultsTask, timeoutSeconds: max(30, analysisTimeout / 2), analyzer: analyzer)
                print("⏱️ resultsTask completion: \(Date().timeIntervalSince(resultsStart))s")

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
                    print("⚠️ Transcription attempt \(attempt + 1) failed: \(error). Retrying once...")
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

    private func collectFinalResults(from transcriber: SpeechTranscriber, videoID: UUID, locale: Locale) async throws -> TranscriptionOutput {
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

    private func timedWords(from text: AttributedString) -> [TimedWord] {
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

    private func seconds(from time: CMTime) -> TimeInterval {
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

    private func awaitResultsWithTimeout(_ task: Task<TranscriptionOutput, Error>, timeoutSeconds: TimeInterval, analyzer: SpeechAnalyzer) async throws -> TranscriptionOutput {
        try await withThrowingTaskGroup(of: TranscriptionOutput.self) { group in
            group.addTask {
                return try await task.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                task.cancel()
                await analyzer.cancelAndFinishNow()
                throw TranscriptionError.analysisFailed("Transcription results stalled (timeout).")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func analyzeSequenceWithTimeout(analyzer: SpeechAnalyzer, audioFile: AVAudioFile, timeoutSeconds: TimeInterval) async throws -> CMTime? {
        try await withThrowingTaskGroup(of: CMTime?.self) { group in
            group.addTask {
                return try await analyzer.analyzeSequence(from: audioFile)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
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

    private func mapTranslationError(
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

    private func detectLanguageFromText(_ text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue else {
            return Locale.current.language
        }
        return Locale(identifier: code).language
    }
    
    // MARK: - Chunked summarization helpers

    private func estimateTokens(for text: String) -> Int {
        let length = text.utf8.count
        return max(1, length / 4)
    }
    
    private func splitTextIntoChunksByBudget(_ text: String, targetTokens: Int, hardLimit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        
        // Split by paragraph blocks
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { $0.joined(separator: "\n") }
        
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
            currentTokens = 0
        }
        
        for para in paragraphs {
            let paraTokens = estimateTokens(for: para)
            if paraTokens > targetTokens {
                // Further split by sentences
                let sentences = splitIntoSentences(para)
                var buffer = ""
                var bufferTokens = 0
                for sentence in sentences {
                    let t = estimateTokens(for: sentence)
                    if bufferTokens + t > targetTokens {
                        if !buffer.isEmpty {
                            chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                            buffer = ""
                            bufferTokens = 0
                        }
                    }
                    if t > hardLimit {
                        // Hard split long sentence
                        let mid = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
                        let s1 = String(sentence[..<mid])
                        let s2 = String(sentence[mid...])
                        for part in [s1, s2] {
                            let pt = estimateTokens(for: part)
                            if bufferTokens + pt > targetTokens {
                                if !buffer.isEmpty {
                                    chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                                    buffer = ""
                                    bufferTokens = 0
                                }
                            }
                            buffer += part + " "
                            bufferTokens += pt
                        }
                    } else {
                        buffer += sentence + " "
                        bufferTokens += t
                    }
                }
                if !buffer.isEmpty {
                    chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }
            
            if currentTokens + paraTokens > targetTokens {
                flush()
            }
            current += para + "\n\n"
            currentTokens += paraTokens
        }
        
        flush()
        
        // Safety pass: split any chunk above hardLimit
        var safe: [String] = []
        for c in chunks {
            if estimateTokens(for: c) > hardLimit {
                let mid = c.index(c.startIndex, offsetBy: c.count / 2)
                safe.append(String(c[..<mid]))
                safe.append(String(c[mid...]))
            } else {
                safe.append(c)
            }
        }
        return safe
    }
    
    private func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        return sentences
    }
    
    private func summarizeChunk(_ chunk: String, customPrompt: String?) async throws -> String {
        let instructionsText = summaryInstructions(from: customPrompt)
        let instructions = Instructions("""
        You are an expert summarizer. Follow these rules:
        - Output Markdown only (no plain text outside markdown, no code fences)
        - Use clear headings (##) and lists when useful
        - Keep content faithful and concise
        - Avoid repetition
        - Preserve important names, dates, figures

        Task:
        \(instructionsText)
        """)
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Summarize the following transcript chunk:

        \(chunk)
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }
    
    private func reduceSummaries(_ summaries: [String], customPrompt: String?) async throws -> String {
        let instructionsText = summaryInstructions(from: customPrompt)
        let instructions = Instructions("""
        You are an expert at synthesizing multiple summaries into a cohesive, non-redundant final summary.
        - Output Markdown only (no plain text outside markdown, no code fences)
        - Use clear headings (##) and lists when useful
        - Remove duplicates and merge related points
        - Maintain logical flow and highlight key insights

        Final summary style:
        \(instructionsText)
        """)
        let session = LanguageModelSession(instructions: instructions)
        let joined = summaries.enumerated().map { "Chunk \($0 + 1):\n\($1)" }.joined(separator: "\n\n---\n\n")
        let prompt = """
        Combine the following chunk summaries into a single, coherent summary:

        \(joined)
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }

    private func summaryInstructions(from customPrompt: String?) -> String {
        let trimmed = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Summarize the content clearly with headings and bullet points."
        }
        return trimmed
    }

    // MARK: - Main-thread UI helpers

    private func setTranscribingState(isTranscribing: Bool, isSummarizing: Bool) async {
        await MainActor.run {
            self.isTranscribing = isTranscribing
            self.isSummarizing = isSummarizing
        }
    }

    private func setProgress(_ value: Double) async {
        await MainActor.run {
            self.progress = value
        }
    }

    private func setStatus(_ message: String) async {
        await MainActor.run {
            self.statusMessage = message
        }
    }

    private func setErrorMessage(_ message: String?) async {
        await MainActor.run {
            self.errorMessage = message
        }
    }

    private func userVisibleMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError {
            let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suggestion = localized.recoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !description.isEmpty, !suggestion.isEmpty, description != suggestion {
                return "\(description)\n\n\(suggestion)"
            }
            if !description.isEmpty {
                return description
            }
            if !suggestion.isEmpty {
                return suggestion
            }
        }

        let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "An unknown error occurred." : fallback
    }

    private func isTranscribingOnMain() async -> Bool {
        await MainActor.run { isTranscribing }
    }

    private func getProgressOnMain() async -> Double {
        await MainActor.run { progress }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
