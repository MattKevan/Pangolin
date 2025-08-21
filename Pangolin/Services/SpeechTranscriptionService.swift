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
    
    // iOS 26.0+ properties stored as Any to avoid compilation issues
    private var _currentAnalyzer: Any?
    
    // Legacy properties for current SDK
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    
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
            
            if #available(iOS 26.0, macOS 26.0, *) {
                transcriptText = try await performModernTranscription(audioFile: audioFile, locale: detectedLocale)
            } else {
                transcriptText = try await performLegacyTranscription(audioFile: audioFile, locale: detectedLocale)
            }
            
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
            
            // Use modern export API if available, fallback to legacy
            if #available(macOS 15.0, iOS 18.0, *) {
                Task {
                    do {
                        for await state in session.states(updateInterval: 0.1) {
                            switch state.status {
                            case .completed:
                                continuation.resume(returning: tempAudioURL)
                                return
                            case .failed, .cancelled:
                                continuation.resume(throwing: TranscriptionError.audioExtractionFailed)
                                return
                            case .waiting, .exporting:
                                continue
                            @unknown default:
                                continue
                            }
                        }
                    } catch {
                        continuation.resume(throwing: TranscriptionError.audioExtractionFailed)
                    }
                }
                session.export()
            } else {
                // Legacy approach
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
    }
    
    private func detectLanguage(from audioURL: URL, video: Video) async -> Locale {
        // First, try to detect language from existing subtitles
        if let subtitles = video.subtitles as? Set<Subtitle>,
           let firstSubtitle = subtitles.first,
           let language = firstSubtitle.language {
            return Locale(identifier: language)
        }
        
        // Could implement audio-based language detection here using the extracted audio
        // For now, use system locale as fallback
        return Locale.current
    }
    
    // MARK: - iOS 26.0+ Modern Implementation
    @available(iOS 26.0, macOS 26.0, *)
    private func performModernTranscription(audioFile: URL, locale: Locale) async throws -> String {
        // This implementation will work when iOS 26.0 SDK is available
        // For now, fall back to legacy implementation
        return try await performLegacyTranscription(audioFile: audioFile, locale: locale)
        
        /*
        // Full iOS 26.0 implementation - uncomment when SDK is available:
        statusMessage = "Setting up modern speech transcriber..."
        guard let supportedLocale = SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.languageNotSupported(locale)
        }
        
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechTranscriberNotAvailable
        }
        
        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcriptionWithAlternatives)
        progress = 0.4
        
        // Download assets if needed
        statusMessage = "Downloading speech assets if needed..."
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }
        progress = 0.5
        
        // Get the best available audio format
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        
        // Create the analyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        _currentAnalyzer = analyzer
        
        var transcriptParts: [String] = []
        var totalConfidence: Double = 0.0
        var resultCount = 0
        
        // Collect results
        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if !text.isEmpty {
                        transcriptParts.append(text)
                        
                        if let confidence = result.text.runs.first?.transcriptionConfidence {
                            totalConfidence += confidence
                            resultCount += 1
                        }
                        
                        await MainActor.run {
                            self.progress = min(0.8, 0.5 + Double(transcriptParts.count) * 0.05)
                        }
                    }
                }
            } catch {
                throw error
            }
        }
        
        do {
            let audioFileObj = try AVAudioFile(forReading: audioFile)
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFileObj)
            
            if let lastSampleTime = lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            
            try await resultsTask.value
            
        } catch {
            resultsTask.cancel()
            _currentAnalyzer = nil
            throw error
        }
        
        _currentAnalyzer = nil
        
        let fullTranscript = transcriptParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if fullTranscript.isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        
        if resultCount > 0 {
            let averageConfidence = totalConfidence / Double(resultCount)
            print("📊 Modern transcription completed with average confidence: \(String(format: "%.2f", averageConfidence))")
        }
        
        return fullTranscript
        */
    }
    
    // MARK: - Legacy Implementation (iOS < 26.0)
    private func performLegacyTranscription(audioFile: URL, locale: Locale) async throws -> String {
        statusMessage = "Setting up legacy speech recognizer..."
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.languageNotSupported(locale)
        }
        
        guard speechRecognizer.isAvailable else {
            throw TranscriptionError.speechTranscriberNotAvailable
        }
        
        self.speechRecognizer = speechRecognizer
        progress = 0.4
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: audioFile)
            request.shouldReportPartialResults = false
            request.taskHint = .dictation
            
            if #available(iOS 13.0, macOS 10.15, *) {
                request.requiresOnDeviceRecognition = false
            }
            
            recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: TranscriptionError.noSpeechDetected)
                    return
                }
                
                if result.isFinal {
                    let transcript = result.bestTranscription.formattedString
                    if transcript.isEmpty {
                        continuation.resume(throwing: TranscriptionError.noSpeechDetected)
                    } else {
                        print("📊 Legacy transcription completed")
                        continuation.resume(returning: transcript)
                    }
                }
            }
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
        if #available(iOS 26.0, macOS 26.0, *), _currentAnalyzer != nil {
            // Modern cancellation - would work with real iOS 26 SDK
            _currentAnalyzer = nil
        } else {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
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