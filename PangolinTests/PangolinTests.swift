//
//  PangolinTests.swift
//  PangolinTests
//
//  Created by Matt Kevan on 16/08/2025.
//

import Testing
import Foundation
import Combine
import SwiftUI
@testable import Pangolin

@MainActor
private final class ManualVideoPresentationTransitionSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func sleep(for _: TimeInterval) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func completeNext() {
        continuations.removeFirst().resume()
    }

    func waitForPendingCount(_ expectedCount: Int) async {
        for _ in 0..<100 {
            guard pendingCount < expectedCount else { return }
            await Task.yield()
        }
    }
}

struct PangolinTests {
    @Test("Activity popover shows every item in order")
    func activityPopoverPolicyShowsEveryActiveItem() {
        let items = [1, 2, 3, 4, 5, 6]

        #expect(ActivityPopoverPolicy.visibleItems(items) == items)
    }

    @Test("Sidebar project selection opens projects only")
    func sidebarProjectSelectionPolicyOpensOnlyProjects() {
        #expect(SidebarProjectSelectionPolicy.canOpen(isProject: true))
        #expect(!SidebarProjectSelectionPolicy.canOpen(isProject: false))
    }

    @Test("Sidebar highlights an open project instead of the projects shortcut")
    func sidebarProjectSelectionPolicyHighlightsOpenProject() {
        #expect(SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
            isProjectsDestination: true,
            hasSelectedProject: true
        ))
        #expect(!SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
            isProjectsDestination: true,
            hasSelectedProject: false
        ))
        #expect(!SidebarProjectSelectionPolicy.prefersProjectRowHighlight(
            isProjectsDestination: false,
            hasSelectedProject: true
        ))
    }

    @Test("Sidebar projects shortcut resets an open project detail")
    func sidebarProjectSelectionPolicyResetsProjectDetailForProjectsShortcut() {
        #expect(SidebarProjectSelectionPolicy.shouldResetProjectDetail(
            isProjectsDestination: true,
            hasSelectedProject: true
        ))
        #expect(!SidebarProjectSelectionPolicy.shouldResetProjectDetail(
            isProjectsDestination: true,
            hasSelectedProject: false
        ))
        #expect(!SidebarProjectSelectionPolicy.shouldResetProjectDetail(
            isProjectsDestination: false,
            hasSelectedProject: true
        ))
    }

    @Test("Core Data store file protection uses a valid protection class string")
    func persistentStoreFileProtectionUsesValidString() {
        #expect(
            CoreDataStack.persistentStoreFileProtectionOptionValue
                == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        )
    }

    @Test("iOS Info plist enables remote notifications for CloudKit")
    func infoPlistIncludesRemoteNotificationBackgroundMode() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pangolin/Info-iOS.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(plist as? [String: Any])
        let backgroundModes = try #require(dictionary["UIBackgroundModes"] as? [String])

        #expect(backgroundModes.contains("remote-notification"))
    }
}

@Suite("Video presentation frame updates")
struct VideoPresentationFrameUpdatePolicyTests {
    @Test("An initial docked frame update is direct")
    func initialDockedFrameIsDirect() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: nil,
            newMode: .docked,
            hasPresentedFrame: false
        ) == .direct)
    }

    @Test("A steady docked frame update is direct")
    func steadyDockedFrameIsDirect() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .docked,
            newMode: .docked,
            hasPresentedFrame: true
        ) == .direct)
    }

    @Test("Moving from docked to floating animates")
    func dockedToFloatingAnimates() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .docked,
            newMode: .floating,
            hasPresentedFrame: true
        ) == .animated)
    }

    @Test("Moving from floating to docked animates")
    func floatingToDockedAnimates() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .floating,
            newMode: .docked,
            hasPresentedFrame: true
        ) == .animated)
    }

    @Test("An active transition smoothly retargets its frame")
    func activeTransitionRetargetsWithAnimation() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .docked,
            newMode: .docked,
            hasPresentedFrame: true,
            isTransitioning: true
        ) == .animated)
    }

    @Test("A floating gesture updates its frame directly")
    func floatingGestureUpdatesDirectly() {
        #expect(VideoPresentationFrameUpdatePolicy.decision(
            previousMode: .floating,
            newMode: .floating,
            hasPresentedFrame: true,
            isInteracting: true
        ) == .direct)
    }

    @Test("Reset clears directly applied presentation geometry")
    @MainActor
    func resetClearsPresentationGeometry() {
        let controller = VideoPresentationFrameController()

        controller.apply(
            destination: CGRect(x: 10, y: 20, width: 300, height: 200),
            mode: .docked,
            animated: false
        )
        controller.reset()

        #expect(controller.frame == nil)
        #expect(controller.mode == nil)
        #expect(!controller.isTransitioning)
    }

    @Test("An animated frame update transitions until its completion")
    @MainActor
    func animatedUpdateCompletes() async {
        let sleeper = ManualVideoPresentationTransitionSleeper()
        let controller = VideoPresentationFrameController(sleep: sleeper.sleep)
        let destination = CGRect(x: 10, y: 20, width: 300, height: 200)

        controller.apply(destination: destination, mode: .floating, animated: true)

        #expect(controller.frame == destination)
        #expect(controller.mode == .floating)
        #expect(controller.isTransitioning)
        await sleeper.waitForPendingCount(1)
        #expect(sleeper.pendingCount == 1)

        sleeper.completeNext()
        for _ in 0..<100 where controller.isTransitioning {
            await Task.yield()
        }

        #expect(!controller.isTransitioning)
    }

    @Test("A superseded completion cannot clear a retargeted transition")
    @MainActor
    func retargetIgnoresSupersededCompletion() async {
        let sleeper = ManualVideoPresentationTransitionSleeper()
        let controller = VideoPresentationFrameController(sleep: sleeper.sleep)
        let first = CGRect(x: 10, y: 20, width: 300, height: 200)
        let second = CGRect(x: 20, y: 30, width: 320, height: 180)

        controller.apply(destination: first, mode: .floating, animated: true)
        await sleeper.waitForPendingCount(1)
        controller.apply(destination: second, mode: .docked, animated: true)
        await sleeper.waitForPendingCount(2)

        #expect(sleeper.pendingCount == 2)
        sleeper.completeNext()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(controller.frame == second)
        #expect(controller.mode == .docked)
        #expect(controller.isTransitioning)

        sleeper.completeNext()
        for _ in 0..<100 where controller.isTransitioning {
            await Task.yield()
        }
        #expect(!controller.isTransitioning)
    }

    @Test("A direct update cancels an active animated completion")
    @MainActor
    func directUpdateCancelsAnimation() async {
        let sleeper = ManualVideoPresentationTransitionSleeper()
        let controller = VideoPresentationFrameController(sleep: sleeper.sleep)
        let animatedFrame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let directFrame = CGRect(x: 30, y: 40, width: 340, height: 190)

        controller.apply(destination: animatedFrame, mode: .floating, animated: true)
        await sleeper.waitForPendingCount(1)
        controller.apply(destination: directFrame, mode: .floating, animated: false)

        #expect(controller.frame == directFrame)
        #expect(controller.mode == .floating)
        #expect(!controller.isTransitioning)

        sleeper.completeNext()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(controller.frame == directFrame)
        #expect(controller.mode == .floating)
        #expect(!controller.isTransitioning)
    }

    @Test("Reset remains cleared after an animated completion")
    @MainActor
    func resetCancelsAnimation() async {
        let sleeper = ManualVideoPresentationTransitionSleeper()
        let controller = VideoPresentationFrameController(sleep: sleeper.sleep)

        controller.apply(
            destination: CGRect(x: 10, y: 20, width: 300, height: 200),
            mode: .floating,
            animated: true
        )
        await sleeper.waitForPendingCount(1)
        controller.reset()

        #expect(controller.frame == nil)
        #expect(controller.mode == nil)
        #expect(!controller.isTransitioning)

        sleeper.completeNext()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(controller.frame == nil)
        #expect(controller.mode == nil)
        #expect(!controller.isTransitioning)
    }
}

