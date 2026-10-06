import Testing
import Foundation
import SwiftUI
import AVFoundation
@testable import Pangolin


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


/// Counts observable changes to a `FloatingVideoState`. Observation fires once per arming, so the
/// count is of changes since the last `consumeChanges()` call, which re-arms it.
@MainActor
private final class StateChangeObserver {
    private let state: FloatingVideoState
    private var pendingChanges = 0
    private var isArmed = false

    init(_ state: FloatingVideoState) {
        self.state = state
        arm()
    }

    private func arm() {
        isArmed = true
        withObservationTracking {
            _ = state.isFloating
            _ = state.frame
            _ = state.videoID
            _ = state.inlineWidth
            _ = state.inlineFrame
            _ = state.presentationViewportFrame
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingChanges += 1
                self?.isArmed = false
            }
        }
    }

    func consumeChanges() -> Int {
        defer {
            pendingChanges = 0
            if !isArmed { arm() }
        }
        return pendingChanges
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

        let observer = StateChangeObserver(state)

        state.updateInlineWidth(760)
        #expect(observer.consumeChanges() == 0)

        state.updateInlineWidth(760)
        state.updateVisibleFraction(0.80)
        #expect(observer.consumeChanges() == 0)

        state.updateVisibleFraction(0.20)
        #expect(observer.consumeChanges() == 1)

        state.updateVisibleFraction(0.10)
        #expect(observer.consumeChanges() == 0)
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

        let observer = StateChangeObserver(state)

        state.prepareFloatingDestination(
            in: bounds,
            aspectRatio: aspectRatio
        )

        #expect(observer.consumeChanges() == 0)
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
