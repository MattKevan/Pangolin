//
//  VideoFloatingLayout.swift
//  Pangolin
//

import SwiftUI

enum VideoResizeHandle: CaseIterable, Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

enum VideoFloatingLayout {
    static let floatVisibleFraction: Double = 0.25
    static let dockVisibleFraction: Double = 0.60
    static let initialWidthScale: CGFloat = 0.55
    static let minimumWidth: CGFloat = 240
    static let edgeInset: CGFloat = 16
    static let fallbackAspectRatio: CGFloat = 16.0 / 9.0

    static func shouldFloat(isFloating: Bool, visibleFraction: Double) -> Bool {
        let visibleFraction = min(max(visibleFraction, 0), 1)
        return isFloating
            ? visibleFraction < dockVisibleFraction
            : visibleFraction <= floatVisibleFraction
    }

    static func aspectRatio(for resolution: String?) -> CGFloat {
        guard let resolution else { return fallbackAspectRatio }

        let dimensions = resolution
            .lowercased()
            .split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let width = Double(dimensions[0]),
              let height = Double(dimensions[1]),
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0 else {
            return fallbackAspectRatio
        }

        let ratio = CGFloat(width) / CGFloat(height)
        guard ratio.isFinite, ratio > 0 else {
            return fallbackAspectRatio
        }

        return ratio
    }

    static func defaultFrame(
        in bounds: CGRect,
        inlineWidth: CGFloat,
        aspectRatio: CGFloat
    ) -> CGRect {
        let ratio = validRatio(aspectRatio)
        let availableBounds = availableBounds(in: bounds)
        guard !availableBounds.isEmpty else { return .zero }

        let proposedWidth = max(inlineWidth * initialWidthScale, minimumWidth)
        let size = fittedSize(
            proposedWidth: proposedWidth,
            aspectRatio: ratio,
            in: availableBounds
        )

        return CGRect(
            x: availableBounds.maxX - size.width,
            y: availableBounds.minY,
            width: size.width,
            height: size.height
        )
    }