@Suite("Video playback selection")
struct VideoPlaybackSelectionTests {
    @Test("New selections load, repeated selections do nothing, and clearing stops playback")
    func selectionActionsAreDeduplicated() {
        let firstID = UUID()
        let secondID = UUID()

        #expect(VideoPlaybackSelection.action(
            selectedID: firstID,
            isVideoDetailActive: true,
            loadedID: nil
        ) == .load)
        #expect(VideoPlaybackSelection.action(
            selectedID: firstID,
            isVideoDetailActive: true,
            loadedID: firstID
        ) == .none)
        #expect(VideoPlaybackSelection.action(
            selectedID: secondID,
            isVideoDetailActive: true,
            loadedID: firstID
        ) == .load)
        #expect(VideoPlaybackSelection.action(
            selectedID: nil,
            isVideoDetailActive: true,
            loadedID: secondID
        ) == .clear)
    }

    @Test("Leaving video detail clears even when the selected video is preserved")
    func inactiveVideoPresentationClearsPlayback() {
        let videoID = UUID()

        #expect(VideoPlaybackSelection.action(
            selectedID: videoID,
            isVideoDetailActive: false,
            loadedID: videoID
        ) == .clear)
    }

    @Test("Switching videos discards stale playback while re-presenting the same video does not")
    func stalePlaybackIsDiscardedOnlyForVideoChanges() {
        let firstID = UUID()
        let secondID = UUID()

        #expect(VideoPlaybackSelection.isVideoChange(from: firstID, to: secondID))
        #expect(!VideoPlaybackSelection.isVideoChange(from: firstID, to: firstID))
        #expect(!VideoPlaybackSelection.isVideoChange(from: nil, to: firstID))
    }

    @Test("Superseded playback operations cannot mutate the current video")
    func playbackOperationTokensRejectSupersededWork() {
        let firstID = UUID()
        let secondID = UUID()
        let firstLoad = VideoPlaybackOperation.Token(generation: 1, videoID: firstID)

        #expect(VideoPlaybackOperation.isCurrent(
            firstLoad,
            generation: 1,
            videoID: firstID
        ))
        #expect(!VideoPlaybackOperation.isCurrent(
            firstLoad,
            generation: 2,
            videoID: firstID
        ))
        #expect(!VideoPlaybackOperation.isCurrent(
            firstLoad,
            generation: 1,
            videoID: secondID
        ))
    }

    @Test("A superseded load cannot clear subtitle loading state")
    func loadingOwnershipTransfersFromLoadToSubtitle() {
        let videoID = UUID()
        let load = VideoPlaybackOperation.Token(generation: 1, videoID: videoID)
        let subtitle = VideoPlaybackOperation.Token(generation: 2, videoID: videoID)

        #expect(VideoPlaybackOperation.ownsLoading(load, owner: load))
        #expect(!VideoPlaybackOperation.ownsLoading(load, owner: subtitle))
        #expect(VideoPlaybackOperation.ownsLoading(subtitle, owner: subtitle))
    }
}

@Suite("Video poster presentation")
struct VideoPosterPresentationTests {
    @Test("Dismissal survives replacement of the same video's player surface")
    func dismissalSurvivesSameVideoSurfaceReplacement() {
        let videoID = UUID()
        var state = VideoPosterPresentationState()

        state.prepare(for: videoID)
        state.dismiss(for: videoID)
        state.prepare(for: videoID)

        #expect(state.isDismissed(for: videoID))
    }

    @Test("Loading a different video resets poster dismissal")
    func differentVideoResetsDismissal() {
        let firstID = UUID()
        let secondID = UUID()
        var state = VideoPosterPresentationState()

        state.prepare(for: firstID)
        state.dismiss(for: firstID)
        state.prepare(for: secondID)

        #expect(!state.isDismissed(for: secondID))
        #expect(!state.isDismissed(for: firstID))
    }

    @Test("Clearing playback resets poster dismissal")
    func clearingResetsDismissal() {
        let videoID = UUID()
        var state = VideoPosterPresentationState()

        state.prepare(for: videoID)
        state.dismiss(for: videoID)
        state.clear()

        #expect(!state.isDismissed(for: videoID))
    }

