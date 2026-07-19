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

enum ThumbnailWorkPolicy {
    static func needsGeneration(data: Data?, version: Int16, force: Bool) -> Bool {
        if force { return true }
        guard version == ThumbnailGenerator.currentVersion,
              let data else { return true }
        return !ThumbnailValidityCache.shared.isValidJPEG(data)
    }
}

enum ThumbnailTaskEnqueueAction: Equatable {
    case enqueue
    case coalesce
    case replace
}

enum ThumbnailTaskEnqueuePolicy {
    static func action(
        existingStatus: ProcessingTaskStatus?,
        force: Bool
    ) -> ThumbnailTaskEnqueueAction {
        guard let existingStatus else { return .enqueue }
        if force { return .replace }
        return existingStatus.isActive ? .coalesce : .replace
    }
}

enum ThumbnailTaskScope {
    static func canRun(taskLibraryID: UUID?, currentLibraryID: UUID?) -> Bool {
        guard let taskLibraryID else { return true }
        return taskLibraryID == currentLibraryID
    }
}

struct ThumbnailReconciliationGate {
    private struct ImportScope: Equatable {
        let sourceID: UUID
        var libraryID: UUID?
    }

    private var activeImportScopes: [UUID: ImportScope] = [:]
    private var pendingLibraryIDs: [UUID] = []

    mutating func eventStarted(id: UUID, sourceID: UUID, isImport: Bool, libraryID: UUID?) {
        if isImport {
            activeImportScopes[id] = ImportScope(sourceID: sourceID, libraryID: libraryID)
        }
    }

    mutating func bindUnscopedImports(from sourceID: UUID, to libraryID: UUID) {
        for (eventID, scope) in activeImportScopes
            where scope.sourceID == sourceID && scope.libraryID == nil {
            activeImportScopes[eventID]?.libraryID = libraryID
        }
    }

    mutating func eventCompleted(
        id: UUID,
        sourceID: UUID,
        isImport: Bool,
        succeeded: Bool,
        libraryID: UUID?
    ) -> UUID? {
        guard isImport,
              activeImportScopes[id]?.sourceID == sourceID,
              let scope = activeImportScopes.removeValue(forKey: id) else { return nil }
        if succeeded,
           let capturedLibraryID = scope.libraryID,
           capturedLibraryID == libraryID {
            appendPending(capturedLibraryID)
        }
        return flushNextReady()
    }

    mutating func request(libraryID: UUID) -> UUID? {
        appendPending(libraryID)
        return flushNextReady()
    }

    mutating func abandon(sourceID: UUID) -> UUID? {
        activeImportScopes = activeImportScopes.filter { $0.value.sourceID != sourceID }
        return flushNextReady()
    }

    mutating func abandon(libraryID: UUID) -> UUID? {
        activeImportScopes = activeImportScopes.filter { $0.value.libraryID != libraryID }
        pendingLibraryIDs.removeAll { $0 == libraryID }
        return flushNextReady()
    }

    private mutating func appendPending(_ libraryID: UUID) {
        if !pendingLibraryIDs.contains(libraryID) {
            pendingLibraryIDs.append(libraryID)
        }
    }

    private mutating func flushNextReady() -> UUID? {
        guard let index = pendingLibraryIDs.firstIndex(where: { libraryID in
            !activeImportScopes.values.contains(where: { $0.libraryID == libraryID })
        }) else { return nil }
        return pendingLibraryIDs.remove(at: index)
    }
}

struct CloudEventSourceLifecycle {
    private var closedSourceIDs: Set<UUID> = []

    mutating func abandon(_ sourceID: UUID) {
        closedSourceIDs.insert(sourceID)
    }

    mutating func activate(_ sourceID: UUID) {
        closedSourceIDs.remove(sourceID)
    }

    func accepts(_ sourceID: UUID) -> Bool {
        !closedSourceIDs.contains(sourceID)
    }
}

struct ThumbnailLibraryLifecycle {
    private(set) var closingLibraryIDs: Set<UUID> = []

    mutating func beginClosing(_ libraryID: UUID) {
        closingLibraryIDs.insert(libraryID)
    }

    mutating func activate(_ libraryID: UUID) {
        closingLibraryIDs.remove(libraryID)
    }

    func allowsWork(for libraryID: UUID) -> Bool {
        !closingLibraryIDs.contains(libraryID)
    }
}

struct ThumbnailReconciliationScanner {
    func videoIDsNeedingGeneration(
        libraryID: UUID,
        persistentStoreCoordinator: NSPersistentStoreCoordinator
    ) async throws -> [UUID] {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = persistentStoreCoordinator
        return try await context.perform {
            try Task.checkCancellation()
            let request = Video.fetchRequest()
            request.predicate = NSPredicate(format: "library.id == %@", libraryID as CVarArg)
            var videoIDs: [UUID] = []
            for video in try context.fetch(request) {
                try Task.checkCancellation()
                if ThumbnailWorkPolicy.needsGeneration(
                    data: video.thumbnailData,
                    version: video.thumbnailGenerationVersion,
                    force: false
                ), let videoID = video.id {
                    videoIDs.append(videoID)
                }
            }
            return videoIDs
        }
    }
}

struct ThumbnailTaskPresentation: Equatable {
    let progress: Double
    let message: String

