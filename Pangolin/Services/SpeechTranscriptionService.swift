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

    // MARK: - Summary Presets (parameter-only, no persistence)
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
        
        // Base instructions tailored to the preset. Custom prompt can augment this.
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

    // New signature with backward-compatible default parameter
    func transcribeVideo(_ video: Video, libraryManager: LibraryManager, preferredLocale: Locale? = nil) async {
        print("🟢 Started transcribeVideo for \(video.title ?? "Unknown")")
        guard !isTranscribing else { return }
        
        isTranscribing = true
        errorMessage = nil
        progress = 0.0
        statusMessage = "Starting transcription..."
        
        do {
            guard let videoURL = video.fileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
                throw TranscriptionError.videoFileNotFound
            }
            
            statusMessage = "Checking permissions..."
            try await requestSpeechRecognitionPermission()
            progress = 0.1
            
            // Determine locale to use
            let usedLocale: Locale
            if let preferredLocale {
                // Validate preferred locale against SpeechTranscriber supported set, mapping to equivalent if needed
                if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) {
                    usedLocale = equivalent
                } else {
                    // If not supported, surface an error
                    throw TranscriptionError.languageNotSupported(preferredLocale)
                }
                print("🧭 Using preferred locale: \(usedLocale.identifier)")
                progress = 0.2
            } else {
                statusMessage = "Extracting audio sample..."
                let sampleAudioURL = try await extractAudio(from: videoURL, duration: 15.0)
                defer { try? FileManager.default.removeItem(at: sampleAudioURL) }
                progress = 0.2
                
                statusMessage = "Detecting language..."
                usedLocale = try await detectLanguage(from: sampleAudioURL)
                print("🧠 DETECTED: Language locale is \(usedLocale.identifier)")
                progress = 0.3
            }
            
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
            
            // Auto-translate if the detected/preferred language is different from the system language
            let systemLanguage = Locale.current.language
            let sourceLanguage = usedLocale.language
            
            if sourceLanguage.languageCode?.identifier != systemLanguage.languageCode?.identifier {
                statusMessage = "Translating transcript..."
                progress = 0.95
                
                do {
                    let translatedText = try await translateText(transcriptText, from: sourceLanguage, to: systemLanguage)
                    video.translatedText = translatedText
                    video.translatedLanguage = systemLanguage.languageCode?.identifier
                    video.translationDateGenerated = Date()
                    print("🟢 Translation completed successfully")
                } catch {
                    print("🟠 Translation failed, but continuing: \(error)")
                    // Continue without failing the entire process
                }
            }
            
            await libraryManager.save()
            
            progress = 1.0
            statusMessage = "Transcription complete!"
            
        } catch {
            let localizedError = error as? LocalizedError
            errorMessage = localizedError?.errorDescription ?? "An unknown error occurred."
            print("🚨 Transcription error: \(error)")
        }
        
        isTranscribing = false
    }

    // New signature with backward-compatible default parameter
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
                print("🟡 Transcript language identifier: '\(transcriptLangIdentifier)'")
                let sourceLocale = Locale(identifier: transcriptLangIdentifier)
                sourceLanguage = sourceLocale.language
                print("🟡 Parsed source language: \(sourceLanguage)")
                
                // Validate parsed language
                if let code = sourceLanguage.languageCode {
                    if code.identifier.isEmpty {
                        print("🟠 Empty stored language identifier, attempting to detect from transcript...")
                        let detectedLanguage = detectLanguageFromText(transcriptText)
                        sourceLanguage = detectedLanguage
                        video.transcriptLanguage = detectedLanguage.languageCode?.identifier
                    }
                } else {
                    print("🟠 Missing stored language code, attempting to detect from transcript...")
                    let detectedLanguage = detectLanguageFromText(transcriptText)
                    sourceLanguage = detectedLanguage
                    video.transcriptLanguage = detectedLanguage.languageCode?.identifier
                }
            } else {
                print("🟠 No transcript language stored, detecting from transcript text...")
                let detectedLanguage = detectLanguageFromText(transcriptText)
                sourceLanguage = detectedLanguage
                video.transcriptLanguage = detectedLanguage.languageCode?.identifier
            }
            
            // Determine target language
            let chosenTargetLanguage: Locale.Language = targetLanguage ?? Locale.current.language
            
            // Validate language codes and derive identifiers
            guard let sourceLangCode = sourceLanguage.languageCode else {
                print("🔴 Invalid source language code: \(sourceLanguage)")
                throw TranscriptionError.translationNotSupported(
                    "Invalid source language",
                    chosenTargetLanguage.languageCode?.identifier ?? "unknown"
                )
            }
            let sourceCode = sourceLangCode.identifier
            guard !sourceCode.isEmpty else {
                print("🔴 Empty source language identifier")
                throw TranscriptionError.translationNotSupported(
                    "Invalid source language",
                    chosenTargetLanguage.languageCode?.identifier ?? "unknown"
                )
            }
            
            guard let targetLangCode = chosenTargetLanguage.languageCode else {
                print("🔴 Invalid target language code: \(chosenTargetLanguage)")
                throw TranscriptionError.translationNotSupported(
                    sourceCode,
                    "Invalid target language"
                )
            }
            let targetCode = targetLangCode.identifier
            guard !targetCode.isEmpty else {
                print("🔴 Empty target language identifier")
                throw TranscriptionError.translationNotSupported(
                    sourceCode,
                    "Invalid target language"
                )
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
            video.translatedLanguage = chosenTargetLanguage.languageCode?.identifier
            video.translationDateGenerated = Date()
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

    // MARK: - Summarization (Chunked map → reduce with presets)

    // Backward-compatible: callers not passing preset/customPrompt will use .detailed by default.
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
            // Check model availability
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
            
            // Chunking strategy
            statusMessage = "Chunking transcript..."
            let maxContextTokens = 4096
            let targetChunkTokens = 3000 // leave headroom for instructions/system prompts
            let chunks = splitTextIntoChunksByBudget(textToSummarize, targetTokens: targetChunkTokens, hardLimit: maxContextTokens)
            print("🧩 Summarization chunks: \(chunks.count)")
            guard !chunks.isEmpty else {
                throw TranscriptionError.summarizationFailed("No content available after chunking.")
            }
            
            // Map: summarize each chunk
            var chunkSummaries: [String] = []
            for (index, chunk) in chunks.enumerated() {
                statusMessage = "Summarizing chunk \(index + 1) of \(chunks.count)..."
                progress = 0.1 + (0.6 * Double(index) / Double(max(1, chunks.count)))
                
                let chunkSummary = try await summarizeChunk(chunk, preset: preset, customPrompt: customPrompt)
                chunkSummaries.append(chunkSummary)
            }
            
            // Reduce: combine chunk summaries
            statusMessage = "Combining summaries..."
            progress = 0.8
            let finalSummary = try await reduceSummaries(chunkSummaries, preset: preset, customPrompt: customPrompt)
            
            statusMessage = "Saving summary..."
            progress = 0.95
            video.transcriptSummary = finalSummary
            video.summaryDateGenerated = Date()
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

    // MARK: - Chunked Summarization Helpers

    // Heuristic token estimation (approx ~4 chars/token, with floor)
    private func estimateTokens(for text: String) -> Int {
        let length = text.utf8.count
        return max(1, length / 4)
    }
    
    // Split on paragraphs first, then sentences, to respect token budgets
    private func splitTextIntoChunksByBudget(_ text: String, targetTokens: Int, hardLimit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        
        // First, split by paragraph boundaries to keep logical structure
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { $0.joined(separator: "\n") }
        
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        
        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current = ""
            currentTokens = 0
        }
        
        for para in paragraphs {
            let paraTokens = estimateTokens(for: para)
            // If a single paragraph is too big, split by sentences
            if paraTokens > targetTokens {
                // Split by sentences using NLTokenizer
                let sentences = splitIntoSentences(para)
                var sentenceBuffer = ""
                var bufferTokens = 0
                for sentence in sentences {
                    let t = estimateTokens(for: sentence)
                    if bufferTokens + t > targetTokens {
                        if !sentenceBuffer.isEmpty {
                            chunks.append(sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                            sentenceBuffer = ""
                            bufferTokens = 0
                        }
                    }
                    if t > hardLimit { // pathological case: sentence too long; hard-split
                        let mid = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
                        let s1 = String(sentence[sentence.startIndex..<mid])
                        let s2 = String(sentence[mid..<sentence.endIndex])
                        for part in [s1, s2] {
                            let pt = estimateTokens(for: part)
                            if bufferTokens + pt > targetTokens {
                                if !sentenceBuffer.isEmpty {
                                    chunks.append(sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                                    sentenceBuffer = ""
                                    bufferTokens = 0
                                }
                            }
                            sentenceBuffer += part + " "
                            bufferTokens += pt
                        }
                    } else {
                        sentenceBuffer += sentence + " "
                        bufferTokens += t
                    }
                }
                if !sentenceBuffer.isEmpty {
                    chunks.append(sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }
            
            // Normal paragraph packing into chunks
            if currentTokens + paraTokens > targetTokens {
                flushCurrent()
            }
            current += para + "\n\n"
            currentTokens += paraTokens
        }
        
        flushCurrent()
        
        // Final safety: if any chunk exceeds hardLimit, split it roughly in half
        var safeChunks: [String] = []
        for c in chunks {
            if estimateTokens(for: c) > hardLimit {
                let mid = c.index(c.startIndex, offsetBy: c.count / 2)
                safeChunks.append(String(c[c.startIndex..<mid]))
                safeChunks.append(String(c[mid..<c.endIndex]))
            } else {
                safeChunks.append(c)
            }
        }
        return safeChunks
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

    func cancelTranscription() {
        Task {
            await speechAnalyzer?.cancelAndFinishNow()
            speechAnalyzer = nil
            isTranscribing = false
            translationSession = nil
            statusMessage = "Operation cancelled."
        }
    }
    
    // MARK: - Private Implementation Details

    private func requestSpeechRecognitionPermission() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        if status == .denied || status == .restricted { throw TranscriptionError.permissionDenied }
        
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus == .authorized)
            }
        }
        
        if !granted {
            throw TranscriptionError.permissionDenied
        }
    }

    private func extractAudio(from videoURL: URL, duration: TimeInterval? = nil) async throws -> URL {
        print("🟠 [extractAudio] Called for URL: \(videoURL)")
        do {
            print("🟠 [extractAudio] About to create AVURLAsset")
            let asset = AVURLAsset(url: videoURL)
            print("🟠 [extractAudio] Created AVURLAsset: duration = \(String(describing: try? await asset.load(.duration)))")

            print("🟠 [extractAudio] About to create AVAssetExportSession")
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                print("🔴 [extractAudio] AVAssetExportSession is nil. Asset may not be exportable.")
                throw TranscriptionError.audioExtractionFailed
            }
            
            if let duration {
                exportSession.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            }
            
            let tempAudioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")

            print("🟠 [extractAudio] About to export audio to \(tempAudioURL)")
            try await exportSession.export(to: tempAudioURL, as: .m4a)
            print("🟠 [extractAudio] Audio export complete: \(tempAudioURL)")

            return tempAudioURL
        } catch {
            print("🔴 [extractAudio] Caught error: \(error)")
            throw error
        }
    }

    private func detectLanguage(from sampleAudioURL: URL) async throws -> Locale {
        print("🟢 Entered detectLanguage")
        
        // Choose a fallback locale based on the system locale, mapped to a SpeechTranscriber-supported equivalent
        let systemLocale = Locale.current
        let fallbackLocale = await SpeechTranscriber.supportedLocale(equivalentTo: systemLocale) ?? Locale(identifier: "en-US")
        print("🟢 Using fallback locale for preliminary pass: \(fallbackLocale.identifier)")
        
        // Preflight model installation for the fallback locale to avoid nilError due to missing assets
        do {
            let transcriber = SpeechTranscriber(locale: fallbackLocale, preset: .transcription)
            if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                statusMessage = "Preparing language model (\(fallbackLocale.identifier))..."
                try await installationRequest.downloadAndInstall()
            }
        } catch {
            print("🟠 Failed to pre-install assets for \(fallbackLocale.identifier): \(error)")
            // Not fatal; proceed and let performTranscription handle further issues
        }
        
        print("🟢 About to call performTranscription with locale: \(fallbackLocale.identifier) (fallback)")
        do {
            let preliminaryTranscript = try await performTranscription(
                fullAudioURL: sampleAudioURL,
                locale: fallbackLocale
            )
            print("🟢 Preliminary transcript: \(preliminaryTranscript.prefix(100))...")

            let languageRecognizer = NLLanguageRecognizer()
            languageRecognizer.processString(preliminaryTranscript)
            
            guard let languageCode = languageRecognizer.dominantLanguage?.rawValue,
                  let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) else {
                return systemLocale
            }
            print("🟢 LanguageRecognizer detected: \(languageCode)")

            // Validate against SpeechTranscriber supported locales (beta API)
            let supportedLocales = await SpeechTranscriber.supportedLocales
            if !supportedLocales.contains(supportedLocale) {
                throw TranscriptionError.languageNotSupported(supportedLocale)
            }
            
            print("🟢 Returning detected locale: \(supportedLocale.identifier)")
            return supportedLocale
        } catch {
            print("🛑 Failed preliminary transcription: \(error)")
            throw error
        }
    }

    private func performTranscription(fullAudioURL: URL, locale: Locale) async throws -> String {
        // Use the correct beta preset
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            statusMessage = "Downloading language model (\(locale.identifier))..."
            try await installationRequest.downloadAndInstall()
        }
        
        // Get the best available audio format for this transcriber
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.speechAnalyzer = analyzer

        // Prepare the analyzer for better performance
        try await analyzer.prepareToAnalyze(in: audioFormat)

        let asset = AVURLAsset(url: fullAudioURL)
        let duration = try await asset.load(.duration)
        let fileExtension = fullAudioURL.pathExtension.lowercased()
        let audioExtensions = ["m4a", "mp3", "wav", "aac", "caf", "aiff"]

        let audioURLToTranscribe: URL
        if audioExtensions.contains(fileExtension) {
            // Already audio; just use it
            print("🟢 [performTranscription] Using existing audio file: \(fullAudioURL)")
            audioURLToTranscribe = fullAudioURL
        } else {
            // Extract audio from video
            audioURLToTranscribe = try await extractAudio(from: fullAudioURL, duration: CMTimeGetSeconds(duration))
            print("🟢 [performTranscription] Extracted audio file: \(audioURLToTranscribe)")
        }
        let audioFile = try AVAudioFile(forReading: audioURLToTranscribe)
        
        // Collect results using proper async pattern
        let resultsTask = Task { () -> [String] in
            var transcriptParts: [String] = []
            do {
                for try await result in transcriber.results {
                    if result.isFinal {
                        transcriptParts.append(String(result.text.characters))
                    }
                }
            } catch {
                print("🔴 Results collection error: \(error)")
                throw error
            }
            return transcriptParts
        }
        
        // Perform the analysis using the documented beta pattern
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            
            // Finalize analysis through the end of input
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            
            // Await the results from the collector task
            let fullTranscriptParts = try await resultsTask.value

            let combinedText = fullTranscriptParts.joined(separator: " ")
            if combinedText.isEmpty {
                throw TranscriptionError.noSpeechDetected
            }
            
            // Cleanup temp file if it was extracted from video
            if !audioExtensions.contains(fileExtension) {
                try? FileManager.default.removeItem(at: audioURLToTranscribe)
            }
            
            return combinedText
            
        } catch {
            // Cancel results collection if analysis fails
            resultsTask.cancel()
            throw error
        }
    }
    
    // MARK: - Translation Implementation
    
    private func translateText(_ text: String, from sourceLanguage: Locale.Language, to targetLanguage: Locale.Language) async throws -> String {
        print("🟢 Starting translation from \(sourceLanguage) to \(targetLanguage)")
        
        do {
            statusMessage = "Checking translation models..."
            
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            self.translationSession = session
            
            try await session.prepareTranslation()
            
            statusMessage = "Translating to \(targetLanguage.languageCode?.identifier ?? "target language")..."
            
            let response = try await session.translate(text)
            
            print("🟢 Translation successful: \(response.targetText.prefix(100))...")
            return response.targetText
            
        } catch {
            print("🔴 Translation error: \(error)")
            
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
    
    // MARK: - Helper Functions
    
    private func detectLanguageFromText(_ text: String) -> Locale.Language {
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(text)
        
        guard let languageCode = languageRecognizer.dominantLanguage?.rawValue else {
            // Fallback to current system language
            return Locale.current.language
        }
        
        return Locale(identifier: languageCode).language
    }
    
    // Retained for direct single-shot summaries if needed elsewhere; map→reduce uses these pieces internally now.
    private func generateSummary(for text: String) async throws -> String {
        print("🟢 Starting summarization with Foundation Models")
        
        // Get the system language model
        let model = SystemLanguageModel.default
        
        let availability = model.availability
        switch availability {
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
        
        let instructions = Instructions("""
        You are an expert at creating concise, well-structured summaries of video transcripts. 
        
        Your task is to:
        1. Identify and extract the main topics and key points from the transcript
        2. Organize the information in a logical, coherent structure
        3. Write a comprehensive summary using proper Markdown formatting
        4. Focus on the most important information while maintaining context
        5. Use clear headings, bullet points, and emphasis where appropriate
        
        Format your response as a properly structured Markdown document with:
        - A brief overview paragraph
        - Main sections with descriptive headings (##)
        - Key points as bullet lists where appropriate
        - Important concepts in **bold** or *italics*
        
        Keep the summary comprehensive but concise, covering all significant topics while being easy to read and well-organized.
        """)
        
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Please create a well-structured summary of the following transcript using proper Markdown formatting:\n\n\(text)"
        
        statusMessage = "Processing with Apple Intelligence..."
        
        let response = try await session.respond(to: prompt)
        
        print("🟢 Summarization successful: \(response.content.prefix(100))...")
        return response.content
    }
}