    @Test("Stale surfaces cannot dismiss a newly selected video's poster")
    func staleDismissalIsIgnored() {
        let oldID = UUID()
        let currentID = UUID()
        var state = VideoPosterPresentationState()

        state.prepare(for: currentID)
        state.dismiss(for: oldID)

        #expect(!state.isDismissed(for: currentID))
    }
}

@Suite("Video floating layout")
struct VideoFloatingLayoutTests {
    @Test("Visible fraction measures vertical intersection and clamps to valid fractions")
    func visibleFractionMeasuresIntersection() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(VideoFloatingLayout.visibleFraction(
            of: CGRect(x: 50, y: 50, width: 200, height: 100),
            in: viewport
        ) == 1)
        #expect(VideoFloatingLayout.visibleFraction(
            of: CGRect(x: -100, y: -50, width: 200, height: 100),
            in: viewport
        ) == 0.5)
        #expect(VideoFloatingLayout.visibleFraction(
            of: CGRect(x: 500, y: 500, width: 200, height: 100),
            in: viewport
        ) == 0)
    }

    @Test("Visible fraction rejects empty and nonfinite geometry")
    func visibleFractionRejectsInvalidGeometry() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)
        let invalidFrames = [
            CGRect.zero,
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 100, y: 0, width: -100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
        ]

        for frame in invalidFrames {
            let fraction = VideoFloatingLayout.visibleFraction(of: frame, in: viewport)
            #expect(fraction == 0)
            #expect(fraction.isFinite)
        }

        #expect(VideoFloatingLayout.visibleFraction(
            of: CGRect(x: 0, y: 0, width: 100, height: 100),
            in: .zero
        ) == 0)
        #expect(VideoFloatingLayout.visibleFraction(
            of: CGRect(x: 0, y: 0, width: 100, height: 100),
            in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300)
        ) == 0)
    }

    @Test("Floating state uses separate float and dock thresholds")
    func floatingStateUsesHysteresis() {
        let visibleFraction: Double = 0.25
        let floatThreshold: Double = VideoFloatingLayout.floatVisibleFraction
        let dockThreshold: Double = VideoFloatingLayout.dockVisibleFraction

        #expect(VideoFloatingLayout.shouldFloat(isFloating: false, visibleFraction: visibleFraction))
        #expect(!VideoFloatingLayout.shouldFloat(isFloating: false, visibleFraction: 0.26))
        #expect(VideoFloatingLayout.shouldFloat(isFloating: true, visibleFraction: 0.59))
        #expect(!VideoFloatingLayout.shouldFloat(isFloating: true, visibleFraction: 0.60))
        #expect(floatThreshold == 0.25)
        #expect(dockThreshold == 0.60)
    }

    @Test("Resolution strings produce valid aspect ratios")
    func resolutionAspectRatios() {
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1920x1080") - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1080X1920") - 9.0 / 16.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "invalid") - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: nil) - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1e308x1e-308") - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1e-308x1e308") - 16.0 / 9.0) < 0.000_001)
        #expect(abs(VideoFloatingLayout.aspectRatio(for: "1000001x1080") - 16.0 / 9.0) < 0.000_001)
    }

    @Test("Default frame starts at the top right and fits the inline width")
    func defaultFrame() {
        let frame = VideoFloatingLayout.defaultFrame(
            in: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            inlineWidth: 760,
            aspectRatio: 16.0 / 9.0
        )

        #expect(abs(frame.width - 418) < 0.000_001)
        #expect(abs(frame.height - 235.125) < 0.000_001)
        #expect(abs(frame.maxX - 1_184) < 0.000_001)
        #expect(abs(frame.minY - 16) < 0.000_001)

        let fractionalFrame = VideoFloatingLayout.defaultFrame(
            in: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            inlineWidth: 761,
            aspectRatio: 16.0 / 9.0
        )
        #expect(abs(fractionalFrame.width - 761 * 0.55) < 0.000_001)
    }

    @Test("Drag preview derives from an immutable start frame")
    func dragPreviewUsesImmutableStartFrame() {
        let start = CGRect(x: 600, y: 20, width: 400, height: 225)
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)

        let first = VideoFloatingLayout.draggedFrame(
            from: start,
            translation: CGSize(width: -50, height: 30),
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )
        let repeated = VideoFloatingLayout.draggedFrame(
            from: start,
            translation: CGSize(width: -50, height: 30),
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )

        #expect(first == repeated)
        #expect(first.size == start.size)
        #expect(first.origin == CGPoint(x: 550, y: 50))
    }

    @Test("Drag preview clamps without changing size")
    func dragPreviewClampsWithoutChangingSize() {
        let start = CGRect(x: 400, y: 20, width: 400, height: 225)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let preview = VideoFloatingLayout.draggedFrame(
            from: start,
            translation: CGSize(width: 1_000, height: 1_000),
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )

        #expect(preview.size == start.size)
        #expect(preview.maxX <= bounds.maxX - VideoFloatingLayout.edgeInset)
        #expect(preview.maxY <= bounds.maxY - VideoFloatingLayout.edgeInset)
    }

    @Test("Resizing preserves aspect ratio and the opposite corner")
    func resizingFromBottomLeading() {
        let frame = VideoFloatingLayout.resizedFrame(
            from: CGRect(x: 700, y: 16, width: 400, height: 225),
            handle: .bottomLeading,
            translation: CGSize(width: -100, height: 20),
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.000_001)
        #expect(abs(frame.maxX - 1_100) < 0.000_001)
        #expect(abs(frame.minY - 16) < 0.000_001)

        let mixedAxisFrame = VideoFloatingLayout.resizedFrame(
            from: CGRect(x: 400, y: 16, width: 400, height: 225),
            handle: .bottomTrailing,
            translation: CGSize(width: 80, height: 50),
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 0, y: 0, width: 1_400, height: 1_000)
        )
        let expectedWidth = 400 + 50 * (16.0 / 9.0)
        #expect(abs(mixedAxisFrame.width - expectedWidth) < 0.000_001)
    }

    @Test(
        "Every resize handle preserves its opposite anchor",
        arguments: VideoResizeHandle.allCases
    )
    func everyResizeHandlePreservesOppositeAnchor(handle: VideoResizeHandle) {
        let source = CGRect(x: 400, y: 300, width: 400, height: 225)
        let translation: CGSize
        let expectedAnchor: CGPoint

        switch handle {
        case .topLeading:
            translation = CGSize(width: -80, height: -50)
            expectedAnchor = CGPoint(x: source.maxX, y: source.maxY)
        case .topTrailing:
            translation = CGSize(width: 80, height: -50)
            expectedAnchor = CGPoint(x: source.minX, y: source.maxY)
        case .bottomLeading:
            translation = CGSize(width: -80, height: 50)
            expectedAnchor = CGPoint(x: source.maxX, y: source.minY)
        case .bottomTrailing:
            translation = CGSize(width: 80, height: 50)
            expectedAnchor = CGPoint(x: source.minX, y: source.minY)
        }

        let frame = VideoFloatingLayout.resizedFrame(
            from: source,
            handle: handle,
            translation: translation,
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 0, y: 0, width: 1_400, height: 1_000)
        )

        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.000_001)
        switch handle {
        case .topLeading:
            #expect(abs(frame.maxX - expectedAnchor.x) < 0.000_001)
            #expect(abs(frame.maxY - expectedAnchor.y) < 0.000_001)
        case .topTrailing:
            #expect(abs(frame.minX - expectedAnchor.x) < 0.000_001)
            #expect(abs(frame.maxY - expectedAnchor.y) < 0.000_001)
        case .bottomLeading:
            #expect(abs(frame.maxX - expectedAnchor.x) < 0.000_001)
            #expect(abs(frame.minY - expectedAnchor.y) < 0.000_001)
        case .bottomTrailing:
            #expect(abs(frame.minX - expectedAnchor.x) < 0.000_001)
            #expect(abs(frame.minY - expectedAnchor.y) < 0.000_001)
        }
    }

    @Test("Resizing respects containment and minimum width")
    func resizingConstraints() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        let grownFrame = VideoFloatingLayout.resizedFrame(
            from: CGRect(x: 100, y: 100, width: 400, height: 225),
            handle: .bottomTrailing,
            translation: CGSize(width: 10_000, height: 10_000),
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )
        #expect(grownFrame.minX >= 16 - 0.000_001)
        #expect(grownFrame.minY >= 16 - 0.000_001)
        #expect(grownFrame.maxX <= 884 + 0.000_001)
        #expect(grownFrame.maxY <= 584 + 0.000_001)
        #expect(abs(grownFrame.width / grownFrame.height - 16.0 / 9.0) < 0.000_001)

        let minimumFrame = VideoFloatingLayout.fittedFrame(
            CGRect(x: 100, y: 100, width: 80, height: 45),
            aspectRatio: 16.0 / 9.0,
            in: bounds
        )
        #expect(abs(minimumFrame.width - 240) < 0.000_001)

        let constrainedBounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let constrainedFrame = VideoFloatingLayout.fittedFrame(
            CGRect(x: 16, y: 16, width: 80, height: 45),
            aspectRatio: 16.0 / 9.0,
            in: constrainedBounds
        )
        #expect(constrainedFrame.width < 240)
        #expect(constrainedFrame.minX >= -0.000_001)
        #expect(constrainedFrame.minY >= -0.000_001)
        #expect(constrainedFrame.maxX <= constrainedBounds.maxX + 0.000_001)
        #expect(constrainedFrame.maxY <= constrainedBounds.maxY + 0.000_001)
    }

    @Test("Zero and undersized bounds produce safe frames")
    func zeroAndUndersizedBounds() {
        let zeroDefault = VideoFloatingLayout.defaultFrame(
            in: .zero,
            inlineWidth: 760,
            aspectRatio: 16.0 / 9.0
        )
        let offsetZeroFitted = VideoFloatingLayout.fittedFrame(
            CGRect(x: 10, y: 10, width: 400, height: 225),
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 50, y: 50, width: 0, height: 0)
        )
        for frame in [zeroDefault, offsetZeroFitted] {
            #expect(abs(frame.minX) < 0.000_001)
            #expect(abs(frame.minY) < 0.000_001)
            #expect(abs(frame.width) < 0.000_001)
            #expect(abs(frame.height) < 0.000_001)
        }

        for bounds in [
            CGRect(x: 0, y: 0, width: 20, height: 20),
            CGRect(x: 0, y: 0, width: 20, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 20)
        ] {
            let frames = [
                VideoFloatingLayout.defaultFrame(
                    in: bounds,
                    inlineWidth: 760,
                    aspectRatio: 16.0 / 9.0
                ),
                VideoFloatingLayout.fittedFrame(
                    CGRect(x: 80, y: 80, width: 400, height: 225),
                    aspectRatio: 16.0 / 9.0,
                    in: bounds
                )
            ]
            for frame in frames {
                #expect(frame.minX >= bounds.minX - 0.000_001)
                #expect(frame.minY >= bounds.minY - 0.000_001)
                #expect(frame.maxX <= bounds.maxX + 0.000_001)
                #expect(frame.maxY <= bounds.maxY + 0.000_001)
            }
        }
    }

    @Test("Fitting keeps an oversized-positioned frame reachable")
    func fittingFrameIntoBounds() {
        let frame = VideoFloatingLayout.fittedFrame(
            CGRect(x: 800, y: 550, width: 400, height: 225),
            aspectRatio: 16.0 / 9.0,
            in: CGRect(x: 0, y: 0, width: 900, height: 600)
        )

        #expect(frame.minX >= 16)
        #expect(frame.minY >= 16)
        #expect(frame.maxX <= 884)
        #expect(frame.maxY <= 584)
        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.000_001)
    }
}

