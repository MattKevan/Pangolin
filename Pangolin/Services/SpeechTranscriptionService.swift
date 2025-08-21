import Foundation
import Speech
import AVFoundation
import NaturalLanguage

@MainActor
class SpeechTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    
    // iOS 26.0+ properties
    private var _currentAnalyzer: Any?
    
    func transcribeVideo(_ video: Video, libraryManager: LibraryManager) async {
        guard !isTranscribing else { return }
        
        isTranscribing = true
        errorMessage = nil
        progress = 0.0
        statusMessage = "Preparing transcription..."
        
        do {
            // Step 1: Check permissions
            statusMessage = "Checking speech recognition permissions..."
            try await requestSpeechRecognitionPermission()
            progress = 0.1
            
            // Step 2: Extract audio from video
            statusMessage = "Extracting audio from video..."
            let audioFile = try await extractAudioFromVideo(video)
            progress = 0.2
            
            // Step 3: Detect language 
            statusMessage = "Detecting language..."
            let detectedLocale = await detectLanguage(from: audioFile, video: video)
            progress = 0.3
            
            // Step 4: Perform transcription using available API
            statusMessage = "Transcribing audio..."
            let transcriptText: String
            
            transcriptText = try await performModernTranscription(audioFile: audioFile, locale: detectedLocale)
            
            progress = 0.9
            
            // Step 7: Save results
            statusMessage = "Saving transcript..."
            await saveTranscriptionResults(
                video: video,
                transcriptText: transcriptText,
                language: detectedLocale.identifier,
                libraryManager: libraryManager
            )
            progress = 1.0
            statusMessage = "Transcription completed!"
            
            // Clean up temporary audio file
            try? FileManager.default.removeItem(at: audioFile)
            
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            print("🚨 Transcription error: \(error)")
        }
        
        isTranscribing = false
    }
    
    private func requestSpeechRecognitionPermission() async throws {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        
        switch authorizationStatus {
        case .authorized:
            return
        case .notDetermined:
            return try await withCheckedThrowingContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    switch status {
                    case .authorized:
                        continuation.resume()
                    case .denied, .restricted, .notDetermined:
                        continuation.resume(throwing: TranscriptionError.permissionDenied)
                    @unknown default:
                        continuation.resume(throwing: TranscriptionError.permissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            throw TranscriptionError.permissionDenied
        @unknown default:
            throw TranscriptionError.permissionDenied
        }
    }
    
    private func extractAudioFromVideo(_ video: Video) async throws -> URL {
        let videoURL = try video.getFileURL()
        let tempAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(video.id!.uuidString)
            .appendingPathExtension("m4a")
        
        let asset = AVURLAsset(url: videoURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed
        }
        
        exportSession.outputURL = tempAudioURL
        exportSession.outputFileType = .m4a
        
        return try await withCheckedThrowingContinuation { [weak exportSession] continuation in
            guard let session = exportSession else {
                continuation.resume(throwing: TranscriptionError.audioExtractionFailed)
                return
            }
            
            // Use export session
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: tempAudioURL)
                case .failed, .cancelled:
                    continuation.resume(throwing: TranscriptionError.audioExtractionFailed)
                default:
                    continuation.resume(throwing: TranscriptionError.audioExtractionFailed)
                }
            }
        }
    }
    
    private func detectLanguage(from audioURL: URL, video: Video) async -> Locale {
        // First, try to detect language from existing subtitles
        if let subtitles = video.subtitles as? Set<Subtitle>,
           let firstSubtitle = subtitles.first,
           let language = firstSubtitle.language {
            return Locale(identifier: language)
        }
        
        // Try audio-based language detection using Speech Recognition
        do {
            let detectedLocale = try await detectLanguageFromAudio(audioURL)
            if detectedLocale != nil {
                return detectedLocale!
            }
        } catch {
            print("🚨 Language detection failed: \(error)")
        }
        
        // Fallback to system locale
        return Locale.current
    }
    
    private func detectLanguageFromAudio(_ audioURL: URL) async throws -> Locale? {
        // Extract a small sample from the beginning for language detection
        let sampleURL = try await extractAudioSample(from: audioURL, duration: 10.0)
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        
        // Get list of supported locales for speech recognition
        let supportedLocales = SpeechRecognizer.supportedLocales()
        
        // Try detection with the most common languages first
        let commonLanguages = ["en-US", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "ko-KR", "zh-CN"]
        
        for languageCode in commonLanguages {
            if let locale = supportedLocales.first(where: { $0.identifier.hasPrefix(languageCode.prefix(2)) }) {
                if let confidence = try await testLanguageConfidence(audioURL: sampleURL, locale: locale) {
                    if confidence > 0.6 { // High confidence threshold
                        print("🎯 Detected language: \(locale.identifier) with confidence: \(confidence)")
                        return locale
                    }
                }
            }
        }
        
        return nil
    }
    
    private func extractAudioSample(from audioURL: URL, duration: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: audioURL)
        let tempSampleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed
        }
        
        exportSession.outputURL = tempSampleURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        
        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: tempSampleURL)
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? TranscriptionError.audioExtractionFailed)
                case .cancelled:
                    continuation.resume(throwing: TranscriptionError.cancelled)
                default:
                    continuation.resume(throwing: TranscriptionError.audioExtractionFailed)
                }
            }
        }
    }
    
    private func testLanguageConfidence(audioURL: URL, locale: Locale) async throws -> Double? {
        guard SpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        
        let recognizer = SpeechRecognizer(locale: locale)
        guard recognizer.isAvailable else { return nil }
        
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let result = result, result.isFinal {
                    let confidence = result.bestTranscription.segments.isEmpty ? 0.0 : 
                        result.bestTranscription.segments.map { $0.confidence }.reduce(0, +) / Double(result.bestTranscription.segments.count)
                    continuation.resume(returning: confidence)
                }
            }
        }
    }
    
    // MARK: - iOS 26.0+ Modern Implementation
    private func performModernTranscription(audioFile: URL, locale: Locale) async throws -> String {
        // iOS 26.0 beta implementation using modern SpeechTranscriber APIs
        
        statusMessage = "Setting up modern speech transcriber..."
        
        // Step 1: Create transcriber with enhanced configuration for better quality
        let transcriber = SpeechTranscriber(locale: locale,
                                           transcriptionOptions: [.enablePunctuation, .enableCapitalization],
                                           reportingOptions: [.includeWordConfidences, .includeTimestamps],
                                           attributeOptions: [.includePartialResults])
        progress = 0.3
        
        // Step 2: Ensure model is available
        statusMessage = "Ensuring speech model availability..."
        try await ensureModel(transcriber: transcriber, locale: locale)
        progress = 0.4
        
        // Step 3: Get the best available audio format
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioExtractionFailed
        }
        
        // Step 4: Create the analyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        _currentAnalyzer = analyzer
        progress = 0.5
        
        // Step 5: Set up input stream
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        
        // Step 6: Collect results
        var transcriptParts: [String] = []
        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal && !text.isEmpty {
                        transcriptParts.append(text)
                        await MainActor.run {
                            self.progress = min(0.9, 0.5 + Double(transcriptParts.count) * 0.05)
                        }
                    }
                }
            } catch {
                throw error
            }
        }
        
        // Step 7: Start analysis
        try await analyzer.start(inputSequence: inputSequence)
        statusMessage = "Transcribing audio..."
        
        // Step 8: Process audio file
        do {
            let audioFile = try AVAudioFile(forReading: audioFile)
            
            // Convert and stream audio data
            let bufferSize: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: bufferSize) else {
                throw TranscriptionError.audioExtractionFailed
            }
            
            while audioFile.framePosition < audioFile.length {
                try audioFile.read(into: buffer)
                
                if buffer.frameLength > 0 {
                    // Convert buffer to analyzer format if needed
                    let convertedBuffer: AVAudioPCMBuffer
                    if buffer.format == audioFormat {
                        convertedBuffer = buffer
                    } else {
                        // Create converter if formats don't match
                        guard let converter = AVAudioConverter(from: buffer.format, to: audioFormat) else {
                            throw TranscriptionError.audioExtractionFailed
                        }
                        
                        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: bufferSize) else {
                            throw TranscriptionError.audioExtractionFailed
                        }
                        
                        var error: NSError?
                        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                            outStatus.pointee = AVAudioConverterInputStatus.haveData
                            return buffer
                        }
                        
                        if status == .error {
                            throw TranscriptionError.audioExtractionFailed
                        }
                        
                        convertedBuffer = outputBuffer
                    }
                    
                    let input = AnalyzerInput(buffer: convertedBuffer)
                    inputBuilder.yield(input)
                }
            }
            
            // Step 9: Finish processing
            inputBuilder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            
            // Wait for results
            try await resultsTask.value
            
            _currentAnalyzer = nil
            
            let rawTranscript = transcriptParts.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            if rawTranscript.isEmpty {
                throw TranscriptionError.noSpeechDetected
            }
            
            // Post-process and validate transcript quality
            let fullTranscript = try cleanupTranscript(rawTranscript)
            
            if !isTranscriptQualityAcceptable(fullTranscript) {
                throw TranscriptionError.poorQualityTranscription
            }
            
            print("📊 Modern transcription completed successfully with \(transcriptParts.count) parts")
            return fullTranscript
            
        } catch {
            resultsTask.cancel()
            _currentAnalyzer = nil
            throw error
        }
    }
    
    // MARK: - Model Management
    private func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw TranscriptionError.languageNotSupported(locale)
        }
        
        if await installed(locale: locale) {
            return
        } else {
            try await downloadIfNeeded(for: transcriber)
        }
    }
    
    private func supported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    private func installed(locale: Locale) async -> Bool {
        let installed = await Set(SpeechTranscriber.installedLocales)
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    private func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        statusMessage = "Downloading speech models..."
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }
    
    
    private func saveTranscriptionResults(
        video: Video,
        transcriptText: String,
        language: String,
        libraryManager: LibraryManager
    ) async {
        video.transcriptText = transcriptText
        video.transcriptLanguage = language
        video.transcriptStatus = "completed"
        video.transcriptDateGenerated = Date()
        
        await libraryManager.save()
    }
    
    func cancelTranscription() {
        if let analyzer = _currentAnalyzer as? SpeechAnalyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        _currentAnalyzer = nil
        
        isTranscribing = false
        statusMessage = "Transcription cancelled"
    }
}

