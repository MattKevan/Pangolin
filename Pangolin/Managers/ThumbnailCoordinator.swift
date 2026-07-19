import CoreData
import Foundation

@MainActor
protocol ThumbnailVideoAccessing: AnyObject {
    func thumbnailStatus(for video: Video) async -> VideoFileStatus
    func thumbnailLocalURL(for video: Video) async throws -> URL
    func evictThumbnailSource(for video: Video) async throws
}

extension VideoFileManager: ThumbnailVideoAccessing {
    func thumbnailStatus(for video: Video) async -> VideoFileStatus {
        await isVideoFileAccessible(video)
    }

    func thumbnailLocalURL(for video: Video) async throws -> URL {
        try await getVideoFileURL(for: video, downloadIfNeeded: true)
    }

    func evictThumbnailSource(for video: Video) async throws {
        try await evictLocalCopy(for: video)
    }
}

enum ThumbnailStage: Equatable, Sendable {
    case preparing
    case downloadingVideo
    case generating
    case saving
    case restoringStorage
}

enum ThumbnailCoordinatorError: LocalizedError {
    case missingVideoID
    case invalidGeneratedData
    case missingManagedObjectContext
    case existingVideoNotPersisted
    case thumbnailSaveNotificationMissing

    var errorDescription: String? {
        switch self {
        case .missingVideoID:
            return "The video does not have an identifier, so its thumbnail cannot be generated."
        case .invalidGeneratedData:
            return "The generated thumbnail is not valid JPEG data."
        case .missingManagedObjectContext:
            return "The video is not attached to a library context, so its thumbnail cannot be saved."
        case .existingVideoNotPersisted:
            return "The existing video is not stored persistently, so its thumbnail cannot be saved safely."
        case .thumbnailSaveNotificationMissing:
            return "The thumbnail was saved, but its library update could not be merged."
        }
    }
}

private final class ThumbnailWaiterGroup: @unchecked Sendable {
    typealias Lease = UUID

    private enum LeaseState {
        case active
        case canceled
    }

    private let lock = NSLock()
    private let cancelOperation: @Sendable () -> Void
    private var leases: [Lease: LeaseState] = [:]
    private var activeCount = 0
    private var completionResult: Result<Void, Error>?
    private var completionHandlers: [UUID: @Sendable (Result<Void, Error>) -> Void] = [:]

    init(cancelOperation: @escaping @Sendable () -> Void) {
        self.cancelOperation = cancelOperation
    }

    func acquire() -> Lease {
        lock.lock()
        defer { lock.unlock() }
        let lease = UUID()
        leases[lease] = .active
        activeCount += 1
        return lease
    }

    @discardableResult
    func cancel(_ lease: Lease) -> Bool {
        var shouldCancelOperation = false
        lock.lock()
        if leases[lease] == .active {
            leases[lease] = .canceled
            activeCount -= 1
            shouldCancelOperation = activeCount == 0
        }
        lock.unlock()
        if shouldCancelOperation {
            cancelOperation()
        }
        return shouldCancelOperation
    }

    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        if leases.removeValue(forKey: lease) == .active {
            activeCount -= 1
        }
    }

    func observeCompletion(_ handler: @escaping @Sendable (Result<Void, Error>) -> Void) {
        var completedResult: Result<Void, Error>?
        lock.lock()
        if let completionResult {
            completedResult = completionResult
        } else {
            completionHandlers[UUID()] = handler
        }
        lock.unlock()
        if let completedResult {
            handler(completedResult)
        }
    }

    func complete(with result: Result<Void, Error>) {
        var handlers: [@Sendable (Result<Void, Error>) -> Void] = []
        lock.lock()
        if completionResult == nil {
            completionResult = result
            handlers = Array(completionHandlers.values)
            completionHandlers.removeAll()
        }
        lock.unlock()
        for handler in handlers {
            handler(result)
        }
    }
}

