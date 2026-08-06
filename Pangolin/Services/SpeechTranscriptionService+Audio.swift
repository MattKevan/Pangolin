import os
import Foundation
import Speech
import AVFoundation
import AudioToolbox
import CoreData

extension SpeechTranscriptionService {
    func requestSpeechRecognitionPermission() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        Logger.transcription.info("Transcription: Speech auth status before request = \(self.speechAuthorizationStatusLabel(status))")

        if status == .authorized {
            Logger.transcription.info("Transcription: Speech recognition already authorized")
            return
        }

        if status == .denied || status == .restricted {
            Logger.transcription.info("Transcription: Speech recognition blocked (\(self.speechAuthorizationStatusLabel(status)))")
            throw TranscriptionError.permissionDenied
        }

        let newStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
        Logger.transcription.info("Transcription: Speech auth callback status = \(self.speechAuthorizationStatusLabel(newStatus))")

        guard newStatus == .authorized else {
            Logger.transcription.info("Transcription: Speech recognition not authorized after request (\(self.speechAuthorizationStatusLabel(newStatus)))")
            throw TranscriptionError.permissionDenied
        }

        Logger.transcription.info("Transcription: Speech recognition authorized after request")
    }

    func speechAuthorizationStatusLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
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

    func extractAudio(from videoURL: URL, duration: TimeInterval? = nil) async throws -> URL {
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
    func transcodeAudioWithAssetPipeline(from sourceURL: URL, to targetFormat: AVAudioFormat) async throws -> URL {
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
                try await Task.sleep(for: .milliseconds(5))
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

    func convertAudio(_ sourceURL: URL, to targetFormat: AVAudioFormat) throws -> URL {
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

            if let conversionError = error {
                throw TranscriptionError.analysisFailed(conversionError.localizedDescription)
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

    func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        return lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }

}
