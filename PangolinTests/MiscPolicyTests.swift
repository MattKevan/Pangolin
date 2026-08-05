import Testing
import Foundation
import Combine
import SwiftUI
import AVFoundation
@testable import Pangolin


@Suite("Phone video route selection reconciliation policy")
struct PhoneVideoRouteSelectionReconciliationPolicyTests {
    @Test("Store-driven nil selection removes an existing video route")
    func nilSelectionRemovesRoute() {
        #expect(PhoneVideoRouteSelectionReconciliationPolicy.action(
            existingVideoRouteIDs: [UUID()],
            selectedVideoID: nil,
            isSwitchingTabs: false
        ) == .removeVideoRoutes)
    }

    @Test("A nonnil Previous or Next selection keeps route synchronization active")
    func nonnilSelectionKeepsRoute() {
        #expect(PhoneVideoRouteSelectionReconciliationPolicy.action(
            existingVideoRouteIDs: [UUID()],
            selectedVideoID: UUID(),
            isSwitchingTabs: false
        ) == .none)
    }

    @Test("Tab-switch abandonment is not treated as external deselection")
    func tabSwitchDoesNotRestoreOrigin() {
        #expect(PhoneVideoRouteSelectionReconciliationPolicy.action(
            existingVideoRouteIDs: [UUID()],
            selectedVideoID: nil,
            isSwitchingTabs: true
        ) == .none)
    }
}


@Suite("Search video selection reset policy")
struct SearchVideoSelectionResetPolicyTests {
    @Test("Store deselection clears the selected search row")
    func nilVideoClearsSelection() {
        #expect(SearchVideoSelectionResetPolicy.shouldClearRowSelection(
            selectedVideoID: nil
        ))
    }

    @Test("Previous or Next selection retains the selected search row")
    func selectedVideoRetainsSelection() {
        #expect(!SearchVideoSelectionResetPolicy.shouldClearRowSelection(
            selectedVideoID: UUID()
        ))
    }
}


@Suite("Video toolbar policy")
struct VideoToolbarPolicyTests {
    @Test("Regular workspace uses the native sidebar navigation")
    func regularWorkspaceUsesNativeSidebarNavigation() {
        #expect(VideoToolbarPolicy.ownership(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: true
        ) == .systemOwned)
        #expect(!VideoToolbarPolicy.removesSystemSidebarButton(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: true
        ))
        #expect(!VideoToolbarPolicy.showsSidebarButton(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: true
        ))
    }

    @Test("Compact workspace retains native ordinary split navigation")
    func compactWorkspaceUsesSystemSidebarNavigation() {
        #expect(VideoToolbarPolicy.ownership(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: false
        ) == .systemOwned)
        #expect(!VideoToolbarPolicy.removesSystemSidebarButton(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: false
        ))
        #expect(!VideoToolbarPolicy.showsSidebarButton(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: false
        ))
    }

    @Test("Every workspace video detail replaces split navigation with store-aware Back")
    func everyWorkspaceVideoDetailUsesAppOwnedBack() {
        for supportsAppOwnedSidebarButton in [false, true] {
            #expect(VideoToolbarPolicy.ownership(
                shell: .workspace,
                isVideoDetail: true,
                supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
            ) == .appOwned)
            #expect(VideoToolbarPolicy.removesSystemSidebarButton(
                shell: .workspace,
                isVideoDetail: true,
                supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
            ))
            #expect(!VideoToolbarPolicy.showsSidebarButton(
                shell: .workspace,
                isVideoDetail: true,
                supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
            ))
            #expect(VideoToolbarPolicy.showsVideoBackButton(
                shell: .workspace,
                isVideoDetail: true,
                supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
            ))
        }
    }

    @Test("Phone navigation remains native")
    func phoneUsesNativeNavigation() {
        #expect(VideoToolbarPolicy.ownership(
            shell: .phone,
            isVideoDetail: true,
            supportsAppOwnedSidebarButton: true
        ) == .none)
        #expect(!VideoToolbarPolicy.removesSystemSidebarButton(
            shell: .phone,
            isVideoDetail: true,
            supportsAppOwnedSidebarButton: true
        ))
        #expect(!VideoToolbarPolicy.showsSidebarButton(
            shell: .phone,
            isVideoDetail: true,
            supportsAppOwnedSidebarButton: true
        ))
        #expect(!VideoToolbarPolicy.showsVideoBackButton(
            shell: .phone,
            isVideoDetail: true,
            supportsAppOwnedSidebarButton: true
        ))
    }

    @Test("Sidebar toggle reopens detail-only and collapses every other visible state")
    func sidebarVisibilityToggleTransitions() {
        #expect(WorkspaceSidebarVisibilityPolicy.toggled(from: .detailOnly) == .all)
        #expect(WorkspaceSidebarVisibilityPolicy.toggled(from: .all) == .detailOnly)
        #expect(WorkspaceSidebarVisibilityPolicy.toggled(from: .automatic) == .detailOnly)
    }
}


