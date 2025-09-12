import Foundation
import Speech
import AVFoundation
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

@MainActor
class SpeechTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var isSummarizing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    
    private var speechAnalyzer: SpeechAnalyzer?
    private var translationSession: TranslationSession?
    
    // Session cache: locales we’ve verified/installed during this app run
    private var preparedLocales = Set<String>()

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
        print("🟢 Started transcribeVideo for \(video.title ?? "Unknown")")
        guard !isTranscribing else { return }
        
        isTranscribing = true
        errorMessage = nil
        progress = 0.0
        statusMessage = "Starting transcription..."
        
        // Register with task queue
        let taskGroupId = await MainActor.run {
            TaskQueueManager.shared.startTaskGroup(
                type: .transcribing,
                totalItems: 1
            )
        }
        
        do {
            // Use the async method to get accessible video file URL, downloading if needed
            statusMessage = "Accessing video file..."
            // Update task queue (this handles main thread dispatch internally)
            await TaskQueueManager.shared.updateTaskGroup(
                id: taskGroupId,
                completedItems: 0,
                currentItem: video.title ?? "Unknown Video"
            )
            
            let videoURL: URL
            do {
                videoURL = try await video.getAccessibleFileURL(downloadIfNeeded: true)
                print("🎬 Transcription: Got accessible video URL: \(videoURL)")
            } catch {
                print("🚨 Transcription: Failed to get accessible video URL: \(error)")
                throw TranscriptionError.videoFileNotFound
            }
            
            statusMessage = "Checking permissions..."
            try await requestSpeechRecognitionPermission()
            progress = 0.1
            
            // Determine locale to use
            let usedLocale: Locale
            if let preferredLocale {
                if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) {
                    usedLocale = equivalent
                } else {
                    throw TranscriptionError.languageNotSupported(preferredLocale)
                }
                print("🧭 Using preferred locale: \(usedLocale.identifier)")
                progress = 0.2
            } else {
                statusMessage = "Extracting audio sample..."
                let sampleAudioURL = try await extractAudio(from: videoURL, duration: 30.0)
                defer { try? FileManager.default.removeItem(at: sampleAudioURL) }
                progress = 0.2
                
                statusMessage = "Detecting language..."
                usedLocale = try await detectLanguage(from: sampleAudioURL)
                print("🧠 DETECTED: Language locale is \(usedLocale.identifier)")
                progress = 0.3
            }
            
            // Ensure model is present for the final chosen locale
            statusMessage = "Preparing language model (\(usedLocale.identifier))..."
            try await prepareModelIfNeeded(for: usedLocale)
            progress = max(progress, 0.35)
            
            statusMessage = "Transcribing main audio..."
            let transcriptText = try await performTranscription(
                fullAudioURL: videoURL,
                locale: usedLocale
            )
            progress = 0.9
            
            statusMessage = "Saving transcript..."
            video.transcriptText = transcriptText
            video.transcriptLanguage = usedLocale.identifier
            video.transcriptDateGenerated = Date()
            
            // Persist to disk (best effort)
            do {
                try libraryManager.ensureTextArtifactDirectories()
                if let url = libraryManager.transcriptURL(for: video) {
                    try libraryManager.writeTextAtomically(transcriptText, to: url)
                }
            } catch {
                print("⚠️ Failed to write transcript to disk: \(error)")
            }
            
            // NOTE: Removed automatic translation. Translation must be initiated manually
            // via translateVideo(_:libraryManager:targetLanguage:).
            
            await libraryManager.save()
            
            progress = 1.0
            statusMessage = "Transcription complete!"
            
        } catch {
            let localizedError = error as? LocalizedError
            errorMessage = localizedError?.errorDescription ?? "An unknown error occurred."
            print("🚨 Transcription error: \(error)")
        }
        
        isTranscribing = false
        
        // Complete or remove task group based on success/failure (handles main thread internally)
        if errorMessage == nil {
            await TaskQueueManager.shared.completeTaskGroup(id: taskGroupId)
        } else {
            await MainActor.run {
                TaskQueueManager.shared.removeTaskGroup(id: taskGroupId)
            }
        }
    }

    func translateVideo(_ video: Video, libraryManager: LibraryManager, targetLanguage: Locale.Language? = nil) async {
        print("🟢 Started translateVideo for \(video.title ?? "Unknown")")
        guard !isTranscribing, let transcriptText = video.transcriptText else { return }
        
        isTranscribing = true
        errorMessage = nil
        progress = 0.0
        statusMessage = "Starting translation..."
        
        do {
            // Determine source language
            var sourceLanguage: Locale.Language
            if let transcriptLangIdentifier = video.transcriptLanguage {
                let sourceLocale = Locale(identifier: transcriptLangIdentifier)
                sourceLanguage = sourceLocale.language
                if let code = sourceLanguage.languageCode {
                    if code.identifier.isEmpty {
                        let detectedLanguage = detectLanguageFromText(transcriptText)
                        sourceLanguage = detectedLanguage
                        video.transcriptLanguage = detectedLanguage.languageCode?.identifier
                    }
                } else {
                    let detectedLanguage = detectLanguageFromText(transcriptText)
                    sourceLanguage = detectedLanguage
                    video.transcriptLanguage = detectedLanguage.languageCode?.identifier
                }
            } else {
                let detectedLanguage = detectLanguageFromText(transcriptText)
                sourceLanguage = detectedLanguage
                video.transcriptLanguage = detectedLanguage.languageCode?.identifier
            }
            
            // Determine target language
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
                statusMessage = "Translation not needed - already in target language"
                isTranscribing = false
                return
            }
            
            progress = 0.3
            let translatedText = try await translateText(transcriptText, from: sourceLanguage, to: chosenTargetLanguage)
            
            progress = 0.9
            statusMessage = "Saving translation..."
            
            video.translatedText = translatedText
            video.translatedLanguage = targetCode
            video.translationDateGenerated = Date()
            
            // Persist to disk (best effort)
            do {
                try libraryManager.ensureTextArtifactDirectories()
                if let url = libraryManager.translationURL(for: video, languageCode: targetCode) {
                    try libraryManager.writeTextAtomically(translatedText, to: url)
                }
            } catch {
                print("⚠️ Failed to write translation to disk: \(error)")
            }
            
            await libraryManager.save()
            
            progress = 1.0
            statusMessage = "Translation complete!"
            
        } catch {
            let localizedError = error as? LocalizedError
            errorMessage = localizedError?.errorDescription ?? "An unknown error occurred."
            print("🚨 Translation error: \(error)")
        }
        
        isTranscribing = false
    }

    // MARK: - Summarization

    func summarizeVideo(_ video: Video, libraryManager: LibraryManager, preset: SummaryPreset = .detailed, customPrompt: String? = nil) async {
        print("🟢 Started summarizeVideo for \(video.title ?? "Unknown")")
        guard !isTranscribing else { return }
        
        // Use translated text if available, otherwise use original transcript
        let textToSummarize: String
        if let translatedText = video.translatedText, !translatedText.isEmpty {
            textToSummarize = translatedText
        } else if let transcriptText = video.transcriptText, !transcriptText.isEmpty {
            textToSummarize = transcriptText
        } else {
            errorMessage = "No transcript available to summarize."
            return
        }
        
        isTranscribing = true
        isSummarizing = true
        errorMessage = nil
        progress = 0.0
        statusMessage = "Preparing Apple Intelligence..."
        
        do {
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
            
            statusMessage = "Chunking transcript..."
            let maxContextTokens = 4096
            let targetChunkTokens = 3000
            let chunks = splitTextIntoChunksByBudget(textToSummarize, targetTokens: targetChunkTokens, hardLimit: maxContextTokens)
            guard !chunks.isEmpty else {
                throw TranscriptionError.summarizationFailed("No content available after chunking.")
            }
            
            var chunkSummaries: [String] = []
            for (index, chunk) in chunks.enumerated() {
                statusMessage = "Summarizing chunk \(index + 1) of \(chunks.count)..."
                progress = 0.1 + (0.6 * Double(index) / Double(max(1, chunks.count)))
                
                let chunkSummary = try await summarizeChunk(chunk, preset: preset, customPrompt: customPrompt)
                chunkSummaries.append(chunkSummary)
            }
            
            statusMessage = "Combining summaries..."
            progress = 0.8
            let finalSummary = try await reduceSummaries(chunkSummaries, preset: preset, customPrompt: customPrompt)
            
            statusMessage = "Saving summary..."
            progress = 0.95
            video.transcriptSummary = finalSummary
            video.summaryDateGenerated = Date()
            
            // Persist to disk (best effort)
            do {
                try libraryManager.ensureTextArtifactDirectories()
                if let url = libraryManager.summaryURL(for: video) {
                    try libraryManager.writeTextAtomically(finalSummary, to: url)
                }
            } catch {
                print("⚠️ Failed to write summary to disk: \(error)")
            }
            
            await libraryManager.save()
            
            progress = 1.0
            statusMessage = "Summary complete!"
        } catch {
            let localizedError = error as? LocalizedError
            errorMessage = localizedError?.errorDescription ?? error.localizedDescription
            print("🚨 Summarization error: \(error)")
        }
        
        isSummarizing = false
        isTranscribing = false
    }

    // MARK: - Model preparation helpers (cache-aware)

    private func localeKey(_ locale: Locale) -> String {
        locale.identifier
    }
    
    private func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }
    
    // Returns true if all required assets for the transcriber are already installed.
    private func isModelInstalled(for locale: Locale) async -> Bool {
        let key = localeKey(locale)
        if preparedLocales.contains(key) {
            return true
        }
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
        if preparedLocales.contains(key) {
            return
        }
        let t = transcriber(for: locale)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                // Something missing — download and install
                try await request.downloadAndInstall()
            }
            // Mark prepared for this session (even if request was nil)
            preparedLocales.insert(key)
        } catch {
            throw TranscriptionError.assetInstallationFailed
        }
    }

    // MARK: - Private helpers (existing)

    private func requestSpeechRecognitionPermission() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        if status == .denied || status == .restricted { throw TranscriptionError.permissionDenied }
        
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus == .authorized)
            }
        }
        if !granted { throw TranscriptionError.permissionDenied }
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

    private func detectLanguage(from sampleAudioURL: URL) async throws -> Locale {
        // Fallback to system-equivalent supported locale
        let systemLocale = Locale.current
        let supportedSystemLocale = await SpeechTranscriber.supportedLocale(equivalentTo: systemLocale) ?? Locale(identifier: "en-US")
        
        // Preflight model installation for fallback (cache-aware)
        do {
            statusMessage = "Preparing language model (\(supportedSystemLocale.identifier))..."
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
        
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.speechAnalyzer = analyzer
        try await analyzer.prepareToAnalyze(in: audioFormat)

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
        let audioFile = try AVAudioFile(forReading: audioURLToTranscribe)
        
        // Collect results concurrently
        let resultsTask = Task { () -> [String] in
            var transcriptParts: [String] = []
            for try await result in transcriber.results {
                if result.isFinal {
                    transcriptParts.append(String(result.text.characters))
                }
            }
            return transcriptParts
        }
        
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let parts = try await resultsTask.value
            let combined = parts.joined(separator: " ")
            if combined.isEmpty { throw TranscriptionError.noSpeechDetected }
            if !audioExtensions.contains(fileExtension) {
                try? FileManager.default.removeItem(at: audioURLToTranscribe)
            }
            return combined
        } catch {
            resultsTask.cancel()
            throw error
        }
    }

    private func translateText(_ text: String, from sourceLanguage: Locale.Language, to targetLanguage: Locale.Language) async throws -> String {
        statusMessage = "Checking translation models..."
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        self.translationSession = session
        try await session.prepareTranslation()
        statusMessage = "Translating to \(targetLanguage.languageCode?.identifier ?? "target language")..."
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
        - Use proper Markdown with headings (##) and bullet points
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
        - Use Markdown with clear headings (##) and bullet points
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
}