private final class ThumbnailWaiter: @unchecked Sendable {
    private enum State {
        case pending
        case canceled
        case canceling
        case completed(Result<Void, Error>)
    }

    private let lock = NSLock()
    private let waiterGroup: ThumbnailWaiterGroup
    private let lease: ThumbnailWaiterGroup.Lease
    private var state: State = .pending
    private var continuation: CheckedContinuation<Void, Error>?
    private var hasReleasedLease = false

    init(waiterGroup: ThumbnailWaiterGroup) {
        self.waiterGroup = waiterGroup
        lease = waiterGroup.acquire()
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        var continuationToResume: CheckedContinuation<Void, Error>?
        lock.lock()
        if case .pending = state {
            if waiterGroup.cancel(lease) {
                state = .canceling
            } else {
                state = .canceled
                continuationToResume = continuation
                continuation = nil
            }
        }
        lock.unlock()
        continuationToResume?.resume(throwing: CancellationError())
    }

    func complete(with result: Result<Void, Error>) {
        var continuationToResume: CheckedContinuation<Void, Error>?
        var resumeWithCancellation = false
        var shouldReleaseLease = false
        lock.lock()
        if !hasReleasedLease {
            hasReleasedLease = true
            shouldReleaseLease = true
            switch state {
            case .pending:
                state = .completed(result)
                continuationToResume = continuation
                continuation = nil
            case .canceling:
                state = .canceled
                continuationToResume = continuation
                continuation = nil
                resumeWithCancellation = true
            case .canceled, .completed:
                break
            }
        }
        lock.unlock()

        if shouldReleaseLease {
            waiterGroup.release(lease)
            if resumeWithCancellation {
                continuationToResume?.resume(throwing: CancellationError())
            } else {
                continuationToResume?.resume(with: result)
            }
        }
    }

    private func install(_ newContinuation: CheckedContinuation<Void, Error>) {
        var completedResult: Result<Void, Error>?
        var wasCanceled = false
        lock.lock()
        switch state {
        case .pending:
            continuation = newContinuation
        case .canceling:
            continuation = newContinuation
        case .canceled:
            wasCanceled = true
        case let .completed(result):
            completedResult = result
        }
        lock.unlock()

        if wasCanceled {
            newContinuation.resume(throwing: CancellationError())
        } else if let completedResult {
            newContinuation.resume(with: completedResult)
        }
    }
}

