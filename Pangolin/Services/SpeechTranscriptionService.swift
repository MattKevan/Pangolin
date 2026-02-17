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
            return "The language '\(locale.identifier)' is not supported for transcription on this device."
        case .audioExtractionFailed:
            return "Failed to extract a usable audio track from the video file."
        case .videoFileNotFound:
            return "The video file could not be found. It may have been moved or deleted."
        case .noSpeechDetected:
            return "No speech could be detected in the video's audio track."
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
            return "Ensure your Mac is connected to the internet to see all available languages."
        case .audioExtractionFailed:
            return "Try converting the video to a standard format like MP4 and re-importing it."
        case .videoFileNotFound:
            return "Please re-import the video into your Pangolin library."
        case .noSpeechDetected:
            return "The video's audio may be silent or contain only music."
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
            return "Ensure Apple Intelligence is enabled in System Settings and try again. Summarization requires Apple Intelligence to be active."
        }
    }
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

    // MARK: - Summary Presets
    enum SummaryPreset: String, CaseIterable, Identifiable {
        case executive
        case detailed
        case actionItems
        case studyNotes
        case custom
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .executive: return "Executive Summary"
            case .detailed: return "Detailed Overview"
            case .actionItems: return "Action Items"
            case .studyNotes: return "Study Notes"
            case .custom: return "Custom"
            }
        }
        
        var baseInstructions: String {
            switch self {
            case .executive:
                return """
                Create a concise executive summary focused on key insights, decisions, and outcomes. \
                Use clear headings and bullet points. Keep it brief and high-signal.
                """
            case .detailed:
                return """
                Produce a comprehensive, well-structured summary with headings and bullet points. \
                Maintain logical flow, highlight key arguments, tradeoffs, and conclusions.
                """
            case .actionItems:
                return """
                Extract clear, actionable tasks with owners (if mentioned), due dates (if provided), and status. \
                Include a brief context section, then list actions as bullet points.
                """
            case .studyNotes:
                return """
                Create study notes: definitions, key concepts, examples, and takeaways. \
                Use headings, bullet points, and emphasis for clarity.
                """
            case .custom:
                return ""
            }
        }
        
        func combinedInstructions(with customPrompt: String?) -> String {
            let custom = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if self == .custom {
                return custom.isEmpty ? "Summarize the content clearly with headings and bullet points." : custom
            }
            if custom.isEmpty {
                return baseInstructions
            }
            return baseInstructions + "\n\nAdditional guidance:\n" + custom
        }
    }

    // MARK: - Public API

    func transcribeVideo(_ video: Video, libraryManager: LibraryManager, preferredLocale: Locale? = nil) async {
        let videoTitle = await MainActor.run { video.title ?? "Unknown" }
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
            let transcriptText = try await performTranscription(
                fullAudioURL: videoURL,
                locale: usedLocale
            )
            await setProgress(0.9)
            
            await setStatus("Saving transcript...")
            await MainActor.run {
                video.transcriptText = transcriptText
                video.transcriptLanguage = usedLocale.identifier
                video.transcriptDateGenerated = Date()
            }
            
            // Persist to disk (best effort)
            do {
                try await MainActor.run {
                    try libraryManager.ensureTextArtifactDirectories()
                    if let url = libraryManager.transcriptURL(for: video) {
                        try libraryManager.writeTextAtomically(transcriptText, to: url)
                    }
                }
            } catch {
                print("⚠️ Failed to write transcript to disk: \(error)")
            }
            
            // NOTE: Removed automatic translation. Translation must be initiated manually
            // via translateVideo(_:libraryManager:targetLanguage:).
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Transcription complete!")
        } catch {
            let localizedError = error as? LocalizedError
            await setErrorMessage(localizedError?.errorDescription ?? "An unknown error occurred.")
            print("🚨 Transcription error: \(error)")
        }
        
        await setTranscribingState(isTranscribing: false, isSummarizing: false)
        
    }

    func translateVideo(_ video: Video, libraryManager: LibraryManager, targetLanguage: Locale.Language? = nil) async {
        let initialState = await MainActor.run { () -> (title: String, transcript: String?, transcriptLanguage: String?) in
            (video.title ?? "Unknown", video.transcriptText, video.transcriptLanguage)
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
            let computationResult = try await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    throw TranscriptionError.translationFailed("Translation service unavailable.")
                }
                return try await self.computeTranslation(
                    transcriptText: transcriptText,
                    transcriptLanguageIdentifier: initialState.transcriptLanguage,
                    targetLanguage: targetLanguage
                )
            }.value

            if computationResult.translationSkipped {
                await setStatus("Translation not needed - already in target language")
                await setProgress(1.0)
                return
            }

            await setProgress(0.3)
            let translatedText = computationResult.translatedText
            let targetCode = computationResult.targetLanguageIdentifier
            
            await setProgress(0.9)
            await setStatus("Saving translation...")

            await MainActor.run {
                video.translatedText = translatedText
                video.translatedLanguage = targetCode
                video.translationDateGenerated = Date()
                if let resolvedSourceLanguage = computationResult.resolvedSourceLanguageIdentifier {
                    video.transcriptLanguage = resolvedSourceLanguage
                }
            }
            
            // Persist to disk (best effort)
            do {
                try await MainActor.run {
                    try libraryManager.ensureTextArtifactDirectories()
                    if let url = libraryManager.translationURL(for: video, languageCode: targetCode) {
                        try libraryManager.writeTextAtomically(translatedText, to: url)
                    }
                }
            } catch {
                print("⚠️ Failed to write translation to disk: \(error)")
            }
            
            await libraryManager.save()
            
            await setProgress(1.0)
            await setStatus("Translation complete!")
        } catch {
            let localizedError = error as? LocalizedError
            await setErrorMessage(localizedError?.errorDescription ?? "An unknown error occurred.")
            print("🚨 Translation error: \(error)")
        }
        
        await setTranscribingState(isTranscribing: false, isSummarizing: false)
    }

    // MARK: - Summarization

    func summarizeVideo(_ video: Video, libraryManager: LibraryManager, preset: SummaryPreset = .detailed, customPrompt: String? = nil) async {
        let initialState = await MainActor.run { () -> (title: String, translated: String?, transcript: String?) in
            (video.title ?? "Unknown", video.translatedText, video.transcriptText)
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

                    let chunkSummary = try await self.summarizeChunk(chunk, preset: preset, customPrompt: customPrompt)
                    chunkSummaries.append(chunkSummary)
                }

                await setStatus("Combining summaries...")
                await setProgress(0.8)
                return try await self.reduceSummaries(chunkSummaries, preset: preset, customPrompt: customPrompt)
            }.value

            await setStatus("Saving summary...")
            await setProgress(0.95)
            await MainActor.run {
                video.transcriptSummary = finalSummary
                video.summaryDateGenerated = Date()
            }
            
            // Persist to disk (best effort)
            do {
                try await MainActor.run {
                    try libraryManager.ensureTextArtifactDirectories()
                    if let url = libraryManager.summaryURL(for: video) {
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
            let localizedError = error as? LocalizedError
            await setErrorMessage(localizedError?.errorDescription ?? error.localizedDescription)
            print("🚨 Summarization error: \(error)")
        }
        
        await setTranscribingState(isTranscribing: false, isSummarizing: false)
    }

    private struct TranslationComputationResult {
        let translatedText: String
        let targetLanguageIdentifier: String
        let resolvedSourceLanguageIdentifier: String?
        let translationSkipped: Bool

        static var skipped: TranslationComputationResult {
            TranslationComputationResult(
                translatedText: "",
                targetLanguageIdentifier: "",
                resolvedSourceLanguageIdentifier: nil,
                translationSkipped: true
            )
        }
    }

    private func computeTranslation(
        transcriptText: String,
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

        if sourceCode == targetCode {
            return .skipped
        }

        let translatedText = try await translateText(transcriptText, from: sourceLanguage, to: chosenTargetLanguage)
        return TranslationComputationResult(
            translatedText: translatedText,
            targetLanguageIdentifier: targetCode,
            resolvedSourceLanguageIdentifier: resolvedSourceLanguageIdentifier,
            translationSkipped: false
        )
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
        SpeechTranscriber(locale: locale, preset: .transcription)
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

    private func detectLanguage(from sampleAudioURL: URL) async throws -> Locale {
        // Fallback to system-equivalent supported locale
        let systemLocale = Locale.current
        let supportedSystemLocale = await SpeechTranscriber.supportedLocale(equivalentTo: systemLocale) ?? Locale(identifier: "en-US")
        
        // Preflight model installation for fallback (cache-aware)
        do {
            await setStatus("Preparing language model (\(supportedSystemLocale.identifier))...")
            try await prepareModelIfNeeded(for: supportedSystemLocale)
        } catch {
            // Non-fatal: continue with detection attempt using whatever is available
        }
        
        // Preliminary transcription for detection
        do {
            let preliminaryTranscript = try await performTranscription(fullAudioURL: sampleAudioURL, locale: supportedSystemLocale)
            let languageRecognizer = NLLanguageRecognizer()
            languageRecognizer.processString(preliminaryTranscript)
            guard let languageCode = languageRecognizer.dominantLanguage?.rawValue else {
                return supportedSystemLocale
            }
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) {
                let set = await SpeechTranscriber.supportedLocales
                return set.contains(supported) ? supported : supportedSystemLocale
            }
            return supportedSystemLocale
        } catch {
            return supportedSystemLocale
        }
    }

    private func performTranscription(fullAudioURL: URL, locale: Locale) async throws -> String {
        // Ensure model is prepared (fast if already installed or prepared this session)
        try await prepareModelIfNeeded(for: locale)

        let preset: SpeechTranscriber.Preset = .transcription

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
        let formatTranscriber = SpeechTranscriber(locale: locale, preset: preset)
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
            let transcriber = SpeechTranscriber(locale: locale, preset: preset)
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

            let resultsTask = Task { () -> [String] in
                try await collectFinalResults(from: transcriber)
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
                let parts = try await awaitResultsWithTimeout(resultsTask, timeoutSeconds: max(30, analysisTimeout / 2), analyzer: analyzer)
                print("⏱️ resultsTask completion: \(Date().timeIntervalSince(resultsStart))s")

                let combined = parts.joined(separator: " ")
                if combined.isEmpty { throw TranscriptionError.noSpeechDetected }
                if !audioExtensions.contains(fileExtension) {
                    try? FileManager.default.removeItem(at: audioURLToTranscribe)
                }
                return combined
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

    private func collectFinalResults(from transcriber: SpeechTranscriber) async throws -> [String] {
        var transcriptParts: [String] = []
        for try await result in transcriber.results {
            if Task.isCancelled {
                throw TranscriptionError.analysisFailed("Transcription cancelled.")
            }
            if result.isFinal {
                transcriptParts.append(String(result.text.characters))
            }
        }
        return transcriptParts
    }

    private func awaitResultsWithTimeout(_ task: Task<[String], Error>, timeoutSeconds: TimeInterval, analyzer: SpeechAnalyzer) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
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

    private func translateText(_ text: String, from sourceLanguage: Locale.Language, to targetLanguage: Locale.Language) async throws -> String {
        await setStatus("Checking translation models...")
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        await MainActor.run {
            self.translationSession = session
        }
        try await session.prepareTranslation()
        await setStatus("Translating to \(targetLanguage.languageCode?.identifier ?? "target language")...")
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            if let translationError = error as? TranslationError,
               String(describing: translationError).contains("notInstalled") {
                throw TranscriptionError.translationModelsNotInstalled(
                    sourceLanguage.languageCode?.identifier ?? "unknown",
                    targetLanguage.languageCode?.identifier ?? "unknown"
                )
            }
            if error.localizedDescription.contains("not supported") {
                throw TranscriptionError.translationNotSupported(
                    sourceLanguage.languageCode?.identifier ?? "unknown",
                    targetLanguage.languageCode?.identifier ?? "unknown"
                )
            } else if error.localizedDescription.contains("notInstalled") || error.localizedDescription.contains("Code=16") {
                throw TranscriptionError.translationModelsNotInstalled(
                    sourceLanguage.languageCode?.identifier ?? "unknown",
                    targetLanguage.languageCode?.identifier ?? "unknown"
                )
            } else {
                throw TranscriptionError.translationFailed(error.localizedDescription)
            }
        }
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
    
    private func summarizeChunk(_ chunk: String, preset: SummaryPreset, customPrompt: String?) async throws -> String {
        let instructionsText = preset.combinedInstructions(with: customPrompt)
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
    
    private func reduceSummaries(_ summaries: [String], preset: SummaryPreset, customPrompt: String?) async throws -> String {
        let instructionsText = preset.combinedInstructions(with: customPrompt)
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
