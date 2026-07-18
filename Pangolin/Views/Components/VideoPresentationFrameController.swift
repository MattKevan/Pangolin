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
final class VideoPresentationFrameController: ObservableObject {
    static let transitionDuration = 0.25

    @Published private(set) var frame: CGRect?
    @Published private(set) var mode: VideoPresentationMode?
    @Published private(set) var isTransitioning = false

    private var transitionTask: Task<Void, Never>?

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

        transitionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.transitionDuration))
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
        withTransaction(transaction) {
            frame = nil
            mode = nil
            isTransitioning = false
        }
    }
}