@Suite("Video display geometry")
struct VideoDisplayGeometryTests {
    @Test("Identity transforms preserve landscape display dimensions")
    func identityTransformPreservesDimensions() throws {
        let size = try #require(VideoDisplayGeometry.displaySize(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        ))

        #expect(size == CGSize(width: 1920, height: 1080))
    }

    @Test("Quarter-turn transforms produce portrait display dimensions")
    func quarterTurnsSwapDimensions() throws {
        let clockwise = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let counterclockwise = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)

        let clockwiseSize = try #require(VideoDisplayGeometry.displaySize(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: clockwise
        ))
        let counterclockwiseSize = try #require(VideoDisplayGeometry.displaySize(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: counterclockwise
        ))

        #expect(clockwiseSize == CGSize(width: 1080, height: 1920))
        #expect(counterclockwiseSize == CGSize(width: 1080, height: 1920))
    }

    @Test("Mirroring and translation return standardized positive dimensions")
    func mirroringAndTranslationAreStandardized() throws {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2500, ty: -400)
        let size = try #require(VideoDisplayGeometry.displaySize(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        ))

        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("Invalid natural dimensions are rejected")
    func invalidNaturalDimensionsAreRejected() {
        let invalidSizes = [
            CGSize.zero,
            CGSize(width: 0, height: 1080),
            CGSize(width: -1920, height: 1080),
            CGSize(width: CGFloat.infinity, height: 1080),
            CGSize(width: 1920, height: CGFloat.nan),
        ]

        for size in invalidSizes {
            #expect(VideoDisplayGeometry.displaySize(
                naturalSize: size,
                preferredTransform: .identity
            ) == nil)
        }
    }

    @Test("Invalid transforms safely fall back to valid natural dimensions")
    func invalidTransformsUseNaturalDimensions() throws {
        let naturalSize = CGSize(width: 1920, height: 1080)
        let collapsed = CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
        let nonfinite = CGAffineTransform(a: CGFloat.infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        #expect(VideoDisplayGeometry.displaySize(
            naturalSize: naturalSize,
            preferredTransform: collapsed
        ) == naturalSize)
        #expect(VideoDisplayGeometry.displaySize(
            naturalSize: naturalSize,
            preferredTransform: nonfinite
        ) == naturalSize)
    }

    @Test("Extreme finite transforms fall back without producing unrepresentable dimensions")
    func extremeFiniteTransformsUseNaturalDimensions() {
        let naturalSize = CGSize(width: 1920, height: 1080)
        let extreme = CGAffineTransform(
            a: CGFloat.greatestFiniteMagnitude,
            b: 0,
            c: 0,
            d: CGFloat.greatestFiniteMagnitude,
            tx: 0,
            ty: 0
        )

        #expect(VideoDisplayGeometry.displaySize(
            naturalSize: naturalSize,
            preferredTransform: extreme
        ) == naturalSize)
    }

    @Test("Display dimensions enforce the supported conversion boundary")
    func displayDimensionBoundaryIsSafe() {
        let maximum = VideoDisplayGeometry.maximumDimension

        #expect(VideoDisplayGeometry.displaySize(
            naturalSize: CGSize(width: maximum, height: 1),
            preferredTransform: .identity
        ) == CGSize(width: maximum, height: 1))
        #expect(VideoDisplayGeometry.displaySize(
            naturalSize: CGSize(width: maximum.nextUp, height: 1),
            preferredTransform: .identity
        ) == nil)
    }
}

