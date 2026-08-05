import Foundation
import Testing
@testable import Pangolin

// MARK: - VideoDownloadSessionPolicy
//
// Guards the H1 fix: `cancelDownload(for:)` must orphan any in-flight iCloud
// polling loop so it stops instead of re-publishing progress or timing out.

struct VideoDownloadSessionPolicyTests {
    @Test("begin starts a fresh generation")
    func beginStartsFreshGeneration() {
        #expect(VideoDownloadSessionPolicy.begin(storedGeneration: nil) == 1)
        #expect(VideoDownloadSessionPolicy.begin(storedGeneration: 3) == 4)
    }

    @Test("isCurrent only matches the stored generation")
    func isCurrentMatchesStoredGeneration() {
        #expect(VideoDownloadSessionPolicy.isCurrent(generation: 2, storedGeneration: 2))
        #expect(!VideoDownloadSessionPolicy.isCurrent(generation: 2, storedGeneration: 3))
        #expect(!VideoDownloadSessionPolicy.isCurrent(generation: 2, storedGeneration: nil))
    }

    @Test("invalidate orphans any in-flight session")
    func invalidateOrphansInFlightSession() {
        let generation = VideoDownloadSessionPolicy.begin(storedGeneration: nil)
        let bumped = VideoDownloadSessionPolicy.invalidate(generation)
        #expect(!VideoDownloadSessionPolicy.isCurrent(generation: generation, storedGeneration: bumped))
    }

    @Test("complete only clears the stored generation for the current session")
    func completeClearsOnlyCurrentSession() {
        let generation = VideoDownloadSessionPolicy.begin(storedGeneration: nil)
        #expect(VideoDownloadSessionPolicy.complete(generation: generation, storedGeneration: generation) == nil)
        // A stale completion must not clear a newer session's generation.
        let newer = VideoDownloadSessionPolicy.begin(storedGeneration: generation)
        #expect(VideoDownloadSessionPolicy.complete(generation: generation, storedGeneration: newer) == newer)
    }
}

// MARK: - ImportLibraryResolution
//
// Guards the H2 fix: an import task queued for a library that is no longer open
// must fail instead of importing its files into the currently-open library.

struct ImportLibraryResolutionTests {
    @Test("resolves nil task library to the current library")
    func nilTaskLibraryFallsBackToCurrent() {
        let current = UUID()
        #expect(ImportLibraryResolution.resolve(taskLibraryID: nil, currentLibraryID: current) == current)
    }

    @Test("resolves matching task library to that library")
    func matchingTaskLibraryResolves() {
        let current = UUID()
        #expect(ImportLibraryResolution.resolve(taskLibraryID: current, currentLibraryID: current) == current)
    }

    @Test("rejects a task queued for a different library")
    func differentTaskLibraryIsRejected() {
        let current = UUID()
        let other = UUID()
        #expect(ImportLibraryResolution.resolve(taskLibraryID: other, currentLibraryID: current) == nil)
    }

    @Test("requires an open library")
    func requiresOpenLibrary() {
        #expect(ImportLibraryResolution.resolve(taskLibraryID: nil, currentLibraryID: nil) == nil)
        #expect(ImportLibraryResolution.resolve(taskLibraryID: UUID(), currentLibraryID: nil) == nil)
    }
}

// MARK: - TranscriptionFlowClaimPolicy
//
// Guards the C1 fix: transcribe/translate/summarize/flashcards claim a single
// active flow atomically so they can never run concurrently and clobber each
// other's state.

struct TranscriptionFlowClaimPolicyTests {
    @Test("can claim when no flow is active")
    func canClaimWhenIdle() {
        #expect(TranscriptionFlowClaimPolicy.canClaim(activeFlow: nil))
    }

    @Test("cannot claim while another flow is active")
    func cannotClaimWhileActive() {
        #expect(!TranscriptionFlowClaimPolicy.canClaim(activeFlow: .transcription))
        #expect(!TranscriptionFlowClaimPolicy.canClaim(activeFlow: .summarization))
        #expect(!TranscriptionFlowClaimPolicy.canClaim(activeFlow: .flashcards))
    }

    @Test("release clears only the owning flow")
    func releaseClearsOnlyOwner() {
        #expect(TranscriptionFlowClaimPolicy.release(activeFlow: .transcription, for: .transcription) == nil)
        // A stale release from another flow must never clear the active flow.
        #expect(TranscriptionFlowClaimPolicy.release(activeFlow: .transcription, for: .flashcards) == .transcription)
        #expect(TranscriptionFlowClaimPolicy.release(activeFlow: nil, for: .translation) == nil)
    }
}

// MARK: - ProjectGridFocusPolicy
//
// Guards arrow-key navigation across the projects grid: index arithmetic
// with clamping at the edges and the partial last row.

struct ProjectGridFocusPolicyTests {
    @Test("returns nil for an empty grid or an out-of-range index")
    func invalidInputsReturnNil() {
        #expect(ProjectGridFocusPolicy.nextIndex(from: 0, columnCount: 3, itemCount: 0, direction: .right) == nil)
        #expect(ProjectGridFocusPolicy.nextIndex(from: -1, columnCount: 3, itemCount: 4, direction: .right) == nil)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 4, columnCount: 3, itemCount: 4, direction: .right) == nil)
    }

    @Test("horizontal movement clamps at the grid edges")
    func horizontalClampsAtEdges() {
        // 4 items in 3 columns -> rows [0,1,2], [3]
        #expect(ProjectGridFocusPolicy.nextIndex(from: 0, columnCount: 3, itemCount: 4, direction: .left) == 0)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 0, columnCount: 3, itemCount: 4, direction: .right) == 1)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 2, columnCount: 3, itemCount: 4, direction: .right) == 3)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 3, columnCount: 3, itemCount: 4, direction: .right) == 3)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 3, columnCount: 3, itemCount: 4, direction: .left) == 2)
    }

