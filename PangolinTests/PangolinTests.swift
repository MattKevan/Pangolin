//
//  PangolinTests.swift
//  PangolinTests
//
//  Created by Matt Kevan on 16/08/2025.
//

import Testing
import Foundation
@testable import Pangolin

struct PangolinTests {
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
}

@Suite("Video floating layout")
struct VideoFloatingLayoutTests {
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

@Suite("Floating video state")
@MainActor
struct FloatingVideoStateTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    private let aspectRatio: CGFloat = 16.0 / 9.0

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
}
