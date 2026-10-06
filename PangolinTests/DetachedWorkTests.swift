import Foundation
import Testing
@testable import Pangolin

struct DetachedWorkTests {
    private actor Flag {
        private(set) var wasCancelled = false
        func markCancelled() { wasCancelled = true }
    }

    @Test("Cancelling the caller cancels the detached work")
    func cancellationReachesDetachedWork() async throws {
        let flag = Flag()
        let started = AsyncStream<Void>.makeStream()

        let caller = Task {
            try await runDetached {
                started.continuation.yield()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                await flag.markCancelled()
                return 1
            }
        }

        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        caller.cancel()
        _ = try? await caller.value

        #expect(await flag.wasCancelled)
    }

    @Test("A result is returned when nothing is cancelled")
    func returnsResult() async throws {
        let value = try await runDetached { 21 * 2 }
        #expect(value == 42)
    }

    @Test("Errors thrown by the work propagate")
    func propagatesErrors() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await runDetached { throw Boom() }
        }
    }
}
