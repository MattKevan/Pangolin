import CoreData
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pangolin

@Suite("Thumbnail coordinator", .serialized)
@MainActor
struct ThumbnailCoordinatorTests {
    @Test("Thumbnail tasks have no queue dependencies")
    func thumbnailTasksHaveNoDependencies() {
        #expect(ProcessingTaskType.generateThumbnail.dependencies.isEmpty)
    }

    @Test("Thumbnail work policy detects missing, stale, corrupt, and forced work")
    func thumbnailWorkPolicy() throws {
        let jpeg = try makeValidJPEG()
        let currentVersion = ThumbnailGenerator.currentVersion

        #expect(ThumbnailWorkPolicy.needsGeneration(data: nil, version: 0, force: false))
        #expect(!ThumbnailWorkPolicy.needsGeneration(data: jpeg, version: currentVersion, force: false))
        #expect(ThumbnailWorkPolicy.needsGeneration(data: jpeg, version: currentVersion, force: true))
        #expect(ThumbnailWorkPolicy.needsGeneration(data: Data("not jpeg".utf8), version: currentVersion, force: false))
        #expect(ThumbnailWorkPolicy.needsGeneration(data: jpeg, version: currentVersion - 1, force: false))
    }

    @Test("Thumbnail stages map to exact monotonic queue updates")
    func thumbnailStagePresentation() {
        let stages: [ThumbnailStage] = [
            .preparing,
            .downloadingVideo,
            .generating,
            .saving,
            .restoringStorage,
        ]
        let updates = stages.map(ThumbnailTaskPresentation.update(for:))

        #expect(updates.map(\.message) == [
            "Preparing thumbnail…",
            "Downloading video for thumbnail…",
            "Generating thumbnail…",
            "Saving thumbnail…",
            "Restoring cloud-only video…",
        ])
        #expect(updates.map(\.progress) == updates.map(\.progress).sorted())
    }

    @Test("Cloud-only optimized video downloads, generates, saves, then restores storage")
    func cloudOnlyOptimizedSequence() async throws {
        let fixture = try makeFixture(storage: .optimizeStorage)
        let jpeg = try makeValidJPEG()
        let generator = FakeThumbnailGenerator(results: [.success(jpeg)])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        var stages: [ThumbnailStage] = []
        let saves = SaveCounter(video: fixture.video)

        try await coordinator.generateThumbnail(for: fixture.video) { stages.append($0) }

        #expect(await generator.callCount == 1)
        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        #expect(access.evictionCount == 1)
        #expect(fixture.video.thumbnailData == jpeg)
        #expect(fixture.video.thumbnailGenerationVersion == ThumbnailGenerator.currentVersion)
        #expect(fixture.video.thumbnailGeneratedAt != nil)
        #expect(saves.count == 1)
        #expect(stages == [.preparing, .downloadingVideo, .generating, .saving, .restoringStorage])
    }

    @Test("Generator failure leaves thumbnail and storage untouched")
    func generatorFailureDoesNotSaveOrEvict() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.failure(FakeError.generation)])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        await #expect(throws: FakeError.self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }

        #expect(access.evictionCount == 0)
        #expect(saves.count == 0)
        #expect(fixture.video.thumbnailData == nil)
        #expect(fixture.video.thumbnailGenerationVersion == 0)
        #expect(fixture.video.thumbnailGeneratedAt == nil)
    }

    @Test("Current thumbnail skips work unless forced")
    func currentThumbnailSkipAndForce() async throws {
        let fixture = try makeFixture()
        let original = try makeValidJPEG(red: 0x11)
        let replacement = try makeValidJPEG(red: 0x88)
        fixture.video.thumbnailData = original
        fixture.video.thumbnailGenerationVersion = ThumbnailGenerator.currentVersion
        fixture.video.thumbnailGeneratedAt = Date(timeIntervalSince1970: 1)
        try fixture.context.save()
        let generator = FakeThumbnailGenerator(results: [.success(replacement)])
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        try await coordinator.generateThumbnail(for: fixture.video)
        #expect(await generator.callCount == 0)
        #expect(access.statusCount == 0)

        try await coordinator.generateThumbnail(for: fixture.video, force: true)
        #expect(await generator.callCount == 1)
        #expect(access.statusCount == 1)
        #expect(fixture.video.thumbnailData == replacement)
    }

    @Test("Keep-all and originally-local videos are never evicted")
    func storagePolicyControlsEviction() async throws {
        let keepAll = try makeFixture(storage: .keepAllDownloaded)
        let keepGenerator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG(red: 0x22))])
        let keepAccess = FakeThumbnailVideoAccess(status: .cloudOnly)
        try await ThumbnailCoordinator(generator: keepGenerator, videoAccess: keepAccess)
            .generateThumbnail(for: keepAll.video)
        #expect(keepAccess.evictionCount == 0)

        let local = try makeFixture(storage: .optimizeStorage)
        let localGenerator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG(red: 0x33))])
        let localAccess = FakeThumbnailVideoAccess(status: .local)
        try await ThumbnailCoordinator(generator: localGenerator, videoAccess: localAccess)
            .generateThumbnail(for: local.video)
        #expect(localAccess.evictionCount == 0)
    }

    @Test("Invalid generated bytes fail without saving or evicting")
    func invalidGeneratedDataFailsImmediately() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(Data("not jpeg".utf8))])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        await #expect(throws: ThumbnailCoordinatorError.self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }

        #expect(saves.count == 0)
        #expect(access.evictionCount == 0)
        #expect(fixture.video.thumbnailData == nil)
    }

    @Test("Missing video identifier fails before accessing the source")
    func missingVideoIDFailsImmediately() async throws {
        let fixture = try makeFixture()
        fixture.video.id = nil
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())])
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        await #expect(throws: ThumbnailCoordinatorError.self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }

        #expect(access.statusCount == 0)
        #expect(access.localURLCount == 0)
        #expect(await generator.callCount == 0)
    }

    @Test("Cancellation during generation cleans up and permits retry")
    func cancellationDuringGeneration() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())], suspendCalls: true)
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        let operation = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await waitUntil { await generator.callCount == 1 }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(saves.count == 0)
        #expect(access.evictionCount == 0)

        await generator.setSuspended(false)
        try await coordinator.generateThumbnail(for: fixture.video)
        #expect(await generator.callCount == 2)
        #expect(saves.count == 1)
    }

    @Test("Cancellation during download cleans up and permits retry")
    func cancellationDuringDownload() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly, suspendLocalURL: true)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        let operation = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await waitUntil { access.localURLCount == 1 }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(saves.count == 0)
        #expect(access.evictionCount == 0)

        access.suspendLocalURL = false
        try await coordinator.generateThumbnail(for: fixture.video)
        #expect(access.localURLCount == 2)
        #expect(saves.count == 1)
    }

    @Test("Simultaneous calls for one video share one operation")
    func simultaneousCallsCoalesce() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())], suspendCalls: true)
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        let first = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await waitUntil { await generator.callCount == 1 }
        let second = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await Task.yield()

        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        #expect(await generator.callCount == 1)
        await generator.releaseSuspendedCalls()
        try await first.value
        try await second.value
        #expect(saves.count == 1)
    }

    @Test("Different videos run serially through the complete lifecycle")
    func differentVideosAreSerialized() async throws {
        let fixture = try makeFixture()
        let secondVideo = try fixture.makeVideo()
        try fixture.context.save()
        let generator = FakeThumbnailGenerator(
            results: [.success(try makeValidJPEG(red: 0x21)), .success(try makeValidJPEG(red: 0x42))],
            suspendCalls: true
        )
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        let first = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await waitUntil { await generator.callCount == 1 }
        let second = Task { try await coordinator.generateThumbnail(for: secondVideo) }
        for _ in 0..<20 { await Task.yield() }

        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        #expect(await generator.callCount == 1)

        await generator.releaseSuspendedCalls()
        try await first.value
        try await second.value
        #expect(access.statusCount == 2)
        #expect(access.localURLCount == 2)
        #expect(await generator.callCount == 2)
    }

    @Test("A canceled queued video never begins source access")
    func canceledQueuedVideoDoesNotStart() async throws {
        let fixture = try makeFixture()
        let queuedVideo = try fixture.makeVideo()
        try fixture.context.save()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())], suspendCalls: true)
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        let first = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await waitUntil { await generator.callCount == 1 }
        let queued = Task { try await coordinator.generateThumbnail(for: queuedVideo) }
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()

        let queuedResult = await promptResult(of: queued) {
            await generator.releaseSuspendedCalls()
        }
        #expect(queuedResult == .canceled)
        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        #expect(await generator.callCount == 1)
        #expect(queuedVideo.thumbnailData == nil)

        await generator.releaseSuspendedCalls()
        try await first.value
        for _ in 0..<20 { await Task.yield() }
        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        #expect(await generator.callCount == 1)
        #expect(queuedVideo.thumbnailData == nil)
    }

    @Test("Canceling one joined caller does not cancel shared work")
    func joinedCallerCancellationIsIsolated() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())], suspendCalls: true)
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        let survivor = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        await waitUntil { await generator.callCount == 1 }
        let canceledJoiner = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        for _ in 0..<20 { await Task.yield() }
        let videoID = try #require(fixture.video.id)
        var waiterCounts = coordinator.debugWaiterCounts(for: videoID)
        #expect(waiterCounts.leases == 2)
        #expect(waiterCounts.observers == 2)
        canceledJoiner.cancel()

        let canceledResult = await promptResult(of: canceledJoiner) {
            await generator.releaseSuspendedCalls()
        }
        #expect(canceledResult == .canceled)
        waiterCounts = coordinator.debugWaiterCounts(for: videoID)
        #expect(waiterCounts.leases == 1)
        #expect(waiterCounts.observers == 1)

        let lateJoiner = Task { try await coordinator.generateThumbnail(for: fixture.video) }
        for _ in 0..<20 { await Task.yield() }
        #expect(await generator.callCount == 1)
        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        waiterCounts = coordinator.debugWaiterCounts(for: videoID)
        #expect(waiterCounts.leases == 2)
        #expect(waiterCounts.observers == 2)

        await generator.releaseSuspendedCalls()
        try await survivor.value
        try await lateJoiner.value
        #expect(await generator.callCount == 1)
        #expect(access.statusCount == 1)
        #expect(access.localURLCount == 1)
        #expect(saves.count == 1)
        #expect(fixture.video.hasCurrentThumbnail)
        waiterCounts = coordinator.debugWaiterCounts(for: videoID)
        #expect(waiterCounts.leases == 0)
        #expect(waiterCounts.observers == 0)
    }

    @Test("Cancellation at storage restoration keeps saved thumbnail and skips eviction")
    func cancellationBeforeEvictionKeepsSavedThumbnail() async throws {
        let fixture = try makeFixture()
        let jpeg = try makeValidJPEG()
        let generator = FakeThumbnailGenerator(results: [.success(jpeg)])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        await #expect(throws: CancellationError.self) {
            try await coordinator.generateThumbnail(for: fixture.video) { stage in
                if stage == .restoringStorage, let videoID = fixture.video.id {
                    coordinator.cancel(videoID: videoID)
                }
            }
        }

        #expect(fixture.video.thumbnailData == jpeg)
        #expect(fixture.video.hasCurrentThumbnail)
        #expect(access.evictionCount == 0)
        let persisted = try freshThumbnailValues(for: fixture.video)
        #expect(persisted.data == jpeg)
    }

    @Test("Transient download errors use the exact retry schedule")
    func transientDownloadErrorsRetryThenSucceed() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())])
        let access = FakeThumbnailVideoAccess(
            status: .cloudOnly,
            localResults: [
                .failure(VideoFileError.cloudContainerUnavailable),
                .failure(VideoFileError.downloadFailed("one")),
                .failure(VideoFileError.downloadFailed("two")),
                .success(URL(fileURLWithPath: "/tmp/video.mov")),
            ]
        )
        let sleep = SleepRecorder()
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access) { delay in
            try await sleep.call(delay)
        }

        try await coordinator.generateThumbnail(for: fixture.video)

        #expect(access.localURLCount == 4)
        #expect(sleep.delays == [5, 15, 45])
        #expect(await generator.callCount == 1)
    }

    @Test("Transient download errors propagate after the final attempt")
    func transientDownloadErrorsEventuallyPropagate() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())])
        let access = FakeThumbnailVideoAccess(
            status: .cloudOnly,
            localResults: Array(repeating: .failure(VideoFileError.downloadFailed("offline")), count: 4)
        )
        let sleep = SleepRecorder()
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access) { delay in
            try await sleep.call(delay)
        }

        do {
            try await coordinator.generateThumbnail(for: fixture.video)
            Issue.record("Expected final download error")
        } catch let error as VideoFileError {
            guard case .downloadFailed = error else {
                Issue.record("Unexpected video file error: \(error)")
                return
            }
        }

        #expect(access.localURLCount == 4)
        #expect(sleep.delays == [5, 15, 45])
        #expect(await generator.callCount == 0)
    }

    @Test("Generator errors are never retried")
    func generatorErrorsAreNotRetried() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.failure(FakeError.generation)])
        let access = FakeThumbnailVideoAccess(status: .local)
        let sleep = SleepRecorder()
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access) { delay in
            try await sleep.call(delay)
        }

        await #expect(throws: FakeError.self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }
        #expect(await generator.callCount == 1)
        #expect(sleep.delays.isEmpty)
    }

    @Test("Non-transient source errors are never retried")
    func nonTransientSourceErrorsAreNotRetried() async throws {
        let fixture = try makeFixture()
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())])
        let access = FakeThumbnailVideoAccess(
            status: .local,
            localResults: [.failure(VideoFileError.invalidVideoPath)]
        )
        let sleep = SleepRecorder()
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access) { delay in
            try await sleep.call(delay)
        }

        await #expect(throws: VideoFileError.self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }

        #expect(access.localURLCount == 1)
        #expect(sleep.delays.isEmpty)
        #expect(await generator.callCount == 0)
    }

    @Test("Eviction failure propagates after the thumbnail has been saved")
    func evictionFailureLeavesSavedThumbnail() async throws {
        let fixture = try makeFixture()
        let jpeg = try makeValidJPEG()
        let generator = FakeThumbnailGenerator(results: [.success(jpeg)])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly, evictionError: FakeError.eviction)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)
        let saves = SaveCounter(video: fixture.video)

        await #expect(throws: FakeError.self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }

        #expect(saves.count == 1)
        #expect(fixture.video.thumbnailData == jpeg)
        #expect(fixture.video.hasCurrentThumbnail)
        #expect(access.evictionCount == 1)
    }

    @Test("New import generates directly from its source URL")
    func newImportUsesProvidedSource() async throws {
        let fixture = try makeFixture()
        let importVideo = try fixture.makeVideo()
        #expect(importVideo.objectID.isTemporaryID)
        let source = URL(fileURLWithPath: "/tmp/import.mov")
        let jpeg = try makeValidJPEG()
        let generator = FakeThumbnailGenerator(results: [.success(jpeg)])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        try await coordinator.generateNewImportThumbnail(for: importVideo, sourceURL: source)

        #expect(await generator.urls == [source])
        #expect(access.statusCount == 0)
        #expect(access.localURLCount == 0)
        #expect(access.evictionCount == 0)
        #expect(importVideo.thumbnailData == jpeg)
        #expect(importVideo.thumbnailGenerationVersion == ThumbnailGenerator.currentVersion)
        #expect(importVideo.thumbnailGeneratedAt != nil)
        #expect(!importVideo.objectID.isTemporaryID)
        #expect(!fixture.context.hasChanges)
    }

    @Test("Existing video thumbnail saves without committing unrelated view-context edits")
    func existingVideoUsesIsolatedPersistence() async throws {
        let fixture = try makeFixture()
        let jpeg = try makeValidJPEG()
        fixture.library.name = "Pending unsaved library name"
        let generator = FakeThumbnailGenerator(results: [.success(jpeg)])
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        try await coordinator.generateThumbnail(for: fixture.video)

        #expect(fixture.library.name == "Pending unsaved library name")
        #expect(fixture.context.hasChanges)
        #expect(fixture.video.thumbnailData == jpeg)
        let persistedVideo = try freshThumbnailValues(for: fixture.video)
        let persistedLibraryName = try freshLibraryName(for: fixture.library)
        #expect(persistedVideo.data == jpeg)
        #expect(persistedVideo.version == ThumbnailGenerator.currentVersion)
        #expect(persistedVideo.generatedAt != nil)
        #expect(persistedLibraryName == "Library")
    }

    @Test("Reconcile skips current thumbnails and continues after failures")
    func reconcileIsBestEffort() async throws {
        let fixture = try makeFixture()
        let current = try fixture.makeVideo()
        current.thumbnailData = try makeValidJPEG(red: 0x11)
        current.thumbnailGenerationVersion = ThumbnailGenerator.currentVersion
        current.thumbnailGeneratedAt = Date()
        let failing = try fixture.makeVideo()
        let succeeding = try fixture.makeVideo()
        try fixture.context.save()
        let generator = FakeThumbnailGenerator(results: [
            .failure(FakeError.generation),
            .success(try makeValidJPEG(red: 0x77)),
        ])
        let access = FakeThumbnailVideoAccess(status: .local)
        let coordinator = ThumbnailCoordinator(generator: generator, videoAccess: access)

        await coordinator.reconcile(videos: [current, failing, succeeding])

        #expect(await generator.callCount == 2)
        #expect(access.localURLCount == 2)
        #expect(failing.thumbnailData == nil)
        #expect(succeeding.hasCurrentThumbnail)
    }

    @Test("Save failure restores only coordinator-owned thumbnail fields")
    func saveFailureRestoresThumbnailFields() async throws {
        let fixture = try makeFixture()
        let oldData = Data("old invalid thumbnail".utf8)
        let oldDate = Date(timeIntervalSince1970: 42)
        fixture.video.thumbnailData = oldData
        fixture.video.thumbnailGenerationVersion = 7
        fixture.video.thumbnailGeneratedAt = oldDate
        fixture.library.name = "Unrelated pending edit"
        let generator = FakeThumbnailGenerator(results: [.success(try makeValidJPEG())])
        let access = FakeThumbnailVideoAccess(status: .cloudOnly)
        let coordinator = ThumbnailCoordinator(
            generator: generator,
            videoAccess: access,
            backgroundContextFactory: { coordinator in
                let context = FailingSaveContext(concurrencyType: .privateQueueConcurrencyType)
                context.persistentStoreCoordinator = coordinator
                context.shouldFail = true
                return context
            }
        )

        await #expect(throws: (any Error).self) {
            try await coordinator.generateThumbnail(for: fixture.video)
        }

        #expect(fixture.video.thumbnailData == oldData)
        #expect(fixture.video.thumbnailGenerationVersion == 7)
        #expect(fixture.video.thumbnailGeneratedAt == oldDate)
        #expect(fixture.library.name == "Unrelated pending edit")
        #expect(access.evictionCount == 0)
    }

    private func makeFixture(storage: LibraryStoragePreference = .optimizeStorage) throws -> Fixture {
        let model = try #require(NSManagedObjectModel.mergedModel(from: [Bundle.main]))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = FailingSaveContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let library = Library(entity: try #require(model.entitiesByName["Library"]), insertInto: context)
        library.id = UUID()
        library.name = "Library"
        library.storagePreference = storage
        let fixture = Fixture(context: context, library: library, videoEntity: try #require(model.entitiesByName["Video"]))
        _ = try fixture.makeVideo()
        try context.save()
        return fixture
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous test condition")
    }

    private func promptResult(
        of task: Task<Void, Error>,
        releaseOnTimeout: @escaping @MainActor () async -> Void
    ) async -> PromptTaskResult {
        let (events, continuation) = AsyncStream.makeStream(of: PromptTaskResult.self)
        let observer = Task {
            do {
                try await task.value
                continuation.yield(.succeeded)
            } catch is CancellationError {
                continuation.yield(.canceled)
            } catch {
                continuation.yield(.failed)
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            continuation.yield(.timedOut)
        }

        var iterator = events.makeAsyncIterator()
        let result = await iterator.next() ?? .failed
        timeout.cancel()
        if result == .timedOut {
            Issue.record("Canceled thumbnail waiter did not resume promptly")
            await releaseOnTimeout()
            _ = await observer.result
        }
        return result
    }

    private func freshThumbnailValues(for video: Video) throws -> (data: Data?, version: Int16, generatedAt: Date?) {
        let context = try freshContext(for: video.managedObjectContext)
        let fetched = try #require(context.existingObject(with: video.objectID) as? Video)
        return (fetched.thumbnailData, fetched.thumbnailGenerationVersion, fetched.thumbnailGeneratedAt)
    }

    private func freshLibraryName(for library: Library) throws -> String? {
        let context = try freshContext(for: library.managedObjectContext)
        let fetched = try #require(context.existingObject(with: library.objectID) as? Library)
        return fetched.name
    }

    private func freshContext(for source: NSManagedObjectContext?) throws -> NSManagedObjectContext {
        let coordinator = try #require(source?.persistentStoreCoordinator)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}

private enum PromptTaskResult: Equatable, Sendable {
    case succeeded
    case canceled
    case failed
    case timedOut
}

@MainActor
private final class Fixture {
    let context: NSManagedObjectContext
    let library: Library
    let videoEntity: NSEntityDescription
    private(set) var videos: [Video] = []
    var video: Video { videos[0] }

    init(context: NSManagedObjectContext, library: Library, videoEntity: NSEntityDescription) {
        self.context = context
        self.library = library
        self.videoEntity = videoEntity
    }

    func makeVideo(id: UUID? = UUID()) throws -> Video {
        let video = Video(entity: videoEntity, insertInto: context)
        video.id = id
        video.title = "Video \(videos.count)"
        video.fileName = "video.mov"
        video.library = library
        videos.append(video)
        return video
    }
}

private actor FakeThumbnailGenerator: ThumbnailGenerating {
    private var results: [Result<Data, Error>]
    private(set) var urls: [URL] = []
    private(set) var callCount = 0
    private var suspendCalls: Bool
    private var continuations: [CheckedContinuation<Void, Error>] = []

    init(results: [Result<Data, Error>], suspendCalls: Bool = false) {
        self.results = results
        self.suspendCalls = suspendCalls
    }

    func generate(from videoURL: URL) async throws -> Data {
        callCount += 1
        urls.append(videoURL)
        if suspendCalls {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    continuations.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelSuspendedCalls() }
            }
        }
        return try results.removeFirst().get()
    }

    func releaseSuspendedCalls() {
        suspendCalls = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func setSuspended(_ suspended: Bool) {
        suspendCalls = suspended
    }

    private func cancelSuspendedCalls() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class FakeThumbnailVideoAccess: ThumbnailVideoAccessing {
    var status: VideoFileStatus
    var localResults: [Result<URL, Error>]
    var suspendLocalURL: Bool
    var evictionError: Error?
    private(set) var statusCount = 0
    private(set) var localURLCount = 0
    private(set) var evictionCount = 0

    init(
        status: VideoFileStatus,
        localResults: [Result<URL, Error>] = [.success(URL(fileURLWithPath: "/tmp/video.mov"))],
        suspendLocalURL: Bool = false,
        evictionError: Error? = nil
    ) {
        self.status = status
        self.localResults = localResults
        self.suspendLocalURL = suspendLocalURL
        self.evictionError = evictionError
    }

    func thumbnailStatus(for video: Video) async -> VideoFileStatus {
        statusCount += 1
        return status
    }

    func thumbnailLocalURL(for video: Video) async throws -> URL {
        localURLCount += 1
        if suspendLocalURL {
            try await Task.sleep(for: .seconds(3_600))
        }
        return try localResults[min(localURLCount - 1, localResults.count - 1)].get()
    }

    func evictThumbnailSource(for video: Video) async throws {
        evictionCount += 1
        if let evictionError { throw evictionError }
    }
}

@MainActor
private final class SleepRecorder {
    private(set) var delays: [TimeInterval] = []

    func call(_ delay: TimeInterval) async throws {
        try Task.checkCancellation()
        delays.append(delay)
    }
}

private final class SaveCounter: @unchecked Sendable {
    private(set) var count = 0
    private var observer: NSObjectProtocol?

    init(video: Video) {
        let objectID = video.objectID
        observer = NotificationCenter.default.addObserver(
            forName: NSManagedObjectContext.didSaveObjectsNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let changedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>,
                  changedObjects.contains(where: { $0.objectID == objectID }) else { return }
            self?.count += 1
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

private final class FailingSaveContext: NSManagedObjectContext, @unchecked Sendable {
    var shouldFail = false

    override func save() throws {
        if shouldFail { throw FakeError.save }
        try super.save()
    }
}

private enum FakeError: Error {
    case generation
    case eviction
    case save
}

private func makeValidJPEG(red: UInt8 = 0x33) throws -> Data {
    let pixelData = Data([red, 0x66, 0x99, 0xFF])
    guard let provider = CGDataProvider(data: pixelData as CFData),
          let image = CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw TestFixtureError.couldNotCreateImage
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw TestFixtureError.couldNotCreateImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TestFixtureError.couldNotCreateImage }
    return data as Data
}

private enum TestFixtureError: Error {
    case couldNotCreateImage
}