@Suite("Video aspect ratio selection")
struct VideoAspectRatioSelectionTests {
    @Test("A new video starts from its valid persisted resolution")
    func newVideoUsesPersistedResolution() {
        let ratio = VideoAspectRatioSelection.initialRatio(
            loadedVideoID: UUID(),
            selectedVideoID: UUID(),
            currentRatio: 9.0 / 16.0,
            persistedResolution: "1440x1080"
        )

        #expect(abs(ratio - 4.0 / 3.0) < 0.000_001)
    }

    @Test("A new video with invalid persisted resolution uses the safe fallback")
    func newVideoUsesFallbackForInvalidResolution() {
        let ratio = VideoAspectRatioSelection.initialRatio(
            loadedVideoID: UUID(),
            selectedVideoID: UUID(),
            currentRatio: 9.0 / 16.0,
            persistedResolution: "not-a-resolution"
        )

        #expect(ratio == VideoFloatingLayout.fallbackAspectRatio)
    }

    @Test("Reloading the same video retains its resolved aspect ratio")
    func sameVideoRetainsResolvedRatio() {
        let videoID = UUID()
        let ratio = VideoAspectRatioSelection.initialRatio(
            loadedVideoID: videoID,
            selectedVideoID: videoID,
            currentRatio: 9.0 / 16.0,
            persistedResolution: "1920x1080"
        )

        #expect(abs(ratio - 9.0 / 16.0) < 0.000_001)
    }

    @Test("Reloading the same video rejects an invalid current ratio")
    func sameVideoRejectsInvalidCurrentRatio() {
        let videoID = UUID()
        let ratio = VideoAspectRatioSelection.initialRatio(
            loadedVideoID: videoID,
            selectedVideoID: videoID,
            currentRatio: .infinity,
            persistedResolution: "1440x1080"
        )

        #expect(abs(ratio - 4.0 / 3.0) < 0.000_001)
    }
}