    static func fittedFrame(
        _ frame: CGRect,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let ratio = validRatio(aspectRatio)
        let availableBounds = availableBounds(in: bounds)
        guard !availableBounds.isEmpty else { return .zero }

        let frame = frame.standardized
        let proposedWidth = frame.width.isFinite && frame.width > 0
            ? max(frame.width, minimumWidth)
            : minimumWidth
        let size = fittedSize(
            proposedWidth: proposedWidth,
            aspectRatio: ratio,
            in: availableBounds
        )
        let maximumX = availableBounds.maxX - size.width
        let maximumY = availableBounds.maxY - size.height
        let x = min(max(frame.minX, availableBounds.minX), maximumX)
        let y = min(max(frame.minY, availableBounds.minY), maximumY)

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func resizedFrame(
        from frame: CGRect,
        handle: VideoResizeHandle,
        translation: CGSize,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        let ratio = validRatio(aspectRatio)
        let start = fittedFrame(frame, aspectRatio: ratio, in: bounds)
        let availableBounds = availableBounds(in: bounds)
        guard !start.isEmpty, !availableBounds.isEmpty else { return .zero }

        let horizontalDelta: CGFloat
        switch handle {
        case .topLeading, .bottomLeading:
            horizontalDelta = -translation.width
        case .topTrailing, .bottomTrailing:
            horizontalDelta = translation.width
        }

        let verticalDelta: CGFloat
        switch handle {
        case .topLeading, .topTrailing:
            verticalDelta = -translation.height * ratio
        case .bottomLeading, .bottomTrailing:
            verticalDelta = translation.height * ratio
        }

        let widthDelta = abs(horizontalDelta) >= abs(verticalDelta)
            ? horizontalDelta
            : verticalDelta

        let oppositeCorner: CGPoint
        let horizontalCapacity: CGFloat
        let verticalCapacity: CGFloat
        switch handle {
        case .topLeading:
            oppositeCorner = CGPoint(x: start.maxX, y: start.maxY)
            horizontalCapacity = oppositeCorner.x - availableBounds.minX
            verticalCapacity = (oppositeCorner.y - availableBounds.minY) * ratio
        case .topTrailing:
            oppositeCorner = CGPoint(x: start.minX, y: start.maxY)
            horizontalCapacity = availableBounds.maxX - oppositeCorner.x
            verticalCapacity = (oppositeCorner.y - availableBounds.minY) * ratio
        case .bottomLeading:
            oppositeCorner = CGPoint(x: start.maxX, y: start.minY)
            horizontalCapacity = oppositeCorner.x - availableBounds.minX
            verticalCapacity = (availableBounds.maxY - oppositeCorner.y) * ratio
        case .bottomTrailing:
            oppositeCorner = CGPoint(x: start.minX, y: start.minY)
            horizontalCapacity = availableBounds.maxX - oppositeCorner.x
            verticalCapacity = (availableBounds.maxY - oppositeCorner.y) * ratio
        }

        let maximumWidth = max(0, min(horizontalCapacity, verticalCapacity))
        let minimumAllowedWidth = min(minimumWidth, maximumWidth)
        let width = min(max(start.width + widthDelta, minimumAllowedWidth), maximumWidth)
        let height = width / ratio

        switch handle {
        case .topLeading:
            return CGRect(
                x: oppositeCorner.x - width,
                y: oppositeCorner.y - height,
                width: width,
                height: height
            )
        case .topTrailing:
            return CGRect(
                x: oppositeCorner.x,
                y: oppositeCorner.y - height,
                width: width,
                height: height
            )
        case .bottomLeading:
            return CGRect(
                x: oppositeCorner.x - width,
                y: oppositeCorner.y,
                width: width,
                height: height
            )
        case .bottomTrailing:
            return CGRect(
                x: oppositeCorner.x,
                y: oppositeCorner.y,
                width: width,
                height: height
            )
        }
    }

    private static func fittedSize(
        proposedWidth: CGFloat,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGSize {
        guard !bounds.isEmpty else { return .zero }

        let maximumWidth = max(0, min(bounds.width, bounds.height * aspectRatio))
        let minimumAllowedWidth = min(minimumWidth, maximumWidth)
        let width = min(max(proposedWidth, minimumAllowedWidth), maximumWidth)
        return CGSize(width: width, height: width / aspectRatio)
    }

    private static func availableBounds(in bounds: CGRect) -> CGRect {
        let physicalBounds = bounds.standardized
        guard physicalBounds.minX.isFinite,
              physicalBounds.minY.isFinite,
              physicalBounds.width.isFinite,
              physicalBounds.height.isFinite,
              physicalBounds.width > 0,
              physicalBounds.height > 0 else {
            return .zero
        }

        let horizontalInset = min(edgeInset, physicalBounds.width / 2)
        let verticalInset = min(edgeInset, physicalBounds.height / 2)
        let width = max(0, physicalBounds.width - horizontalInset * 2)
        let height = max(0, physicalBounds.height - verticalInset * 2)
        guard width > 0, height > 0 else { return .zero }

        return CGRect(
            x: physicalBounds.minX + horizontalInset,
            y: physicalBounds.minY + verticalInset,
            width: width,
            height: height
        )
    }

    private static func validRatio(_ aspectRatio: CGFloat) -> CGFloat {
        aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : fallbackAspectRatio
    }
}

@MainActor
final class FloatingVideoState: ObservableObject {
    @Published private(set) var isFloating = false
    @Published private(set) var frame = CGRect.zero
    @Published private(set) var videoID: UUID?

    func reset(for videoID: UUID) {
        guard self.videoID != videoID else { return }

        self.videoID = videoID
        isFloating = false
        frame = .zero
    }

    func prepareDefaultFrame(
        in bounds: CGRect,
        inlineWidth: CGFloat,
        aspectRatio: CGFloat
    ) {
        guard frame == .zero else {
            clamp(to: bounds, aspectRatio: aspectRatio)
            return
        }

        frame = VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        )
    }

    func updateVisibleFraction(_ visibleFraction: Double) {
        isFloating = VideoFloatingLayout.shouldFloat(
            isFloating: isFloating,
            visibleFraction: visibleFraction
        )
    }

    func move(
        by translation: CGSize,
        in bounds: CGRect,
        aspectRatio: CGFloat
    ) {
        setFrame(
            frame.offsetBy(dx: translation.width, dy: translation.height),
            in: bounds,
            aspectRatio: aspectRatio
        )
    }

    func setFrame(
        _ frame: CGRect,
        in bounds: CGRect,
        aspectRatio: CGFloat
    ) {
        self.frame = VideoFloatingLayout.fittedFrame(
            frame,
            aspectRatio: aspectRatio,
            in: bounds
        )
    }

    func resize(
        from frame: CGRect,
        handle: VideoResizeHandle,
        translation: CGSize,
        in bounds: CGRect,
        aspectRatio: CGFloat
    ) {
        self.frame = VideoFloatingLayout.resizedFrame(
            from: frame,
            handle: handle,
            translation: translation,
            aspectRatio: aspectRatio,
            in: bounds
        )
    }

    func clamp(to bounds: CGRect, aspectRatio: CGFloat) {
        guard frame != .zero else { return }

        setFrame(frame, in: bounds, aspectRatio: aspectRatio)
    }

    func resetPlacement(
        in bounds: CGRect,
        inlineWidth: CGFloat,
        aspectRatio: CGFloat
    ) {
        frame = VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        )
    }
}
