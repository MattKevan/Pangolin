import Foundation
import ImageIO
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ThumbnailCacheKey: Hashable, Sendable {
    let videoID: UUID
    let version: Int16
    let generatedAt: Date?
}

struct ThumbnailDataRevision: Hashable, Sendable {
    let byteCount: Int
    let fingerprint: UInt64

    init(_ data: Data) {
        byteCount = data.count
        fingerprint = data.withUnsafeBytes { bytes in
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }
}

struct ThumbnailImageRequestKey: Hashable, Sendable {
    let key: ThumbnailCacheKey
    let dataRevision: ThumbnailDataRevision?

    init(key: ThumbnailCacheKey, data: Data?) {
        self.key = key
        dataRevision = data.map(ThumbnailDataRevision.init)
    }
}

struct DecodedThumbnail: @unchecked Sendable {
    let image: PlatformImage
    let pixelCost: Int
}

actor ThumbnailImageCache {
    typealias Decoder = @Sendable (Data) -> DecodedThumbnail?

    static let shared = ThumbnailImageCache()

    private let cache = NSCache<ThumbnailImageRequestKeyBox, PlatformImage>()
    private let decoder: Decoder
    private var inFlight: [ThumbnailImageRequestKey: InFlightDecode] = [:]
    private var epoch: UInt64 = 0

    init(
        countLimit: Int = 256,
        totalCostLimit: Int = 64 * 1_024 * 1_024,
        decoder: @escaping Decoder = { data in
            ThumbnailImageCache.decodeImage(data)
        }
    ) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        self.decoder = decoder
    }

    func image(for key: ThumbnailCacheKey, data: Data) async -> PlatformImage? {
        let requestKey = ThumbnailImageRequestKey(key: key, data: data)
        let cacheKey = ThumbnailImageRequestKeyBox(requestKey)
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }
        if let existingDecode = inFlight[requestKey] {
            return await existingDecode.task.value?.image
        }

        let decoder = decoder
        let decodeID = UUID()
        let decodeEpoch = epoch
        let decodeTask: Task<DecodedThumbnail?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return decoder(data)
        }
        inFlight[requestKey] = InFlightDecode(id: decodeID, task: decodeTask)

        let decoded = await decodeTask.value
        if inFlight[requestKey]?.id == decodeID {
            inFlight[requestKey] = nil
        }
        guard epoch == decodeEpoch else { return decoded?.image }
        if let decoded {
            cache.setObject(decoded.image, forKey: cacheKey, cost: decoded.pixelCost)
        }
        return decoded?.image
    }

    func removeAll() {
        epoch &+= 1
        cache.removeAllObjects()
        for decode in inFlight.values {
            decode.task.cancel()
        }
        inFlight.removeAll()
    }

    nonisolated static func decodeImage(_ data: Data) -> DecodedThumbnail? {
        guard ThumbnailGenerator.isValidJPEG(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }

        let image: PlatformImage
        #if os(macOS)
        image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        #else
        image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        #endif
        return DecodedThumbnail(
            image: image,
            pixelCost: cgImage.bytesPerRow * cgImage.height
        )
    }
}

private struct InFlightDecode {
    let id: UUID
    let task: Task<DecodedThumbnail?, Never>
}

private final class ThumbnailImageRequestKeyBox: NSObject {
    let key: ThumbnailImageRequestKey

    init(_ key: ThumbnailImageRequestKey) {
        self.key = key
    }

    override var hash: Int { key.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ThumbnailImageRequestKeyBox else { return false }
        return key == other.key
    }
}

struct SyncedThumbnailImage<Placeholder: View>: View {
    let video: Video
    let contentMode: ContentMode
    let placeholder: Placeholder

    init(
        video: Video,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.video = video
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    var body: some View {
        ObservedSyncedThumbnailImage(
            video: video,
            contentMode: contentMode,
            placeholder: placeholder
        )
    }
}

private struct ObservedSyncedThumbnailImage<Placeholder: View>: View {
    @ObservedObject var video: Video
    let contentMode: ContentMode
    let placeholder: Placeholder

    @State private var platformImage: PlatformImage?

    private var cacheKey: ThumbnailCacheKey? {
        guard let videoID = video.id else { return nil }
        return ThumbnailCacheKey(
            videoID: videoID,
            version: video.thumbnailGenerationVersion,
            generatedAt: video.thumbnailGeneratedAt
        )
    }

    private var requestKey: ThumbnailImageRequestKey? {
        guard let cacheKey else { return nil }
        return ThumbnailImageRequestKey(key: cacheKey, data: video.thumbnailData)
    }

    var body: some View {
        Group {
            if let platformImage {
                Image(platformImage: platformImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: requestKey) {
            platformImage = nil
            guard let cacheKey, let data = video.thumbnailData else { return }
            let loadedImage = await ThumbnailImageCache.shared.image(for: cacheKey, data: data)
            guard !Task.isCancelled else { return }
            platformImage = loadedImage
        }
        .purgesThumbnailCacheOnPlatformPressure()
    }
}

private extension View {
    @ViewBuilder
    func purgesThumbnailCacheOnPlatformPressure() -> some View {
        #if os(iOS)
        onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            Task { await ThumbnailImageCache.shared.removeAll() }
        }
        #elseif os(macOS)
        onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            Task { await ThumbnailImageCache.shared.removeAll() }
        }
        #endif
    }
}