@Suite("Floating video state")
@MainActor
struct FloatingVideoStateTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    private let aspectRatio: CGFloat = 16.0 / 9.0

    @Test("A missing preference floats only after a valid current-video measurement")
    func missingPreferenceUsesPriorCurrentMeasurement() {
        let state = FloatingVideoState()
        let firstVideoID = UUID()

        state.reset(for: firstVideoID)
        state.updateVisibilityMeasurement(nil)
        #expect(!state.isFloating)

        state.updateInlineWidth(760)
        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )
        state.updateVisibilityMeasurement(0.80)
        #expect(!state.isFloating)

        state.updateVisibilityMeasurement(nil)
        #expect(state.isFloating)

        state.reset(for: UUID())
        state.updateVisibilityMeasurement(nil)
        #expect(!state.isFloating)
    }

    @Test("Repeated geometry on the same hysteresis side does not republish state")
    func unchangedGeometryDoesNotPublish() {
        let state = FloatingVideoState()
        state.updateInlineWidth(760)
        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )

        var changeCount = 0
        let observation = state.objectWillChange.sink {
            changeCount += 1
        }

        state.updateInlineWidth(760)
        #expect(changeCount == 0)

        state.updateInlineWidth(760)
        state.updateVisibleFraction(0.80)
        #expect(changeCount == 0)

        state.updateVisibleFraction(0.20)
        #expect(changeCount == 1)

        state.updateVisibleFraction(0.10)
        #expect(changeCount == 1)

        withExtendedLifetime(observation) {}
    }

    @Test("Inline width records valid measurements and resets with video presentation")
    func inlineWidthTracksCurrentVideoOnly() {
        let state = FloatingVideoState()
        let videoID = UUID()

        state.reset(for: videoID)
        state.updateInlineWidth(760)
        #expect(state.inlineWidth == 760)

        state.updateInlineWidth(0)
        state.updateInlineWidth(.nan)
        #expect(state.inlineWidth == 760)

        state.reset(for: UUID())
        #expect(state.inlineWidth == 0)
    }

    @Test("Inline frame records valid geometry and resets with video presentation")
    func inlineFrameTracksCurrentVideoOnly() {
        let state = FloatingVideoState()
        let inlineFrame = CGRect(x: 120, y: 40, width: 800, height: 450)

        state.reset(for: UUID())
        state.updateInlineFrame(inlineFrame)
        #expect(state.inlineFrame == inlineFrame)

        state.updateInlineFrame(.zero)
        state.updateInlineFrame(CGRect(x: CGFloat.nan, y: 0, width: 800, height: 450))
        #expect(state.inlineFrame == inlineFrame)

        state.reset(for: UUID())
        #expect(state.inlineFrame == .zero)
    }

    @Test("Visibility thresholds float and dock without resetting placement")
    func visibilityThresholdsPreservePlacement() {
        let videoID = UUID()
        let state = FloatingVideoState()

        state.reset(for: videoID)
        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        let preparedFrame = state.frame

        state.updateVisibleFraction(0.20)
        #expect(state.videoID == videoID)
        #expect(state.isFloating)

        state.updateVisibleFraction(0.40)
        #expect(state.isFloating)
        #expect(state.frame == preparedFrame)

        state.updateVisibleFraction(0.70)
        #expect(!state.isFloating)
    }

    @Test("A new video resets floating state and placement")
    func newVideoResetsState() {
        let originalVideoID = UUID()
        let newVideoID = UUID()
        let state = FloatingVideoState()

        state.reset(for: originalVideoID)
        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        state.updateVisibleFraction(0.20)
        state.move(
            by: CGSize(width: -120, height: 80),
            in: bounds,
            aspectRatio: aspectRatio
        )
        #expect(state.frame != .zero)

        state.reset(for: newVideoID)

        #expect(state.videoID == newVideoID)
        #expect(!state.isFloating)
        #expect(state.frame == .zero)
    }

    @Test("Clearing selection makes reopening the same video start fresh")
    func clearingSelectionResetsPriorVideoPlacement() {
        let videoID = UUID()
        let state = FloatingVideoState()

        state.reset(for: videoID)
        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        state.move(
            by: CGSize(width: -180, height: 90),
            in: bounds,
            aspectRatio: aspectRatio
        )
        state.updateVisibleFraction(0.20)
        let movedFrame = state.frame

        state.reset(for: nil)
        #expect(state.videoID == nil)
        #expect(!state.isFloating)
        #expect(state.frame == .zero)

        state.reset(for: videoID)
        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )

        #expect(state.videoID == videoID)
        #expect(!state.isFloating)
        #expect(state.frame != movedFrame)
        #expect(state.frame == VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        ))
    }

    @Test("Resetting the same video preserves its presentation")
    func sameVideoResetPreservesPresentation() {
        let videoID = UUID()
        let state = FloatingVideoState()

        state.reset(for: videoID)
        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        state.move(
            by: CGSize(width: -120, height: 80),
            in: bounds,
            aspectRatio: aspectRatio
        )
        state.updateVisibleFraction(0.20)
        let movedFrame = state.frame

        state.reset(for: videoID)

        #expect(state.videoID == videoID)
        #expect(state.isFloating)
        #expect(state.frame == movedFrame)
    }

    @Test("Setting a frame clamps it inside available bounds")
    func setFrameClampsToBounds() {
        let state = FloatingVideoState()

        state.setFrame(
            CGRect(x: 850, y: 580, width: 320, height: 180),
            in: CGRect(x: 0, y: 0, width: 900, height: 600),
            aspectRatio: aspectRatio
        )

        #expect(state.frame.maxX <= 884)
        #expect(state.frame.maxY <= 584)
    }

    @Test("Preparation retries after transient zero bounds")
    func preparationRetriesAfterZeroBounds() {
        let state = FloatingVideoState()

        state.prepareDefaultFrame(
            in: .zero,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        #expect(state.frame == .zero)

        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )

        #expect(state.frame != .zero)
        #expect(state.frame.minX >= 16)
        #expect(state.frame.minY == 16)
        #expect(state.frame.maxX == 1_184)
        #expect(state.frame.maxY <= 784)
    }

    @Test("Inline geometry prepares a floating destination before undocking")
    func preparesDestinationWhileDocked() {
        let state = FloatingVideoState()

        state.reset(for: UUID())
        state.updateInlineFrame(CGRect(x: 120, y: 40, width: 800, height: 450))
        state.updateInlineWidth(800)
        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )

        #expect(!state.isFloating)
        #expect(state.frame != .zero)
        #expect(state.frame == VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: 800,
            aspectRatio: aspectRatio
        ))
    }

    @Test("First offscreen measurement waits for a floating destination")
    func firstOffscreenMeasurementWaitsForDestination() {
        let state = FloatingVideoState()

        state.reset(for: UUID())
        state.updateInlineWidth(800)
        state.updateVisibleFraction(0.20)
        #expect(!state.isFloating)

        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )

        #expect(state.frame != .zero)
        #expect(state.isFloating)
    }

    @Test("Transient unusable bounds preserve customized placement")
    func transientBoundsPreserveCustomizedPlacement() {
        let state = FloatingVideoState()

        state.prepareDefaultFrame(
            in: bounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        state.move(
            by: CGSize(width: -200, height: 100),
            in: bounds,
            aspectRatio: aspectRatio
        )
        let movedFrame = state.frame

        state.prepareDefaultFrame(
            in: .zero,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )
        #expect(state.frame == movedFrame)

        let smallerBounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        state.prepareDefaultFrame(
            in: smallerBounds,
            inlineWidth: 760,
            aspectRatio: aspectRatio
        )

        #expect(state.frame == VideoFloatingLayout.fittedFrame(
            movedFrame,
            aspectRatio: aspectRatio,
            in: smallerBounds
        ))
        #expect(state.frame != movedFrame)
    }

    @Test("Repeated preparation with unchanged geometry does not publish")
    func repeatedPreparationDoesNotPublish() {
        let state = FloatingVideoState()
        state.updateInlineWidth(760)
        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )

        var changeCount = 0
        let observation = state.objectWillChange.sink {
            changeCount += 1
        }

        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )

        #expect(changeCount == 0)
        withExtendedLifetime(observation) {}
    }

    @Test("Invalid viewport clears a previous measurement for host fallback")
    func invalidViewportClearsMeasurement() {
        let state = FloatingVideoState()
        state.updatePresentationViewportFrame(
            CGRect(x: 0, y: 96, width: 800, height: 600)
        )

        state.updatePresentationViewportFrame(.zero)

        #expect(state.presentationViewportFrame == .zero)
    }

    @Test("Viewport follows the detail shell lifecycle instead of video identity")
    func viewportPersistsBetweenVideosAndClearsOnExit() {
        let state = FloatingVideoState()
        let viewportFrame = CGRect(x: 0, y: 96, width: 800, height: 600)

        state.reset(for: UUID())
        state.updatePresentationViewportFrame(viewportFrame)
        state.reset(for: UUID())

        #expect(state.presentationViewportFrame == viewportFrame)

        state.reset(for: nil)

        #expect(state.presentationViewportFrame == .zero)
    }
}

