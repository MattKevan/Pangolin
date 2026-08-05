import Testing
import Foundation
import Combine
import SwiftUI
import AVFoundation
@testable import Pangolin


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
