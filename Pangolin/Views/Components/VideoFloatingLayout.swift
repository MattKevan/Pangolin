//
//  VideoFloatingLayout.swift
//  Pangolin
//

import SwiftUI

enum VideoFloatingCoordinateSpace {
    static let root = "videoFloatingRoot"
}

enum VideoPresentationHostLayout {
    static func availableBounds(size: CGSize, insets: EdgeInsets) -> CGRect {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              insets.top.isFinite,
              insets.leading.isFinite,
              insets.bottom.isFinite,
              insets.trailing.isFinite,
              insets.top >= 0,
              insets.leading >= 0,
              insets.bottom >= 0,
              insets.trailing >= 0 else {
            return .zero
        }

        let width = size.width - insets.leading - insets.trailing
        let height = size.height - insets.top - insets.bottom
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return .zero
        }

        return CGRect(
            x: insets.leading,
            y: insets.top,
            width: width,
            height: height
        )
    }

    static func availableBounds(
        outerBounds: CGRect,
        presentationViewportFrame: CGRect?
    ) -> CGRect {
        guard isValid(outerBounds) else { return .zero }
        guard let presentationViewportFrame,
              isValid(presentationViewportFrame) else {
            return outerBounds
        }

        let minimumY = max(outerBounds.minY, presentationViewportFrame.minY)
        let maximumY = min(outerBounds.maxY, presentationViewportFrame.maxY)
        let height = maximumY - minimumY
        guard height.isFinite, height > 0 else { return .zero }

        return CGRect(
            x: outerBounds.minX,
            y: minimumY,
            width: outerBounds.width,
            height: height
        )
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

enum PhoneProjectVideoRoutePopPolicy {
    static func shouldNavigateBack(
        oldVideoRouteIDs: [UUID],
        newVideoRouteIDs: [UUID],
        selectedVideoID: UUID?,
        isVideoDetailActive: Bool
    ) -> Bool {
        guard isVideoDetailActive, let selectedVideoID else { return false }
        return oldVideoRouteIDs.contains(selectedVideoID)
            && !newVideoRouteIDs.contains(selectedVideoID)
    }
}

enum PhoneProjectVideoRouteSyncPolicy {
    enum Action: Equatable {
        case none
        case append
        case replace
    }

    static func action(
        existingVideoRouteIDs: [UUID],
        selectedVideoID: UUID
    ) -> Action {
        guard existingVideoRouteIDs.last != selectedVideoID else { return .none }
        return existingVideoRouteIDs.isEmpty ? .append : .replace
    }
}

enum VideoNavigationShell: Equatable {
    case workspace
    case phone
}

enum WorkspaceToolbarOwnership: Equatable {
    case appOwned
    case systemOwned
    case none
}

enum VideoToolbarPolicy {
    static func ownership(
        shell: VideoNavigationShell,
        isVideoDetail: Bool,
        supportsAppOwnedSidebarButton: Bool
    ) -> WorkspaceToolbarOwnership {
        guard shell == .workspace else { return .none }
        return isVideoDetail || supportsAppOwnedSidebarButton ? .appOwned : .systemOwned
    }

    static func removesSystemSidebarButton(
        shell: VideoNavigationShell,
        isVideoDetail: Bool,
        supportsAppOwnedSidebarButton: Bool
    ) -> Bool {
        ownership(
            shell: shell,
            isVideoDetail: isVideoDetail,
            supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
        ) == .appOwned
    }

    static func showsSidebarButton(
        shell: VideoNavigationShell,
        isVideoDetail: Bool,
        supportsAppOwnedSidebarButton: Bool
    ) -> Bool {
        ownership(
            shell: shell,
            isVideoDetail: isVideoDetail,
            supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
        ) == .appOwned
            && !isVideoDetail
    }

    static func showsVideoBackButton(
        shell: VideoNavigationShell,
        isVideoDetail: Bool,
        supportsAppOwnedSidebarButton: Bool
    ) -> Bool {
        ownership(
            shell: shell,
            isVideoDetail: isVideoDetail,
            supportsAppOwnedSidebarButton: supportsAppOwnedSidebarButton
        ) == .appOwned
            && isVideoDetail
    }
}

enum WorkspaceSidebarVisibilityPolicy {
    static func toggled(
        from visibility: NavigationSplitViewVisibility
    ) -> NavigationSplitViewVisibility {
        visibility == .detailOnly ? .all : .detailOnly
    }
}

enum VideoPlayerPresentationPolicy {
    static func destination(
        isFloating: Bool,
        inlineFrame: CGRect,
        floatingFrame: CGRect
    ) -> CGRect? {
        let candidate = isFloating ? floatingFrame : inlineFrame
        guard isValid(candidate) else { return nil }
        return candidate
    }

    static func shouldAnimate(from oldValue: Bool, to newValue: Bool) -> Bool {
        oldValue != newValue
    }

    static func renderedFrame(
        isFloating: Bool,
        baseFrame: CGRect,
        interactionPreviewFrame: CGRect?
    ) -> CGRect {
        guard isFloating else { return baseFrame }
        return interactionPreviewFrame ?? baseFrame
    }

    static func overlayLocalFrame(
        _ rootFrame: CGRect,
        overlayFrameInRoot: CGRect
    ) -> CGRect? {
        guard isValid(rootFrame), isValid(overlayFrameInRoot) else { return nil }
        return rootFrame.offsetBy(
            dx: -overlayFrameInRoot.minX,
            dy: -overlayFrameInRoot.minY
        )
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }
}

enum VideoResizeHandle: CaseIterable, Hashable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

enum VideoDisplayGeometry {
    static let maximumDimension: CGFloat = 1_000_000

    static func displaySize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize? {
        guard isValid(naturalSize) else { return nil }
        guard isFinite(preferredTransform) else { return naturalSize }

        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        guard isValid(transformedBounds.size) else { return naturalSize }
        return transformedBounds.size
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
            && size.width <= maximumDimension
            && size.height <= maximumDimension
    }

    private static func isFinite(_ transform: CGAffineTransform) -> Bool {
        transform.a.isFinite
            && transform.b.isFinite
            && transform.c.isFinite
            && transform.d.isFinite
            && transform.tx.isFinite
            && transform.ty.isFinite
    }
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

    static func visibleFraction(of frame: CGRect, in viewport: CGRect) -> Double {
        guard isValidMeasurement(frame), isValidMeasurement(viewport) else { return 0 }

        let visibleMinimumY = max(frame.minY, viewport.minY)
        let visibleMaximumY = min(frame.maxY, viewport.maxY)
        let visibleHeight = max(visibleMaximumY - visibleMinimumY, 0)
        guard visibleHeight.isFinite else { return 0 }

        let fraction = Double(visibleHeight / frame.size.height)
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
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
              height > 0,
              width <= Double(VideoDisplayGeometry.maximumDimension),
              height <= Double(VideoDisplayGeometry.maximumDimension) else {
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

    static func draggedFrame(
        from startFrame: CGRect,
        translation: CGSize,
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        fittedFrame(
            startFrame.offsetBy(
                dx: translation.width,
                dy: translation.height
            ),
            aspectRatio: aspectRatio,
            in: bounds
        )
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

    private static func isValidMeasurement(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width > 0
            && rect.size.height > 0
    }
}

@MainActor
final class FloatingVideoState: ObservableObject {
    @Published private(set) var isFloating = false
    @Published private(set) var frame = CGRect.zero
    @Published private(set) var videoID: UUID?
    @Published private(set) var inlineWidth: CGFloat = 0
    @Published private(set) var inlineFrame = CGRect.zero
    @Published private(set) var presentationViewportFrame = CGRect.zero
    private var latestVisibleFraction: Double?

    func reset(for videoID: UUID?) {
        guard self.videoID != videoID else {
            if videoID == nil, presentationViewportFrame != .zero {
                presentationViewportFrame = .zero
            }
            return
        }

        let preservesPresentationViewport = self.videoID != nil && videoID != nil

        self.videoID = videoID
        isFloating = false
        frame = .zero
        inlineWidth = 0
        inlineFrame = .zero
        if !preservesPresentationViewport,
           presentationViewportFrame != .zero {
            presentationViewportFrame = .zero
        }
        latestVisibleFraction = nil
    }

    func updateInlineWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0, inlineWidth != width else { return }
        inlineWidth = width
    }

    func updateInlineFrame(_ frame: CGRect) {
        guard VideoPlayerPresentationPolicy.destination(
            isFloating: false,
            inlineFrame: frame,
            floatingFrame: .zero
        ) != nil,
        inlineFrame != frame else { return }
        inlineFrame = frame
    }

    func updatePresentationViewportFrame(_ frame: CGRect) {
        let normalizedFrame = VideoPlayerPresentationPolicy.destination(
            isFloating: false,
            inlineFrame: frame,
            floatingFrame: .zero
        ) == nil ? .zero : frame
        guard presentationViewportFrame != normalizedFrame else { return }
        presentationViewportFrame = normalizedFrame
    }

    func updateVisibilityMeasurement(_ visibleFraction: Double?) {
        guard inlineWidth > 0 else { return }
        updateVisibleFraction(visibleFraction ?? 0)
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

        updateFrame(VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        ))
    }

    func prepareFloatingDestination(
        in bounds: CGRect,
        aspectRatio: CGFloat
    ) {
        prepareDefaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        )
        if frame != .zero, let latestVisibleFraction {
            applyVisibleFraction(latestVisibleFraction)
        }
    }

    func updateVisibleFraction(_ visibleFraction: Double) {
        latestVisibleFraction = visibleFraction
        applyVisibleFraction(visibleFraction)
    }

    private func applyVisibleFraction(_ visibleFraction: Double) {
        let shouldFloat = VideoFloatingLayout.shouldFloat(
            isFloating: isFloating,
            visibleFraction: visibleFraction
        )
        guard !shouldFloat || frame != .zero else { return }
        guard shouldFloat != isFloating else { return }
        isFloating = shouldFloat
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
        updateFrame(VideoFloatingLayout.fittedFrame(
            frame,
            aspectRatio: aspectRatio,
            in: bounds
        ))
    }

    func resize(
        from frame: CGRect,
        handle: VideoResizeHandle,
        translation: CGSize,
        in bounds: CGRect,
        aspectRatio: CGFloat
    ) {
        updateFrame(VideoFloatingLayout.resizedFrame(
            from: frame,
            handle: handle,
            translation: translation,
            aspectRatio: aspectRatio,
            in: bounds
        ))
    }

    func clamp(to bounds: CGRect, aspectRatio: CGFloat) {
        guard frame != .zero else { return }

        let fittedFrame = VideoFloatingLayout.fittedFrame(
            frame,
            aspectRatio: aspectRatio,
            in: bounds
        )
        guard fittedFrame != .zero else { return }
        updateFrame(fittedFrame)
    }

    func resetPlacement(
        in bounds: CGRect,
        inlineWidth: CGFloat,
        aspectRatio: CGFloat
    ) {
        updateFrame(VideoFloatingLayout.defaultFrame(
            in: bounds,
            inlineWidth: inlineWidth,
            aspectRatio: aspectRatio
        ))
    }

    private func updateFrame(_ newFrame: CGRect) {
        guard frame != newFrame else { return }
        frame = newFrame
    }
}
