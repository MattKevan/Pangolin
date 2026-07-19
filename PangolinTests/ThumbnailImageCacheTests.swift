import AppKit
import Foundation
import Testing
@testable import Pangolin

struct ThumbnailImageCacheTests {
    @Test("Force regeneration changes the cache key")
    func generatedDateInvalidatesCache() {
        let id = UUID()
        let first = ThumbnailCacheKey(
            videoID: id,
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
        let second = ThumbnailCacheKey(
            videoID: id,
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(first != second)
    }

    @Test("Invalid image bytes return no image")
    func invalidBytesReturnNil() async {
        let cache = ThumbnailImageCache(countLimit: 2, totalCostLimit: 1_024)
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: nil)

        let image = await cache.image(for: key, data: Data("not an image".utf8))

        #expect(image == nil)
    }

    @Test("Exact data changes request identity without probabilistic fingerprints")
    func exactDataInvalidatesRequestIdentity() {
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: Date())
        let first = ThumbnailImageRequestKey(key: key, data: Data([1, 2, 3]))
        let replacement = ThumbnailImageRequestKey(key: key, data: Data([1, 2, 4]))

        #expect(first != replacement)
        #expect(first.data == Data([1, 2, 3]))
    }

    @Test("Event revisions rerun tasks for nil-to-data and replacement changes")
    func dataEventsInvalidateViewTaskIdentity() {
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: Date())
        let initial = ThumbnailImageTaskKey(cacheKey: key, dataChangeRevision: 0)
        let receivedBytes = ThumbnailImageTaskKey(cacheKey: key, dataChangeRevision: 1)
        let replacement = ThumbnailImageTaskKey(cacheKey: key, dataChangeRevision: 2)

        #expect(initial != receivedBytes)
        #expect(receivedBytes != replacement)
    }

    @Test("Replacing data with unchanged metadata decodes the replacement")
    func replacingDataInvalidatesCachedImage() async {
        let probe = DecoderProbe()
        let cache = ThumbnailImageCache(
            countLimit: 2,
            totalCostLimit: 1_024,
            decoder: { data in probe.decode(data) }
        )
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: Date())

        _ = await cache.image(for: key, data: Data([1]))
        _ = await cache.image(for: key, data: Data([2]))

        #expect(probe.callCount == 2)
    }

    @Test("Production decoder retains decoded pixels and reports their cost")
    func productionDecodeHasPixelBackingAndCost() throws {
        let jpeg = try makeJPEG(width: 64, height: 64)

        let decoded = try #require(ThumbnailImageCache.decodeImage(jpeg))
        let cgImage = try #require(decoded.image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ))

        #expect(cgImage.width == 64)
        #expect(cgImage.height == 64)
        #expect(decoded.pixelCost == cgImage.bytesPerRow * cgImage.height)
        #expect(decoded.pixelCost > jpeg.count)
        #expect(ThumbnailImageCache.decodeImage(Data(jpeg.dropLast(2))) == nil)
    }

    @Test("Concurrent requests for one key share a decode")
    func concurrentRequestsCoalesce() async {
        let probe = DecoderProbe(delay: 0.1)
        let cache = ThumbnailImageCache(
            countLimit: 2,
            totalCostLimit: 1_024,
            decoder: { data in probe.decode(data) }
        )
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: Date())
        let data = Data([1, 2, 3])

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await cache.image(for: key, data: data) != nil
                }
            }

            for await result in group {
                #expect(result)
            }
        }

        #expect(probe.callCount == 1)
    }

    @Test("Decoding is dispatched away from the main thread")
    @MainActor
    func decodingRunsOffMain() async {
        let probe = DecoderProbe()
        let cache = ThumbnailImageCache(
            countLimit: 2,
            totalCostLimit: 1_024,
            decoder: { data in probe.decode(data) }
        )
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: nil)

        _ = await cache.image(for: key, data: Data([1]))

        #expect(probe.wasCalledOnMainThread == false)
    }

    @Test("Removing all decoded images forces a fresh decode")
    func removeAllForcesFreshDecode() async {
        let probe = DecoderProbe()
        let cache = ThumbnailImageCache(
            countLimit: 2,
            totalCostLimit: 1_024,
            decoder: { data in probe.decode(data) }
        )
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: nil)
        let data = Data([1])

        _ = await cache.image(for: key, data: data)
        _ = await cache.image(for: key, data: data)
        #expect(probe.callCount == 1)

        await cache.removeAll()
        _ = await cache.image(for: key, data: data)

        #expect(probe.callCount == 2)
    }

    @Test("Purge returns nil to original and coalesced in-flight waiters")
    func purgeDuringDecodeReturnsNilToEveryWaiter() async {
        let probe = DecoderProbe(delay: 0.2)
        let cache = ThumbnailImageCache(
            countLimit: 2,
            totalCostLimit: 1_024,
            decoder: { data in probe.decode(data) }
        )
        let key = ThumbnailCacheKey(videoID: UUID(), version: 1, generatedAt: nil)
        let data = Data([1])

        let firstRequest = Task {
            await cache.image(for: key, data: data)
        }
        while probe.callCount == 0 {
            await Task.yield()
        }
        let coalescedRequest = Task {
            await cache.image(for: key, data: data)
        }
        while await cache.inFlightWaiterCount(for: key, data: data) < 2 {
            await Task.yield()
        }
        await cache.removeAll()
        let firstImage = await firstRequest.value
        let coalescedImage = await coalescedRequest.value

        #expect(firstImage == nil)
        #expect(coalescedImage == nil)
        #expect(probe.callCount == 1)

        _ = await cache.image(for: key, data: data)

        #expect(probe.callCount == 2)
    }
}

private final class DecoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var calls = 0
    private var calledOnMainThread: Bool?

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var wasCalledOnMainThread: Bool? {
        lock.withLock { calledOnMainThread }
    }

    func decode(_ data: Data) -> DecodedThumbnail? {
        lock.withLock {
            calls += 1
            calledOnMainThread = Thread.isMainThread
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return DecodedThumbnail(
            image: NSImage(size: NSSize(width: 1, height: 1)),
            pixelCost: 4
        )
    }
}

private func makeJPEG(width: Int, height: Int) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    guard let data = bitmap.representation(using: .jpeg, properties: [:]) else {
        throw JPEGFixtureError.encodingFailed
    }
    return data
}

private enum JPEGFixtureError: Error {
    case encodingFailed
}
