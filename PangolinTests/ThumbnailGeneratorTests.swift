import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Pangolin

struct ThumbnailGeneratorTests {
    @Test("Frame time uses ten percent of duration capped at five seconds")
    func frameTimeIsBounded() {
        #expect(ThumbnailGenerator.frameTime(forDuration: 20) == 2)
        #expect(ThumbnailGenerator.frameTime(forDuration: 120) == 5)
        #expect(ThumbnailGenerator.frameTime(forDuration: 0) == 0)
        #expect(ThumbnailGenerator.frameTime(forDuration: -10) == 0)
    }

    @Test("JPEG validation rejects empty and arbitrary data")
    func rejectsInvalidJPEGData() {
        #expect(!ThumbnailGenerator.isValidJPEG(Data()))
        #expect(!ThumbnailGenerator.isValidJPEG(Data("not a jpeg".utf8)))
    }

    @Test("Generated JPEG is valid, bounded, and does not upscale")
    func generatesBoundedJPEGWithoutUpscaling() async throws {
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-generator-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try await makeTestVideo(at: videoURL, width: 320, height: 180)

        let data = try await ThumbnailGenerator().generate(from: videoURL)
        let size = try #require(ThumbnailGenerator.pixelSize(ofJPEG: data))

        #expect(ThumbnailGenerator.isValidJPEG(data))
        #expect(size.width <= ThumbnailGenerator.maximumSize.width)
        #expect(size.height <= ThumbnailGenerator.maximumSize.height)
        #expect(size == CGSize(width: 320, height: 180))

        let truncatedData = Data(data.prefix(data.count / 2))
        #expect(!ThumbnailGenerator.isValidJPEG(truncatedData))
        #expect(ThumbnailGenerator.pixelSize(ofJPEG: truncatedData) == nil)

        let missingEndMarker = Data(data.dropLast(2))
        #expect(!ThumbnailGenerator.isValidJPEG(missingEndMarker))
        #expect(ThumbnailGenerator.pixelSize(ofJPEG: missingEndMarker) == nil)
    }
}

private func makeTestVideo(at url: URL, width: Int, height: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )

    guard writer.canAdd(input) else {
        throw TestVideoError.cannotAddInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? TestVideoError.cannotStartWriting
    }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<30 {
        let clock = ContinuousClock()
        let readinessDeadline = clock.now.advanced(by: .seconds(5))
        while !input.isReadyForMoreMediaData {
            if let error = writer.error {
                throw error
            }
            switch writer.status {
            case .failed:
                throw TestVideoError.writerFailed
            case .cancelled:
                throw TestVideoError.writerCancelled
            case .completed, .unknown:
                throw TestVideoError.writerStoppedBeforeInputWasReady
            case .writing:
                break
            @unknown default:
                throw TestVideoError.writerStoppedBeforeInputWasReady
            }
            guard clock.now < readinessDeadline else {
                writer.cancelWriting()
                throw TestVideoError.inputReadinessTimedOut
            }
            await Task.yield()
        }
        let buffer = try makePixelBuffer(width: width, height: height)
        let time = CMTime(value: CMTimeValue(frame), timescale: 30)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? TestVideoError.cannotAppendFrame
        }
    }

    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
    await withCheckedContinuation { continuation in
        writer.finishWriting {
            continuation.resume()
        }
    }
    guard writer.status == .completed else {
        throw writer.error ?? TestVideoError.cannotFinishWriting
    }
}

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw TestVideoError.cannotCreatePixelBuffer
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
        throw TestVideoError.cannotCreatePixelBuffer
    }
    memset(baseAddress, 0x66, CVPixelBufferGetDataSize(buffer))
    return buffer
}

private enum TestVideoError: Error {
    case cannotAddInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting
    case cannotCreatePixelBuffer
    case writerFailed
    case writerCancelled
    case writerStoppedBeforeInputWasReady
    case inputReadinessTimedOut
}
