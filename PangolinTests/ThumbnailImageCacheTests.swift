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

    func decode(_ data: Data) -> PlatformImage? {
        lock.withLock {
            calls += 1
            calledOnMainThread = Thread.isMainThread
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return NSImage(size: NSSize(width: 1, height: 1))
    }
}
