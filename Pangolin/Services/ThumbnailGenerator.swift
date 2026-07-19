import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ThumbnailGenerating: Sendable {
    func generate(from videoURL: URL) async throws -> Data
}

actor ThumbnailGenerator: ThumbnailGenerating {
    static let currentVersion: Int16 = 1
    static let maximumSize = CGSize(width: 640, height: 360)
    static let jpegQuality = 0.78

    func generate(from videoURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = Self.maximumSize

        let time = CMTime(
            seconds: Self.frameTime(forDuration: CMTimeGetSeconds(duration)),
            preferredTimescale: 600
        )
        let image = try await imageGenerator.image(at: time).image
        return try Self.jpegData(from: image)
    }

    static func frameTime(forDuration duration: TimeInterval) -> TimeInterval {
        min(max(duration, 0) * 0.1, 5)
    }

    static func isValidJPEG(_ data: Data) -> Bool {
        pixelSize(ofJPEG: data) != nil
    }

    static func pixelSize(ofJPEG data: Data) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue > 0,
            height.doubleValue > 0
        else {
            return nil
        }

        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ThumbnailGenerationError.encodingFailed
        }

        let properties = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailGenerationError.encodingFailed
        }

        return data as Data
    }
}

enum ThumbnailGenerationError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "The thumbnail could not be encoded as JPEG."
    }
}