// MARK: - Video Extension
extension Video {
    func getFileURL() throws -> URL {
        guard let fileURL = fileURL else {
            throw TranscriptionError.videoFileNotFound
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptionError.videoFileNotFound
        }
        
        return fileURL
    }
}

// MARK: - Error Types
enum TranscriptionError: LocalizedError {
    case permissionDenied
    case languageNotSupported(Locale)
    case speechTranscriberNotAvailable
    case audioExtractionFailed
    case videoFileNotFound
    case noSpeechDetected
    case assetInstallationFailed
    case analysisSessionFailed
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission is required to transcribe videos."
        case .languageNotSupported(let locale):
            return "The detected language (\(locale.localizedString(forIdentifier: locale.identifier) ?? "Unknown")) is not supported for transcription."
        case .speechTranscriberNotAvailable:
            return "SpeechTranscriber is not available on this device. This feature requires iOS 26.0+ with compatible hardware."
        case .audioExtractionFailed:
            return "Failed to extract audio from the video file. Please ensure the video format is supported."
        case .videoFileNotFound:
            return "Could not locate the video file for transcription. The file may have been moved or deleted."
        case .noSpeechDetected:
            return "No speech was detected in the audio. The video may contain only music, ambient sounds, or very quiet speech."
        case .assetInstallationFailed:
            return "Failed to download required speech recognition assets. Please check your internet connection and try again."
        case .analysisSessionFailed:
            return "Speech analysis session failed unexpectedly. Please try again."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Go to Settings > Privacy & Security > Speech Recognition and enable access for Pangolin."
        case .languageNotSupported:
            return "Try changing your device language to a supported language, or manually select a different language for transcription."
        case .speechTranscriberNotAvailable:
            return "Update to iOS 26.0+ and ensure your device supports advanced speech recognition features."
        case .audioExtractionFailed:
            return "Try converting your video to a supported format (MP4, MOV, M4V) and try again."
        case .videoFileNotFound:
            return "Re-import the video file to your library and try transcription again."
        case .noSpeechDetected:
            return "Ensure the video contains clear speech and increase the device volume to maximum."
        case .assetInstallationFailed:
            return "Check your internet connection and ensure you have sufficient storage space for language assets."
        case .analysisSessionFailed:
            return "Close other apps to free up memory and try the transcription again."
        }
    }
}