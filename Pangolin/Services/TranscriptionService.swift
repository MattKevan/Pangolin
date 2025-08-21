import Foundation
import Speech
import AVFoundation
import NaturalLanguage

@MainActor
class TranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    
    private var currentAnalyzer: SpeechAnalyzer?
    
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
            
            // Step 2: Extract and analyze audio
            statusMessage = "Extracting audio from video..."
            let audioFile = try await extractAudioFromVideo(video)
            progress = 0.2
            
            // Step 3: Detect language
            statusMessage = "Detecting language..."
            let detectedLocale = try await detectLanguage(from: audioFile)
            progress = 0.3
            
            // Step 4: Set up transcriber
            statusMessage = "Setting up speech transcriber..."
            guard let supportedLocale = SpeechTranscriber.supportedLocale(equivalentTo: detectedLocale) else {
                throw TranscriptionError.languageNotSupported(detectedLocale)
            }
            
            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
            progress = 0.4
            
            // Step 5: Download assets if needed
            statusMessage = "Downloading speech assets..."
            if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installationRequest.downloadAndInstall()
            }
            progress = 0.5
            
            // Step 6: Perform transcription
            statusMessage = "Transcribing audio..."
            let transcriptText = try await performTranscription(audioFile: audioFile, transcriber: transcriber)
            progress = 0.9
            
            // Step 7: Save results
            statusMessage = "Saving transcript..."
            await saveTranscriptionResults(
                video: video,
                transcriptText: transcriptText,
                language: supportedLocale.identifier,
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
        let videoURL = try video.fileURL()
        let tempAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(video.id!.uuidString)
            .appendingPathExtension("m4a")
        
        let asset = AVAsset(url: videoURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed
        }
        
        exportSession.outputURL = tempAudioURL
        exportSession.outputFileType = .m4a
        
        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
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
    
    private func detectLanguage(from audioURL: URL) async throws -> Locale {
        // For now, we'll use the system locale as default
        // In a more sophisticated implementation, you could analyze a sample of the audio
        // or use NLLanguageRecognizer on any existing subtitles
        return Locale.current
    }
    
    private func performTranscription(audioFile: URL, transcriber: SpeechTranscriber) async throws -> String {
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        currentAnalyzer = analyzer
        
        var fullTranscript = ""
        
        // Collect results
        let resultsTask = Task {
            var results: [String] = []
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    results.append(text)
                }
            } catch {
                throw error
            }
            return results.joined(separator: " ")
        }
        
        // Perform analysis
        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            
            fullTranscript = try await resultsTask.value
            
        } catch {
            resultsTask.cancel()
            throw error
        }
        
        currentAnalyzer = nil
        
        if fullTranscript.isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        
        return fullTranscript
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
        guard let analyzer = currentAnalyzer else { return }
        
        Task {
            try? analyzer.cancelAndFinishNow()
        }
        
        currentAnalyzer = nil
        isTranscribing = false
        statusMessage = "Transcription cancelled"
    }
}

extension Video {
    func fileURL() throws -> URL {
        guard let libraryPath = library?.libraryPath,
              let relativePath = relativePath else {
            throw TranscriptionError.videoFileNotFound
        }
        
        let fullPath = URL(fileURLWithPath: libraryPath).appendingPathComponent(relativePath)
        
        guard FileManager.default.fileExists(atPath: fullPath.path) else {
            throw TranscriptionError.videoFileNotFound
        }
        
        return fullPath
    }
}

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case languageNotSupported(Locale)
    case audioExtractionFailed
    case videoFileNotFound
    case noSpeechDetected
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech recognition permission is required to transcribe videos."
        case .languageNotSupported(let locale):
            return "The detected language (\(locale.localizedString(forIdentifier: locale.identifier) ?? "Unknown")) is not supported for transcription."
        case .audioExtractionFailed:
            return "Failed to extract audio from the video file."
        case .videoFileNotFound:
            return "Could not locate the video file for transcription."
        case .noSpeechDetected:
            return "No speech was detected in the audio. The video may contain only music or ambient sounds."
        }
    }
}