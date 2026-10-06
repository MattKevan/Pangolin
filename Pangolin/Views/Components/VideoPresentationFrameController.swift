//
//  VideoPresentationFrameController.swift
//  Pangolin
//

import SwiftUI

enum VideoPresentationMode: Equatable {
    case docked
    case floating
}

enum VideoPresentationFrameUpdateDecision: Equatable {
    case direct
    case animated
}

enum VideoPresentationFrameUpdatePolicy {
    static func decision(
        previousMode: VideoPresentationMode?,
        newMode: VideoPresentationMode,
        hasPresentedFrame: Bool,
        isTransitioning: Bool = false,
        isInteracting: Bool = false
    ) -> VideoPresentationFrameUpdateDecision {
        guard hasPresentedFrame, !isInteracting else { return .direct }
        return previousMode != newMode || isTransitioning ? .animated : .direct
    }
}

@MainActor
@Observable
final class VideoPresentationFrameController {
    static let transitionDuration = 0.25

    typealias TransitionSleep = @MainActor (TimeInterval) async throws -> Void

    private(set) var frame: CGRect?
    private(set) var mode: VideoPresentationMode?
    private(set) var isTransitioning = false

    private let sleep: TransitionSleep
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    init(sleep: @escaping TransitionSleep = { duration in
        try await Task.sleep(for: .seconds(duration))
    }) {
        self.sleep = sleep
    }

    func apply(
        destination: CGRect,
        mode: VideoPresentationMode,
        animated: Bool
    ) {
        transitionTask?.cancel()
        transitionTask = nil

        guard animated else {
            var transaction = Transaction()
            transaction.animation = nil
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                frame = destination
                self.mode = mode
                isTransitioning = false
            }
            return
        }

        isTransitioning = true
        withAnimation(.smooth(duration: Self.transitionDuration)) {
            frame = destination
            self.mode = mode
        }

        let sleep = sleep
        transitionTask = Task { [weak self, sleep] in
            do {
                try await sleep(Self.transitionDuration)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.isTransitioning = false
            self?.transitionTask = nil
        }
    }

    func reset() {
        transitionTask?.cancel()
        transitionTask = nil

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            frame = nil
            mode = nil
            isTransitioning = false
        }
    }
}
