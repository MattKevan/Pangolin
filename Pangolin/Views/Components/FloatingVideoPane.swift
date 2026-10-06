//
//  FloatingVideoPane.swift
//  Pangolin
//

import SwiftUI

enum VideoFloatingMovementDirection {
    case left
    case right
    case up
    case down
}

enum VideoFloatingMovement {
    static let step: CGFloat = 10

    static func translation(for direction: VideoFloatingMovementDirection) -> CGSize {
        switch direction {
        case .left:
            return CGSize(width: -step, height: 0)
        case .right:
            return CGSize(width: step, height: 0)
        case .up:
            return CGSize(width: 0, height: -step)
        case .down:
            return CGSize(width: 0, height: step)
        }
    }
}

struct FloatingVideoPane: View {
    let video: Video
    let playerViewModel: VideoPlayerViewModel
    @ObservedObject var floatingState: FloatingVideoState
    @ObservedObject var frameController: VideoPresentationFrameController
    let dockedFrame: CGRect
    let availableBounds: CGRect

    @State private var interactionStartFrame: CGRect?
    @State private var interactionPreviewFrame: CGRect?
    @FocusState private var isFocused: Bool

    private var mode: VideoPresentationMode {
        floatingState.isFloating ? .floating : .docked
    }

    private var destination: CGRect {
        floatingState.isFloating ? floatingState.frame : dockedFrame
    }

    private var renderedFrame: CGRect {
        VideoPlayerPresentationPolicy.renderedFrame(
            isFloating: floatingState.isFloating,
            baseFrame: frameController.frame ?? destination,
            interactionPreviewFrame: interactionPreviewFrame
        )
    }

    var body: some View {
        VideoPlayerWithPosterView(video: video, viewModel: playerViewModel)
            .frame(width: renderedFrame.width, height: renderedFrame.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .top) {
                if floatingState.isFloating {
                    dragHandle
                }
            }
            .overlay(alignment: .topTrailing) {
                if floatingState.isFloating {
                    resetButton
                }
            }
            .overlay {
                if floatingState.isFloating {
                    resizeHandles
                }
            }
            .shadow(
                color: floatingState.isFloating ? .black.opacity(0.28) : .clear,
                radius: floatingState.isFloating ? 18 : 0,
                y: floatingState.isFloating ? 8 : 0
            )
            .position(x: renderedFrame.midX, y: renderedFrame.midY)
            .macOSKeyboardControls(
                isFloating: floatingState.isFloating,
                isFocused: $isFocused,
                moveAction: moveFloatingPane
            )
            .onAppear {
                updatePresentation(isInteracting: false)
            }
            .onChange(of: floatingState.isFloating) { _, isFloating in
                if !isFloating {
                    clearInteraction()
                }
                updatePresentation(isInteracting: false)
            }
            .onChange(of: destination) { _, _ in
                updatePresentation(isInteracting: false)
            }
            .onDisappear {
                clearInteraction()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                floatingState.isFloating ? "Floating video player" : "Video player"
            )
            .accessibilityValue(accessibilityFrameValue)
            .floatingMovementAccessibilityActions(
                isFloating: floatingState.isFloating,
                moveAction: moveFloatingPane
            )
            .floatingResetAccessibilityAction(
                isFloating: floatingState.isFloating,
                action: resetPlacement
            )
    }

    private var accessibilityFrameValue: String {
        "Position \(Int(renderedFrame.minX)), \(Int(renderedFrame.minY)); width \(Int(renderedFrame.width))"
    }