@Suite("Floating video directional movement")
struct FloatingVideoDirectionalMovementTests {
    @Test("Directional commands use the platform-neutral movement step")
    func directionalTranslations() {
        #expect(VideoFloatingMovement.translation(for: .left) == CGSize(width: -10, height: 0))
        #expect(VideoFloatingMovement.translation(for: .right) == CGSize(width: 10, height: 0))
        #expect(VideoFloatingMovement.translation(for: .up) == CGSize(width: 0, height: -10))
        #expect(VideoFloatingMovement.translation(for: .down) == CGSize(width: 0, height: 10))
    }
}

@Suite("Video player presentation policy")
struct VideoPlayerPresentationPolicyTests {
    private let inline = CGRect(x: 100, y: 80, width: 800, height: 450)
    private let floating = CGRect(x: 700, y: 40, width: 440, height: 247.5)

    @Test("Docked presentation uses the inline frame")
    func dockedDestination() {
        #expect(VideoPlayerPresentationPolicy.destination(
            isFloating: false,
            inlineFrame: inline,
            floatingFrame: floating
        ) == inline)
    }

    @Test("Floating presentation uses the committed floating frame")
    func floatingDestination() {
        #expect(VideoPlayerPresentationPolicy.destination(
            isFloating: true,
            inlineFrame: inline,
            floatingFrame: floating
        ) == floating)
    }

    @Test("Invalid destinations are rejected")
    func invalidDestination() {
        #expect(VideoPlayerPresentationPolicy.destination(
            isFloating: false,
            inlineFrame: .zero,
            floatingFrame: floating
        ) == nil)
    }

    @Test("Only dock state changes animate")
    func animationEligibility() {
        #expect(VideoPlayerPresentationPolicy.shouldAnimate(from: false, to: true))
        #expect(VideoPlayerPresentationPolicy.shouldAnimate(from: true, to: false))
        #expect(!VideoPlayerPresentationPolicy.shouldAnimate(from: false, to: false))
        #expect(!VideoPlayerPresentationPolicy.shouldAnimate(from: true, to: true))
    }

    @Test("Docked presentation ignores a stale floating interaction preview")
    func dockedPresentationIgnoresPreview() {
        let preview = CGRect(x: 500, y: 200, width: 320, height: 180)

        #expect(VideoPlayerPresentationPolicy.renderedFrame(
            isFloating: false,
            baseFrame: inline,
            interactionPreviewFrame: preview
        ) == inline)
        #expect(VideoPlayerPresentationPolicy.renderedFrame(
            isFloating: true,
            baseFrame: floating,
            interactionPreviewFrame: preview
        ) == preview)
    }

    @Test("Root geometry converts to overlay-local coordinates")
    func overlayLocalFrame() {
        let rootFrame = CGRect(x: 120, y: 180, width: 800, height: 450)
        let overlayFrameInRoot = CGRect(x: 0, y: 58, width: 1200, height: 742)

        #expect(VideoPlayerPresentationPolicy.overlayLocalFrame(
            rootFrame,
            overlayFrameInRoot: overlayFrameInRoot
        ) == CGRect(x: 120, y: 122, width: 800, height: 450))
    }

    @Test("Invalid root and overlay geometry are rejected")
    func invalidOverlayGeometry() {
        #expect(VideoPlayerPresentationPolicy.overlayLocalFrame(
            .zero,
            overlayFrameInRoot: CGRect(x: 0, y: 58, width: 1200, height: 742)
        ) == nil)
        #expect(VideoPlayerPresentationPolicy.overlayLocalFrame(
            inline,
            overlayFrameInRoot: .zero
        ) == nil)
    }
}