    @Test("vertical movement steps by the column count and clamps")
    func verticalStepsByColumnCount() {
        // 7 items in 3 columns -> rows [0,1,2], [3,4,5], [6]
        #expect(ProjectGridFocusPolicy.nextIndex(from: 1, columnCount: 3, itemCount: 7, direction: .down) == 4)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 4, columnCount: 3, itemCount: 7, direction: .up) == 1)
        // From the first row, up clamps to the start.
        #expect(ProjectGridFocusPolicy.nextIndex(from: 2, columnCount: 3, itemCount: 7, direction: .up) == 0)
        // From the partial last row, down clamps to the last item.
        #expect(ProjectGridFocusPolicy.nextIndex(from: 6, columnCount: 3, itemCount: 7, direction: .down) == 6)
    }

    @Test("single-column grid moves one row per press")
    func singleColumnStepsByOne() {
        #expect(ProjectGridFocusPolicy.nextIndex(from: 2, columnCount: 1, itemCount: 5, direction: .down) == 3)
        #expect(ProjectGridFocusPolicy.nextIndex(from: 2, columnCount: 1, itemCount: 5, direction: .up) == 1)
    }
}

// MARK: - Transfer snapshot resolution
//
// Guards the shared fallback chain that rows use to display cloud transfer
// status (previously duplicated in VideoResultsTableView and FolderOutlineRow).

struct TransferSnapshotResolutionTests {
    private func snapshot(state: VideoCloudTransferState, id: UUID = UUID()) -> VideoCloudTransferSnapshot {
        VideoCloudTransferSnapshot(videoID: id, videoTitle: "Video", state: state, updatedAt: Date())
    }

    @Test("cached snapshot wins over all other sources")
    func cachedSnapshotWins() {
        let cached = snapshot(state: .downloading(progress: 0.5))
        let result = VideoFileManager.resolvedSnapshot(
            cached: cached,
            managerSnapshot: snapshot(state: .downloaded),
            fileAvailabilityState: VideoFileStatus.error.rawValue,
            cloudRelativePath: "x.mp4",
            videoID: UUID(),
            videoTitle: "Video"
        )
        #expect(result == cached)
    }

    @Test("manager snapshot wins over stored video state")
    func managerSnapshotWins() {
        let manager = snapshot(state: .uploading(progress: 0.2))
        let result = VideoFileManager.resolvedSnapshot(
            cached: nil,
            managerSnapshot: manager,
            fileAvailabilityState: VideoFileStatus.cloudOnly.rawValue,
            cloudRelativePath: nil,
            videoID: UUID(),
            videoTitle: "Video"
        )
        #expect(result == manager)
    }

    @Test("stored file state maps to transfer states")
    func storedStateMapsToTransferState() {
        func resolve(_ raw: String) -> VideoCloudTransferState {
            VideoFileManager.resolvedSnapshot(
                cached: nil,
                managerSnapshot: nil,
                fileAvailabilityState: raw,
                cloudRelativePath: nil,
                videoID: UUID(),
                videoTitle: "Video"
            ).state
        }
        #expect(resolve(VideoFileStatus.local.rawValue) == .downloaded)
        #expect(resolve(VideoFileStatus.cloudOnly.rawValue) == .inCloudOnly)
        #expect(resolve(VideoFileStatus.missing.rawValue) == .inCloudOnly)
        guard case .downloading = resolve(VideoFileStatus.downloading.rawValue) else {
            Issue.record("downloading state should map to .downloading")
            return
        }
        guard case .error = resolve(VideoFileStatus.error.rawValue) else {
            Issue.record("error state should map to .error")
            return
        }
    }

    @Test("cloud relative path implies in-cloud-only when no state is stored")
    func cloudPathImpliesInCloudOnly() {
        let result = VideoFileManager.resolvedSnapshot(
            cached: nil,
            managerSnapshot: nil,
            fileAvailabilityState: nil,
            cloudRelativePath: "folder/video.mp4",
            videoID: UUID(),
            videoTitle: "Video"
        )
        #expect(result.state == .inCloudOnly)
    }

    @Test("no signal resolves to the placeholder")
    func emptyResolvesToPlaceholder() {
        let result = VideoFileManager.resolvedSnapshot(
            cached: nil,
            managerSnapshot: nil,
            fileAvailabilityState: nil,
            cloudRelativePath: nil,
            videoID: UUID(),
            videoTitle: "Video"
        )
        #expect(result.videoTitle == "Video")
        #expect(result.state == .downloaded)
    }
}

struct TransferNotificationMatchingTests {
    @Test("matches the targeted video and rejects others")
    func matchesTargetedVideoOnly() {
        let videoID = UUID()
        let otherID = UUID()
        let notification = Notification(
            name: .videoStorageAvailabilityChanged,
            userInfo: [VideoStorageChangeKey.videoID: videoID]
        )
        #expect(VideoFileManager.transferNotification(notification, matches: videoID))
        #expect(!VideoFileManager.transferNotification(notification, matches: otherID))
        #expect(!VideoFileManager.transferNotification(notification, matches: nil))
    }

    @Test("rejects notifications without a valid video id payload")
    func rejectsMissingPayload() {
        let bare = Notification(name: .videoStorageAvailabilityChanged, userInfo: nil)
        let wrongType = Notification(name: .videoStorageAvailabilityChanged, userInfo: [VideoStorageChangeKey.videoID: "not-a-uuid"])
        #expect(!VideoFileManager.transferNotification(bare, matches: UUID()))
        #expect(!VideoFileManager.transferNotification(wrongType, matches: UUID()))
    }
}