    private var dragHandle: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.85))
                    .frame(width: 44, height: 5)
            }
            .frame(width: 76, height: 44)
            .padding(.top, 6)
            .contentShape(Rectangle())
            .macOSHelp("Drag to move the floating video")
            .accessibilityLabel("Move floating video")
            .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                focusFloatingPane()
                let start = interactionStartFrame ?? floatingState.frame
                interactionStartFrame = start
                interactionPreviewFrame = VideoFloatingLayout.draggedFrame(
                    from: start,
                    translation: value.translation,
                    aspectRatio: playerViewModel.videoAspectRatio,
                    in: availableBounds,
                )
            }
            .onEnded { _ in
                commitInteraction()
            }
    }

    private var resizeHandles: some View {
        ZStack {
            resizeHandle(.topLeading, alignment: .topLeading)
            resizeHandle(.topTrailing, alignment: .topTrailing)
            resizeHandle(.bottomLeading, alignment: .bottomLeading)
            resizeHandle(.bottomTrailing, alignment: .bottomTrailing)
        }
    }

    private var resetButton: some View {
        Button(action: resetPlacement) {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.trailing, 52)
        .macOSResetShortcut()
        .macOSHelp("Reset floating video position (Command-Option-0)")
        .accessibilityLabel("Reset floating video position")
    }

    private func resizeHandle(
        _ handle: VideoResizeHandle,
        alignment: Alignment
    ) -> some View {
        Circle()
            .fill(.white)
            .overlay {
                Circle().stroke(.black.opacity(0.35), lineWidth: 1)
            }
            .frame(width: 14, height: 14)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .accessibilityLabel(accessibilityLabel(for: handle))
            .accessibilityHint("Adjust to resize while preserving the video's aspect ratio")
            .accessibilityAdjustableAction { direction in
                resizeWithAccessibility(handle, direction: direction)
            }
            .gesture(resizeGesture(for: handle))
    }

    private func resizeGesture(for handle: VideoResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                focusFloatingPane()
                let start = interactionStartFrame ?? floatingState.frame
                interactionStartFrame = start
                interactionPreviewFrame = VideoFloatingLayout.resizedFrame(
                    from: start,
                    handle: handle,
                    translation: value.translation,
                    aspectRatio: playerViewModel.videoAspectRatio,
                    in: availableBounds
                )
            }
            .onEnded { _ in
                commitInteraction()
            }
    }

    private func commitInteraction() {
        if let interactionPreviewFrame {
            floatingState.setFrame(
                interactionPreviewFrame,
                in: availableBounds,
                aspectRatio: playerViewModel.videoAspectRatio
            )
            updatePresentation(isInteracting: true)
        }
        interactionStartFrame = nil
        interactionPreviewFrame = nil
    }

    private func accessibilityLabel(for handle: VideoResizeHandle) -> String {
        switch handle {
        case .topLeading:
            return "Resize floating video from top left"
        case .topTrailing:
            return "Resize floating video from top right"
        case .bottomLeading:
            return "Resize floating video from bottom left"
        case .bottomTrailing:
            return "Resize floating video from bottom right"
        }
    }

    private func resizeWithAccessibility(
        _ handle: VideoResizeHandle,
        direction: AccessibilityAdjustmentDirection
    ) {
        let growsWithPositiveTranslation = handle == .topTrailing || handle == .bottomTrailing
        let translation: CGFloat
        switch direction {
        case .increment:
            translation = growsWithPositiveTranslation ? 10 : -10
        case .decrement:
            translation = growsWithPositiveTranslation ? -10 : 10
        @unknown default:
            return
        }

        floatingState.resize(
            from: floatingState.frame,
            handle: handle,
            translation: CGSize(width: translation, height: 0),
            in: availableBounds,
            aspectRatio: playerViewModel.videoAspectRatio
        )
        updatePresentation(isInteracting: true)
    }

    private func resetPlacement() {
        guard floatingState.isFloating else { return }
        floatingState.resetPlacement(
            in: availableBounds,
            inlineWidth: dockedFrame.width,
            aspectRatio: playerViewModel.videoAspectRatio
        )
        updatePresentation(isInteracting: true)
    }

    private func updatePresentation(isInteracting: Bool) {
        guard VideoPlayerPresentationPolicy.destination(
            isFloating: mode == .floating,
            inlineFrame: destination,
            floatingFrame: destination
        ) != nil else { return }
        guard frameController.frame != destination || frameController.mode != mode else { return }

        let decision = VideoPresentationFrameUpdatePolicy.decision(
            previousMode: frameController.mode,
            newMode: mode,
            hasPresentedFrame: frameController.frame != nil,
            isTransitioning: frameController.isTransitioning,
            isInteracting: isInteracting
        )
        frameController.apply(
            destination: destination,
            mode: mode,
            animated: decision == .animated
        )
    }

    private func clearInteraction() {
        interactionStartFrame = nil
        interactionPreviewFrame = nil
        #if os(macOS)
        isFocused = false
        #endif
    }

    private func focusFloatingPane() {
        #if os(macOS)
        isFocused = true
        #endif
    }

    private func moveFloatingPane(_ direction: VideoFloatingMovementDirection) {
        guard floatingState.isFloating else { return }

        floatingState.move(
            by: VideoFloatingMovement.translation(for: direction),
            in: availableBounds,
            aspectRatio: playerViewModel.videoAspectRatio
        )
        updatePresentation(isInteracting: true)
    }
}

private extension View {
    @ViewBuilder
    func macOSKeyboardControls(
        isFloating: Bool,
        isFocused: FocusState<Bool>.Binding,
        moveAction: @escaping (VideoFloatingMovementDirection) -> Void
    ) -> some View {
        #if os(macOS)
        focusable(isFloating)
            .focused(isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    moveAction(.left)
                case .right:
                    moveAction(.right)
                case .up:
                    moveAction(.up)
                case .down:
                    moveAction(.down)
                @unknown default:
                    break
                }
            }
        #else
        self
        #endif
    }

    @ViewBuilder
    func macOSHelp(_ text: String) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
        #endif
    }

    @ViewBuilder
    func macOSResetShortcut() -> some View {
        #if os(macOS)
        keyboardShortcut("0", modifiers: [.command, .option])
        #else
        self
        #endif
    }

    @ViewBuilder
    func floatingResetAccessibilityAction(
        isFloating: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isFloating {
            accessibilityAction(named: "Reset position", action)
        } else {
            self
        }
    }

    @ViewBuilder
    func floatingMovementAccessibilityActions(
        isFloating: Bool,
        moveAction: @escaping (VideoFloatingMovementDirection) -> Void
    ) -> some View {
        if isFloating {
            accessibilityAction(named: "Move left") {
                moveAction(.left)
            }
            .accessibilityAction(named: "Move right") {
                moveAction(.right)
            }
            .accessibilityAction(named: "Move up") {
                moveAction(.up)
            }
            .accessibilityAction(named: "Move down") {
                moveAction(.down)
            }
        } else {
            self
        }
    }
}