struct VideoPresentationHostLayoutTests {
    @Test("Available bounds subtract safe-area insets")
    func subtractsSafeAreaInsets() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 390, height: 844),
            insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        ) == CGRect(x: 0, y: 59, width: 390, height: 751))
    }

    @Test("Oversized safe-area insets produce empty bounds")
    func rejectsOversizedInsets() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 100, height: 100),
            insets: EdgeInsets(top: 80, leading: 60, bottom: 30, trailing: 60)
        ) == .zero)
    }

    @Test("Safe-area bounds at or below two edge insets are unusable")
    func rejectsSafeAreaBoundsWithoutPositiveInsetArea() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 32, height: 100),
            insets: EdgeInsets()
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 40, height: 40),
            insets: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        ) == .zero)
    }

    @Test("Safe-area bounds above two edge insets remain usable")
    func acceptsSafeAreaBoundsWithPositiveInsetArea() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 33, height: 33),
            insets: EdgeInsets()
        ) == CGRect(x: 0, y: 0, width: 33, height: 33))
    }

    @Test("Detail viewport excludes the sidebar while retaining inspector-side width")
    func excludesSidebarAndRetainsInspectorWidth() {
        let outerBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(x: 260, y: 60, width: 700, height: 700)
        ) == CGRect(x: 260, y: 60, width: 940, height: 700))
    }

    @Test("Invalid detail viewport falls back to outer safe bounds")
    func invalidViewportFallsBack() {
        let outerBounds = CGRect(x: 0, y: 59, width: 390, height: 751)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(
                x: 0,
                y: CGFloat.nan,
                width: 390,
                height: 700
            )
        ) == outerBounds)
    }

    @Test("Missing detail viewport falls back to outer safe bounds")
    func missingViewportFallsBack() {
        let outerBounds = CGRect(x: 0, y: 59, width: 390, height: 751)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: nil
        ) == outerBounds)
    }

    @Test("Missing viewport only falls back to pane-usable outer bounds")
    func missingViewportRejectsUnusableOuterBounds() {
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 32, height: 100),
            presentationViewportFrame: nil
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 33, height: 33),
            presentationViewportFrame: nil
        ) == CGRect(x: 0, y: 0, width: 33, height: 33))
    }

    @Test("Detail viewport disjoint on either horizontal side produces empty bounds")
    func horizontallyDisjointViewportIsEmpty() {
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            presentationViewportFrame: CGRect(x: 1300, y: 60, width: 700, height: 700)
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            presentationViewportFrame: CGRect(x: -700, y: 60, width: 600, height: 700)
        ) == .zero)
    }

    @Test("Viewport intersection must leave positive area inside pane edge insets")
    func viewportIntersectionRequiresPositiveInsetArea() {
        let outerBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(x: 1168, y: 60, width: 100, height: 700)
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(x: 1167, y: 60, width: 100, height: 700)
        ) == CGRect(x: 1167, y: 60, width: 33, height: 700))
    }
}

@Suite("Phone video route pop policy")
struct PhoneVideoRoutePopPolicyTests {
    @Test("Popping an active collection video route unwinds the store detail")
    func removedVideoRouteNavigatesBack() {
        let videoID = UUID()

        #expect(PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [videoID],
            newVideoRouteIDs: [],
            selectedVideoID: videoID,
            isVideoDetailActive: true
        ))
    }

    @Test("A steady active video route leaves store detail unchanged")
    func steadyVideoRouteDoesNotNavigateBack() {
        let videoID = UUID()

        #expect(!PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [videoID],
            newVideoRouteIDs: [videoID],
            selectedVideoID: videoID,
            isVideoDetailActive: true
        ))
    }

    @Test("Removing a different video route does not unwind the active detail")
    func unrelatedVideoRouteDoesNotNavigateBack() {
        let selectedVideoID = UUID()

        #expect(!PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [UUID()],
            newVideoRouteIDs: [],
            selectedVideoID: selectedVideoID,
            isVideoDetailActive: true
        ))
    }

    @Test("Programmatic route removal for an inactive origin does not behave like native Back")
    func inactiveOriginRemovalDoesNotNavigateBack() {
        let videoID = UUID()

        #expect(!PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [videoID],
            newVideoRouteIDs: [],
            selectedVideoID: videoID,
            isVideoDetailActive: false
        ))
    }
}

@Suite("Phone video route sync policy")
struct PhoneVideoRouteSyncPolicyTests {
    @Test("Selecting the first collection video appends a route")
    func firstCollectionVideoAppendsRoute() {
        #expect(PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: [],
            selectedVideoID: UUID()
        ) == .append)
    }

    @Test("Selecting another search result replaces the existing terminal video route")
    func nextVideoReplacesRoute() {
        let oldVideoID = UUID()
        let newVideoID = UUID()

        #expect(PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: [oldVideoID],
            selectedVideoID: newVideoID
        ) == .replace)
    }

    @Test("Selecting the routed video again does not duplicate it")
    func selectedRouteIsNotDuplicated() {
        let videoID = UUID()

        #expect(PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: [videoID],
            selectedVideoID: videoID
        ) == .none)
    }
}

@Suite("Phone video route deactivation policy")
struct PhoneVideoRouteDeactivationPolicyTests {
    @Test("Deactivating a tab removes its stale video route")
    func activeRouteIsRemoved() {
        #expect(PhoneVideoRouteDeactivationPolicy.action(
            existingVideoRouteIDs: [UUID()]
        ) == .removeVideoRoutes)
    }

    @Test("Deactivating a root tab leaves its path unchanged")
    func rootPathIsUnchanged() {
        #expect(PhoneVideoRouteDeactivationPolicy.action(
            existingVideoRouteIDs: []
        ) == .none)
    }

    @Test("Removing a project video route preserves the project route")
    func projectRouteIsPreserved() {
        let projectID = UUID()

        #expect(PhoneProjectsPathPolicy.removingVideoRoutes(from: [
            .project(projectID),
            .video(UUID())
        ]) == [.project(projectID)])
    }
}

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
    @Test("Regular workspace owns ordinary sidebar navigation")
    func regularWorkspaceOwnsSidebarNavigation() {
        #expect(VideoToolbarPolicy.ownership(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: true
        ) == .appOwned)
        #expect(VideoToolbarPolicy.removesSystemSidebarButton(
            shell: .workspace,
            isVideoDetail: false,
            supportsAppOwnedSidebarButton: true
        ))
        #expect(VideoToolbarPolicy.showsSidebarButton(
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
