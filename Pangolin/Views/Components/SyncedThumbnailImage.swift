import Foundation
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

actor ThumbnailImageCache {
    typealias Decoder = @Sendable (Data) -> PlatformImage?

    static let shared = ThumbnailImageCache()

    private let cache = NSCache<ThumbnailCacheKeyBox, PlatformImage>()
    private let decoder: Decoder
    private var inFlight: [ThumbnailCacheKey: Task<PlatformImage?, Never>] = [:]

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
        let cacheKey = ThumbnailCacheKeyBox(key)
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }
        if let existingTask = inFlight[key] {
            return await existingTask.value
        }

        let decoder = decoder
        let decodeTask = Task.detached(priority: .utility) {
            decoder(data)
        }
        inFlight[key] = decodeTask

        let image = await decodeTask.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: cacheKey, cost: data.count)
        }
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    nonisolated private static func decodeImage(_ data: Data) -> PlatformImage? {
        guard ThumbnailGenerator.isValidJPEG(data) else { return nil }
        return PlatformImage(data: data)
    }
}

private final class ThumbnailCacheKeyBox: NSObject {
    let key: ThumbnailCacheKey

    init(_ key: ThumbnailCacheKey) {
        self.key = key
    }

    override var hash: Int { key.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ThumbnailCacheKeyBox else { return false }
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
        .task(id: cacheKey) {
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