private final class ThumbnailCancellationSignal: @unchecked Sendable {
    private enum State {
        case pending
        case completed
        case canceled
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func complete() {
        var continuationToResume: CheckedContinuation<Void, Error>?
        lock.lock()
        if case .pending = state {
            state = .completed
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()
        continuationToResume?.resume()
    }

    private func cancel() {
        var continuationToResume: CheckedContinuation<Void, Error>?
        lock.lock()
        if case .pending = state {
            state = .canceled
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()
        continuationToResume?.resume(throwing: CancellationError())
    }

    private func install(_ newContinuation: CheckedContinuation<Void, Error>) {
        var completed = false
        var canceled = false
        lock.lock()
        switch state {
        case .pending:
            continuation = newContinuation
        case .completed:
            completed = true
        case .canceled:
            canceled = true
        }
        lock.unlock()

        if completed {
            newContinuation.resume()
        } else if canceled {
            newContinuation.resume(throwing: CancellationError())
        }
    }
}

private final class ThumbnailSaveNotificationBox: @unchecked Sendable {
    var notification: Notification?
}

@MainActor
final class ThumbnailCoordinator {
    typealias Sleep = @MainActor @Sendable (TimeInterval) async throws -> Void
    typealias StageHandler = @MainActor (ThumbnailStage) -> Void
    typealias BackgroundContextFactory = @MainActor (NSPersistentStoreCoordinator) -> NSManagedObjectContext

    static let retryDelays: [TimeInterval] = [5, 15, 45]

    private let generator: any ThumbnailGenerating
    private let videoAccess: any ThumbnailVideoAccessing
    private let sleep: Sleep
    private let backgroundContextFactory: BackgroundContextFactory
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var waiterGroups: [UUID: ThumbnailWaiterGroup] = [:]
    private var serialTail: Task<Void, Never>?

    init(
        generator: any ThumbnailGenerating,
        videoAccess: any ThumbnailVideoAccessing,
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        backgroundContextFactory: @escaping BackgroundContextFactory = { coordinator in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            return context
        }
    ) {
        self.generator = generator
        self.videoAccess = videoAccess
        self.sleep = sleep
        self.backgroundContextFactory = backgroundContextFactory
    }

    func generateThumbnail(
        for video: Video,
        force: Bool = false,
        onStage: @escaping StageHandler = { _ in }
    ) async throws {
        if !force, video.hasCurrentThumbnail {
            return
        }
        guard let videoID = video.id else {
            throw ThumbnailCoordinatorError.missingVideoID
        }

        if inFlight[videoID] != nil {
            guard let waiterGroup = waiterGroups[videoID] else {
                throw ThumbnailCoordinatorError.existingVideoNotPersisted
            }
            try await awaitTask(waiterGroup: waiterGroup)
            return
        }

        let generation = UUID()
        let predecessor = serialTail
        let backgroundContextFactory = self.backgroundContextFactory
        let task = Task { @MainActor [generator, videoAccess, sleep] in
            if let predecessor {
                try await Self.waitForPredecessor(predecessor)
            }
            try Task.checkCancellation()
            onStage(.preparing)
            let originalStatus = await videoAccess.thumbnailStatus(for: video)
            onStage(.downloadingVideo)
            let localURL = try await Self.acquireLocalURL(
                for: video,
                videoAccess: videoAccess,
                sleep: sleep
            )
            try Task.checkCancellation()
            onStage(.generating)
            let data = try await generator.generate(from: localURL)
            guard ThumbnailGenerator.isValidJPEG(data) else {
                throw ThumbnailCoordinatorError.invalidGeneratedData
            }
            try Task.checkCancellation()
            onStage(.saving)
            try await Self.saveExisting(
                data,
                for: video,
                backgroundContextFactory: backgroundContextFactory
            )
            try Task.checkCancellation()

            if originalStatus == .cloudOnly,
               video.library?.storagePreference == .optimizeStorage {
                onStage(.restoringStorage)
                try Task.checkCancellation()
                try await videoAccess.evictThumbnailSource(for: video)
            }
        }
        let waiterGroup = ThumbnailWaiterGroup {
            task.cancel()
        }
        inFlight[videoID] = task
        generations[videoID] = generation
        waiterGroups[videoID] = waiterGroup
        serialTail = Task { @MainActor in
            if let predecessor {
                await predecessor.value
            }
            _ = try? await task.value
        }
        Task { @MainActor [weak self] in
            let result = await task.result
            self?.cleanInFlight(videoID: videoID, generation: generation)
            waiterGroup.complete(with: result)
        }
        try await awaitTask(waiterGroup: waiterGroup)
    }

    func generateNewImportThumbnail(for video: Video, sourceURL: URL) async throws {
        let data = try await generator.generate(from: sourceURL)
        guard ThumbnailGenerator.isValidJPEG(data) else {
            throw ThumbnailCoordinatorError.invalidGeneratedData
        }
        try Task.checkCancellation()
        try Self.saveNewImport(data, for: video)
    }

    func reconcile(videos: [Video]) async {
        for video in videos {
            guard !Task.isCancelled else { return }
            do {
                try await generateThumbnail(for: video)
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    func cancel(videoID: UUID) {
        inFlight[videoID]?.cancel()
    }

    private func awaitTask(waiterGroup: ThumbnailWaiterGroup) async throws {
        let waiter = ThumbnailWaiter(waiterGroup: waiterGroup)
        waiterGroup.observeCompletion { result in
            waiter.complete(with: result)
        }
        try await waiter.wait()
        try Task.checkCancellation()
    }

    private func cleanInFlight(videoID: UUID, generation: UUID?) {
        guard generations[videoID] == generation else { return }
        inFlight.removeValue(forKey: videoID)
        generations.removeValue(forKey: videoID)
        waiterGroups.removeValue(forKey: videoID)
    }

    private static func waitForPredecessor(_ predecessor: Task<Void, Never>) async throws {
        let signal = ThumbnailCancellationSignal()
        Task {
            await predecessor.value
            signal.complete()
        }
        try await signal.wait()
        try Task.checkCancellation()
    }

    private static func acquireLocalURL(
        for video: Video,
        videoAccess: any ThumbnailVideoAccessing,
        sleep: Sleep
    ) async throws -> URL {
        for delay in retryDelays {
            do {
                return try await videoAccess.thumbnailLocalURL(for: video)
            } catch {
                if error is CancellationError { throw error }
                guard isTransientDownloadError(error) else { throw error }
                try await sleep(delay)
            }
        }
        return try await videoAccess.thumbnailLocalURL(for: video)
    }

    private static func isTransientDownloadError(_ error: Error) -> Bool {
        guard let videoError = error as? VideoFileError else { return false }
        switch videoError {
        case .cloudContainerUnavailable, .downloadFailed:
            return true
        case .invalidVideoPath, .fileNotFound, .fileNotDownloaded, .uploadFailed, .offloadFailed:
            return false
        }
    }

    private static func saveExisting(
        _ data: Data,
        for video: Video,
        backgroundContextFactory: BackgroundContextFactory
    ) async throws {
        guard let sourceContext = video.managedObjectContext else {
            throw ThumbnailCoordinatorError.missingManagedObjectContext
        }
        guard let coordinator = sourceContext.persistentStoreCoordinator,
              !coordinator.persistentStores.isEmpty,
              !video.objectID.isTemporaryID,
              !video.isInserted,
              !video.isDeleted else {
            throw ThumbnailCoordinatorError.existingVideoNotPersisted
        }

        let objectID = video.objectID
        let generatedAt = Date()
        let backgroundContext = backgroundContextFactory(coordinator)
        let notification = try await backgroundContext.perform {
            guard let backgroundVideo = try backgroundContext.existingObject(with: objectID) as? Video else {
                throw ThumbnailCoordinatorError.existingVideoNotPersisted
            }
            let notificationBox = ThumbnailSaveNotificationBox()
            let observer = NotificationCenter.default.addObserver(
                forName: NSManagedObjectContext.didSaveObjectsNotification,
                object: backgroundContext,
                queue: nil
            ) { notification in
                notificationBox.notification = notification
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            backgroundVideo.thumbnailData = data
            backgroundVideo.thumbnailGenerationVersion = ThumbnailGenerator.currentVersion
            backgroundVideo.thumbnailGeneratedAt = generatedAt
            try backgroundContext.save()
            guard let notification = notificationBox.notification else {
                throw ThumbnailCoordinatorError.thumbnailSaveNotificationMissing
            }
            return notification
        }

        sourceContext.mergeChanges(fromContextDidSave: notification)
    }

    private static func saveNewImport(_ data: Data, for video: Video) throws {
        guard let context = video.managedObjectContext else {
            throw ThumbnailCoordinatorError.missingManagedObjectContext
        }

        let previousData = video.thumbnailData
        let previousVersion = video.thumbnailGenerationVersion
        let previousDate = video.thumbnailGeneratedAt
        video.thumbnailData = data
        video.thumbnailGenerationVersion = ThumbnailGenerator.currentVersion
        video.thumbnailGeneratedAt = Date()

        do {
            try context.save()
        } catch {
            video.thumbnailData = previousData
            video.thumbnailGenerationVersion = previousVersion
            video.thumbnailGeneratedAt = previousDate
            throw error
        }
    }
}
