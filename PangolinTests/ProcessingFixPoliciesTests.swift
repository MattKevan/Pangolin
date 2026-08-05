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
