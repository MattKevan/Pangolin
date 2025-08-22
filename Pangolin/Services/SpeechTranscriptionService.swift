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

    func transcribeVideo(_ video: Video, libraryManager: LibraryManager) async {
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
            
            statusMessage = "Extracting audio sample..."
            let sampleAudioURL = try await extractAudio(from: videoURL, duration: 15.0)
            defer { try? FileManager.default.removeItem(at: sampleAudioURL) }
            progress = 0.2
            
            statusMessage = "Detecting language..."
            let detectedLocale = try await detectLanguage(from: sampleAudioURL)
            
            // Diagnostic: Print detected language and supported locales for debugging
            print("🧠 DETECTED: Language locale is \(detectedLocale.identifier)")
            let supportedLocales = SFSpeechRecognizer.supportedLocales()
            print("🧠 SUPPORTED LOCALES:")
            for locale in supportedLocales.sorted(by: { $0.identifier < $1.identifier }) {
                print("- \(locale.identifier)")
            }
            
            progress = 0.3
            
            statusMessage = "Transcribing main audio..."
            let transcriptText = try await performTranscription(
                fullAudioURL: videoURL,
                locale: detectedLocale
            )
            progress = 0.9
            
            statusMessage = "Saving transcript..."
            video.transcriptText = transcriptText
            video.transcriptLanguage = detectedLocale.identifier
            video.transcriptDateGenerated = Date()
            // Auto-translate if the detected language is different from system language
            let systemLanguage = Locale.current.language
            let detectedLanguage = detectedLocale.language
            
            if detectedLanguage != systemLanguage {
                statusMessage = "Translating transcript..."
                progress = 0.95
                
                do {
                    let translatedText = try await translateText(transcriptText, from: detectedLanguage, to: systemLanguage)
                    video.translatedText = translatedText
                    video.translatedLanguage = systemLanguage.languageCode?.identifier
                    video.translationDateGenerated = Date()
                    print("🟢 Translation completed successfully")
                } catch {
                    print("🟠 Translation failed, but continuing: \\(error)")
                    // Don't fail the whole process if translation fails
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


    func translateVideo(_ video: Video, libraryManager: LibraryManager) async {
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
                
                // Check if the parsed language is valid
                if sourceLanguage.languageCode?.identifier == nil || sourceLanguage.languageCode?.identifier.isEmpty == true {
                    print("🟠 Invalid stored language identifier, attempting to detect from transcript...")
                    // Try to detect language from transcript text
                    let detectedLanguage = detectLanguageFromText(transcriptText)
                    sourceLanguage = detectedLanguage
                    // Update the stored language with the correct identifier
                    video.transcriptLanguage = detectedLanguage.languageCode?.identifier
                }
            } else {
                print("🟠 No transcript language stored, detecting from transcript text...")
                // Detect language from transcript text
                let detectedLanguage = detectLanguageFromText(transcriptText)
                sourceLanguage = detectedLanguage
                // Store the detected language
                video.transcriptLanguage = detectedLanguage.languageCode?.identifier
            }
            
            let targetLanguage = Locale.current.language
            
            // Validate that both languages have valid language codes
            guard let sourceCode = sourceLanguage.languageCode?.identifier, !sourceCode.isEmpty else {
                print("🔴 Invalid source language code: \(sourceLanguage)")
                throw TranscriptionError.translationNotSupported(
                    "Invalid source language",
                    targetLanguage.languageCode?.identifier ?? "unknown"
                )
            }
            
            guard let targetCode = targetLanguage.languageCode?.identifier, !targetCode.isEmpty else {
                print("🔴 Invalid target language code: \(targetLanguage)")
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
            let translatedText = try await translateText(transcriptText, from: sourceLanguage, to: targetLanguage)
            
            progress = 0.9
            statusMessage = "Saving translation..."
            
            video.translatedText = translatedText
            video.translatedLanguage = targetLanguage.languageCode?.identifier
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

    func summarizeVideo(_ video: Video, libraryManager: LibraryManager) async {
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
        errorMessage = nil
        progress = 0.0
        statusMessage = "Generating summary..."
        
        do {
            progress = 0.2
            let summary = try await generateSummary(for: textToSummarize)
            
            progress = 0.8
            statusMessage = "Saving summary..."
            
            video.transcriptSummary = summary
            video.summaryDateGenerated = Date()
            await libraryManager.save()
            
            progress = 1.0
            statusMessage = "Summary complete!"
            
        } catch {
            let localizedError = error as? LocalizedError
            errorMessage = localizedError?.errorDescription ?? "An unknown error occurred."
            print("🚨 Summarization error: \(error)")
        }
        
        isTranscribing = false
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
        print("🟢 About to call performTranscription with locale: en-US (fallback)")
        do {
            let preliminaryTranscript = try await performTranscription(
                fullAudioURL: sampleAudioURL,
                locale: Locale(identifier: "en-US") // fallback for language guessing
            )
            print("🟢 Preliminary transcript: \(preliminaryTranscript.prefix(100))...")

            let languageRecognizer = NLLanguageRecognizer()
            languageRecognizer.processString(preliminaryTranscript)
            
            guard let languageCode = languageRecognizer.dominantLanguage?.rawValue,
                  let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) else {
                return Locale.current
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
                        // Correctly convert from AttributedString.CharacterView to String
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
            // Check if translation models are available and install if needed
            statusMessage = "Checking translation models..."
            
            // Create translation session using the beta API
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            self.translationSession = session
            
            // The Translation framework will handle model downloads automatically
            // during prepareTranslation() if needed
            
            // Prepare the translation session
            try await session.prepareTranslation()
            
            statusMessage = "Translating to \(targetLanguage.languageCode?.identifier ?? "target language")..."
            
            // Perform the translation
            let response = try await session.translate(text)
            
            print("🟢 Translation successful: \(response.targetText.prefix(100))...")
            return response.targetText
            
        } catch {
            print("🔴 Translation error: \(error)")
            
            // Check if it's a TranslationError with notInstalled cause
            if let translationError = error as? TranslationError,
               String(describing: translationError).contains("notInstalled") {
                throw TranscriptionError.translationModelsNotInstalled(
                    sourceLanguage.languageCode?.identifier ?? "unknown",
                    targetLanguage.languageCode?.identifier ?? "unknown"
                )
            }
            
            // Map other specific translation errors
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
        
        // Create instructions for summarization
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
        
        // Create a session with the summarization-optimized instructions
        let session = LanguageModelSession(instructions: instructions)
        
        // Create the summarization prompt
        let prompt = "Please create a well-structured summary of the following transcript using proper Markdown formatting:\n\n\(text)"
        
        statusMessage = "Processing with Apple Intelligence..."
        
        // Generate the summary
        let response = try await session.respond(to: prompt)
        
        print("🟢 Summarization successful: \(response.content.prefix(100))...")
        return response.content
    }
}
