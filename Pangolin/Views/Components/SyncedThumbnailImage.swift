import Combine
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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

struct ThumbnailImageRequestKey: Hashable, Sendable {
    let key: ThumbnailCacheKey
    let data: Data

    init(key: ThumbnailCacheKey, data: Data) {
        self.key = key
        self.data = data
    }
}

struct ThumbnailImageTaskKey: Hashable, Sendable {
    let cacheKey: ThumbnailCacheKey
    let dataChangeRevision: UInt64
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
        if var existingDecode = inFlight[requestKey] {
            existingDecode.waiterCount += 1
            inFlight[requestKey] = existingDecode
            return await resolvedImage(for: requestKey, decode: existingDecode)
        }

        let decoder = decoder
        let decodeID = UUID()
        let decodeTask: Task<DecodedThumbnail?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return decoder(data)
        }
        let decode = InFlightDecode(
            id: decodeID,
            epoch: epoch,
            task: decodeTask,
            waiterCount: 1
        )
        inFlight[requestKey] = decode
        return await resolvedImage(for: requestKey, decode: decode)
    }

    /// Empties the cache when the system reports memory pressure. Call once at launch.
    /// Switching apps is not memory pressure, so it no longer flushes thumbnails.
    @MainActor
    static func startObservingMemoryPressure() {
        guard memoryPressureObserver == nil else { return }
        memoryPressureObserver = MemoryPressureObserver {
            Task { await ThumbnailImageCache.shared.removeAll() }
        }
    }

    @MainActor private static var memoryPressureObserver: MemoryPressureObserver?

    func removeAll() {
        epoch &+= 1
        cache.removeAllObjects()
        for decode in inFlight.values {
            decode.task.cancel()
        }
        inFlight.removeAll()
    }

    func inFlightWaiterCount(for key: ThumbnailCacheKey, data: Data) -> Int {
        inFlight[ThumbnailImageRequestKey(key: key, data: data)]?.waiterCount ?? 0
    }

    private func resolvedImage(
        for requestKey: ThumbnailImageRequestKey,
        decode: InFlightDecode
    ) async -> PlatformImage? {
        let decoded = await decode.task.value
        guard epoch == decode.epoch else { return nil }

        if inFlight[requestKey]?.id == decode.id {
            inFlight[requestKey] = nil
            if let decoded {
                let (retainedCost, overflow) = decoded.pixelCost.addingReportingOverflow(
                    requestKey.data.count
                )
                cache.setObject(
                    decoded.image,
                    forKey: ThumbnailImageRequestKeyBox(requestKey),
                    cost: overflow ? Int.max : retainedCost
                )
            }
        }
        return decoded?.image
    }

    nonisolated static func decodeImage(_ data: Data) -> DecodedThumbnail? {
        guard data.count >= 2,
              data[data.index(data.endIndex, offsetBy: -2)] == 0xFF,
              data[data.index(before: data.endIndex)] == 0xD9,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }

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
    let epoch: UInt64
    let task: Task<DecodedThumbnail?, Never>
    var waiterCount: Int
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
    @State private var loadedVideoID: UUID?
    @State private var thumbnailDataChangeRevision: UInt64 = 0

    private var cacheKey: ThumbnailCacheKey? {
        guard let videoID = video.id else { return nil }
        return ThumbnailCacheKey(
            videoID: videoID,
            version: video.thumbnailGenerationVersion,
            generatedAt: video.thumbnailGeneratedAt
        )
    }

    private var taskKey: ThumbnailImageTaskKey? {
        guard let cacheKey else { return nil }
        return ThumbnailImageTaskKey(
            cacheKey: cacheKey,
            dataChangeRevision: thumbnailDataChangeRevision
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
        .task(id: taskKey) {
            // Keep the current image while a refreshed one loads; only a different video clears it.
            if loadedVideoID != cacheKey?.videoID {
                platformImage = nil
            }
            guard let cacheKey, let data = video.thumbnailData else { return }
            var loadedImage = await ThumbnailImageCache.shared.image(for: cacheKey, data: data)
            if loadedImage == nil, !Task.isCancelled {
                // A cache purge hands nil to decodes already in flight; ask once more.
                loadedImage = await ThumbnailImageCache.shared.image(for: cacheKey, data: data)
            }
            guard !Task.isCancelled else { return }
            platformImage = loadedImage
            loadedVideoID = cacheKey.videoID
        }
        .onReceive(video.publisher(for: \Video.thumbnailData, options: [.new])) { _ in
            thumbnailDataChangeRevision &+= 1
        }
    }
}

private final class MemoryPressureObserver {
    #if os(macOS)
    private let source: DispatchSourceMemoryPressure

    init(onPressure: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: onPressure)
        source.resume()
    }

    deinit {
        source.cancel()
    }
    #else
    private var token: NSObjectProtocol?

    init(onPressure: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in onPressure() }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
    #endif
}