    static func update(for stage: ThumbnailStage) -> ThumbnailTaskPresentation {
        switch stage {
        case .preparing:
            return ThumbnailTaskPresentation(progress: 0.05, message: "Preparing thumbnail…")
        case .downloadingVideo:
            return ThumbnailTaskPresentation(progress: 0.20, message: "Downloading video for thumbnail…")
        case .generating:
            return ThumbnailTaskPresentation(progress: 0.45, message: "Generating thumbnail…")
        case .saving:
            return ThumbnailTaskPresentation(progress: 0.75, message: "Saving thumbnail…")
        case .restoringStorage:
            return ThumbnailTaskPresentation(progress: 0.90, message: "Restoring cloud-only video…")
        }
    }
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
    private let operationCancellation: @Sendable () -> Void
    private var leases: [Lease: LeaseState] = [:]
    private var activeCount = 0
    private var completionResult: Result<Void, Error>?
    private var completionHandlers: [UUID: @Sendable (Result<Void, Error>) -> Void] = [:]

    init(cancelOperation: @escaping @Sendable () -> Void) {
        operationCancellation = cancelOperation
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
    func cancel(
        _ lease: Lease,
        removingCompletionHandler completionToken: UUID
    ) -> Bool {
        var shouldCancelOperation = false
        lock.lock()
        if leases[lease] == .active {
            if activeCount == 1 {
                leases[lease] = .canceled
                activeCount = 0
                shouldCancelOperation = true
            } else {
                leases.removeValue(forKey: lease)
                activeCount -= 1
                completionHandlers.removeValue(forKey: completionToken)
            }
        }
        lock.unlock()
        return shouldCancelOperation
    }

    func cancelOperation() {
        operationCancellation()
    }

    func release(_ lease: Lease) {
        lock.lock()
        defer { lock.unlock() }
        if leases.removeValue(forKey: lease) == .active {
            activeCount -= 1
        }
    }

    func observeCompletion(
        token: UUID,
        _ handler: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        var completedResult: Result<Void, Error>?
        lock.lock()
        if let completionResult {
            completedResult = completionResult
        } else {
            completionHandlers[token] = handler
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

    #if DEBUG
    var debugCounts: (leases: Int, observers: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (leases.count, completionHandlers.count)
    }
    #endif
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
    private let completionToken = UUID()
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

    func observeCompletion() {
        waiterGroup.observeCompletion(token: completionToken) { [self] result in
            complete(with: result)
        }
    }

    func cancel() {
        var continuationToResume: CheckedContinuation<Void, Error>?
        var shouldCancelOperation = false
        lock.lock()
        if case .pending = state {
            if waiterGroup.cancel(lease, removingCompletionHandler: completionToken) {
                state = .canceling
                shouldCancelOperation = true
            } else {
                state = .canceled
                hasReleasedLease = true
                continuationToResume = continuation
                continuation = nil
            }
        }
        lock.unlock()
        if shouldCancelOperation {
            waiterGroup.cancelOperation()
        }
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
    static let shared = ThumbnailCoordinator(
        generator: ThumbnailGenerator(),
        videoAccess: VideoFileManager.shared
    )

    private let generator: any ThumbnailGenerating
    private let videoAccess: any ThumbnailVideoAccessing
    private let sleep: Sleep
    private let backgroundContextFactory: BackgroundContextFactory
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    private struct OperationIdentity {
        let generation: UUID
        let libraryID: UUID?
    }

    private var operationIdentities: [UUID: OperationIdentity] = [:]
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
        if !ThumbnailWorkPolicy.needsGeneration(
            data: video.thumbnailData,
            version: video.thumbnailGenerationVersion,
            force: force
        ) {
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
        operationIdentities[videoID] = OperationIdentity(
            generation: generation,
            libraryID: video.library?.id
        )
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

    func cancelAndWait(videoID: UUID) async {
        guard let task = inFlight[videoID],
              let identity = operationIdentities[videoID] else { return }
        task.cancel()
        _ = await task.result
        cleanInFlight(videoID: videoID, generation: identity.generation)
    }

    func hasOperation(videoID: UUID) -> Bool {
        inFlight[videoID] != nil
    }

    func activeVideoIDs(for libraryID: UUID) -> Set<UUID> {
        Set(operationIdentities.compactMap { videoID, identity in
            identity.libraryID == libraryID ? videoID : nil
        })
    }

    func cancelAndWaitAll(for libraryID: UUID) async {
        let videoIDs = activeVideoIDs(for: libraryID)
        for videoID in videoIDs {
            await cancelAndWait(videoID: videoID)
        }
    }

    #if DEBUG
    func debugWaiterCounts(for videoID: UUID) -> (leases: Int, observers: Int) {
        waiterGroups[videoID]?.debugCounts ?? (0, 0)
    }
    #endif

    private func awaitTask(waiterGroup: ThumbnailWaiterGroup) async throws {
        let waiter = ThumbnailWaiter(waiterGroup: waiterGroup)
        waiter.observeCompletion()
        try await waiter.wait()
        try Task.checkCancellation()
    }

    private func cleanInFlight(videoID: UUID, generation: UUID?) {
        guard operationIdentities[videoID]?.generation == generation else { return }
        inFlight.removeValue(forKey: videoID)
        operationIdentities.removeValue(forKey: videoID)
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
