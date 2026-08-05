import Testing
import Foundation
import Combine
import SwiftUI
import AVFoundation
@testable import Pangolin


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