@Suite("Import duplicate policy")
struct ImportDuplicatePolicyTests {
    @Test("Skips matching source paths and matching filename-size pairs")
    func skipsKnownDuplicates() {
        let sourceMatch = URL(fileURLWithPath: "/Volumes/Archive/lesson.mp4")
        let sizeMatch = URL(fileURLWithPath: "/Volumes/Backup/lesson.mp4")
        let distinctFile = URL(fileURLWithPath: "/Volumes/Backup/lesson-copy.mp4")

        let candidates = [
            ImportCandidate(url: sourceMatch, fileName: "lesson.mp4", fileSize: 100),
            ImportCandidate(url: sizeMatch, fileName: "lesson.mp4", fileSize: 100),
            ImportCandidate(url: distinctFile, fileName: "lesson-copy.mp4", fileSize: 100),
        ]
        let existing = [
            ImportedVideoRecord(sourcePath: sourceMatch.path, fileName: "different-name.mp4", fileSize: 1),
            ImportedVideoRecord(sourcePath: nil, fileName: "lesson.mp4", fileSize: 100),
        ]

        #expect(ImportDuplicatePolicy.uniqueCandidates(candidates, existingRecords: existing) == [candidates[2]])
    }

    @Test("Keeps same-name files when their sizes differ")
    func retainsDifferentSizedFiles() {
        let candidate = ImportCandidate(
            url: URL(fileURLWithPath: "/Volumes/Backup/lesson.mp4"),
            fileName: "lesson.mp4",
            fileSize: 101
        )
        let existing = [
            ImportedVideoRecord(sourcePath: nil, fileName: "lesson.mp4", fileSize: 100),
        ]

        #expect(ImportDuplicatePolicy.uniqueCandidates([candidate], existingRecords: existing) == [candidate])
    }
}

@Suite("Transcript follow policy")
struct TranscriptFollowPolicyTests {
    private let viewport = CGRect(x: 0, y: 0, width: 760, height: 700)

    @Test("Playback follows a paragraph crossing the bottom boundary")
    func playbackFollowsBelowBottomBoundary() {
        #expect(TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: CGRect(x: 100, y: 650, width: 560, height: 80),
            viewport: viewport,
            isPlaying: true,
            isSuppressed: false,
            mode: .playbackAdvance
        ))
    }

    @Test("Playback leaves a visible paragraph alone")
    func visibleParagraphDoesNotScroll() {
        #expect(!TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: CGRect(x: 100, y: 300, width: 560, height: 80),
            viewport: viewport,
            isPlaying: true,
            isSuppressed: false,
            mode: .playbackAdvance
        ))
    }

    @Test("User suppression prevents playback following")
    func suppressionPreventsFollowing() {
        #expect(!TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: CGRect(x: 100, y: 650, width: 560, height: 80),
            viewport: viewport,
            isPlaying: true,
            isSuppressed: true,
            mode: .playbackAdvance
        ))
    }

    @Test("Paused playback does not follow")
    func pausedPlaybackDoesNotScroll() {
        #expect(!TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: CGRect(x: 100, y: 650, width: 560, height: 80),
            viewport: viewport,
            isPlaying: false,
            isSuppressed: false,
            mode: .playbackAdvance
        ))
    }

    @Test("Resume returns a paragraph above the viewport")
    func resumeReturnsParagraphAboveViewport() {
        let paragraph = CGRect(x: 100, y: -50, width: 560, height: 30)

        #expect(!TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: paragraph,
            viewport: viewport,
            isPlaying: true,
            isSuppressed: false,
            mode: .playbackAdvance
        ))
        #expect(TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: paragraph,
            viewport: viewport,
            isPlaying: true,
            isSuppressed: false,
            mode: .resume
        ))
    }

    @Test("Invalid geometry never follows")
    func invalidGeometryDoesNotScroll() {
        #expect(!TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: CGRect(x: CGFloat.nan, y: 0, width: 560, height: 80),
            viewport: viewport,
            isPlaying: true,
            isSuppressed: false,
            mode: .resume
        ))
        #expect(!TranscriptFollowPolicy.shouldScroll(
            paragraphFrame: CGRect(x: 0, y: 0, width: 560, height: 80),
            viewport: .zero,
            isPlaying: true,
            isSuppressed: false,
            mode: .resume
        ))
    }

    @Test("Suppression deadline restarts from the latest user input")
    func suppressionDeadlineRestarts() {
        let firstInput = Date(timeIntervalSinceReferenceDate: 100)
        let laterInput = Date(timeIntervalSinceReferenceDate: 102.5)

        let firstDeadline = TranscriptFollowPolicy.suppressionDeadline(after: firstInput)
        let restartedDeadline = TranscriptFollowPolicy.suppressionDeadline(after: laterInput)

        #expect(firstDeadline == Date(timeIntervalSinceReferenceDate: 104))
        #expect(restartedDeadline == Date(timeIntervalSinceReferenceDate: 106.5))
        #expect(restartedDeadline > firstDeadline)
    }

    @Test("Playing paragraph without geometry uses an ID fallback")
    func missingGeometryFallsBack() {
        #expect(TranscriptFollowPolicy.shouldScrollToIDFallback(
            hasActiveParagraph: true,
            hasMeasurement: false,
            isPlaying: true,
            isSuppressed: false
        ))
    }

    @Test("Suppression prevents the missing-geometry fallback")
    func suppressionPreventsFallback() {
        #expect(!TranscriptFollowPolicy.shouldScrollToIDFallback(
            hasActiveParagraph: true,
            hasMeasurement: false,
            isPlaying: true,
            isSuppressed: true
        ))
    }

    @Test("Removing the active paragraph requires lifecycle reset")
    func removalRequiresReset() {
        #expect(TranscriptFollowPolicy.shouldResetLifecycle(activeParagraphID: nil))
        #expect(!TranscriptFollowPolicy.shouldResetLifecycle(activeParagraphID: "paragraph-1"))
    }
}
