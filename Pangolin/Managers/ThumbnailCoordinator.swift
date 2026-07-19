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

    var errorDescription: String? {
        switch self {
        case .missingVideoID:
            return "The video does not have an identifier, so its thumbnail cannot be generated."
        case .invalidGeneratedData:
            return "The generated thumbnail is not valid JPEG data."
        case .missingManagedObjectContext:
            return "The video is not attached to a library context, so its thumbnail cannot be saved."
        }
    }
}

@MainActor
final class ThumbnailCoordinator {
    typealias Sleep = @MainActor @Sendable (TimeInterval) async throws -> Void
    typealias StageHandler = @MainActor (ThumbnailStage) -> Void

    static let retryDelays: [TimeInterval] = [5, 15, 45]

    private let generator: any ThumbnailGenerating
    private let videoAccess: any ThumbnailVideoAccessing
    private let sleep: Sleep
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    private var generations: [UUID: UUID] = [:]

    init(
        generator: any ThumbnailGenerating,
        videoAccess: any ThumbnailVideoAccessing,
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.generator = generator
        self.videoAccess = videoAccess
        self.sleep = sleep
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

        if let task = inFlight[videoID] {
            try await awaitTask(task, videoID: videoID, generation: generations[videoID])
            return
        }

        let generation = UUID()
        let task = Task { @MainActor [generator, videoAccess, sleep] in
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
            try Self.save(data, for: video)

            if originalStatus == .cloudOnly,
               video.library?.storagePreference == .optimizeStorage {
                onStage(.restoringStorage)
                try await videoAccess.evictThumbnailSource(for: video)
            }
        }
        inFlight[videoID] = task
        generations[videoID] = generation
        try await awaitTask(task, videoID: videoID, generation: generation)
    }

    func generateNewImportThumbnail(for video: Video, sourceURL: URL) async throws {
        let data = try await generator.generate(from: sourceURL)
        guard ThumbnailGenerator.isValidJPEG(data) else {
            throw ThumbnailCoordinatorError.invalidGeneratedData
        }
        try Task.checkCancellation()
        try Self.save(data, for: video)
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

    private func awaitTask(
        _ task: Task<Void, Error>,
        videoID: UUID,
        generation: UUID?
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.generations[videoID] == generation else { return }
                    self?.inFlight[videoID]?.cancel()
                }
            }
            cleanInFlight(videoID: videoID, generation: generation)
        } catch {
            cleanInFlight(videoID: videoID, generation: generation)
            throw error
        }
    }

    private func cleanInFlight(videoID: UUID, generation: UUID?) {
        guard generations[videoID] == generation else { return }
        inFlight.removeValue(forKey: videoID)
        generations.removeValue(forKey: videoID)
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

    private static func save(_ data: Data, for video: Video) throws {
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
