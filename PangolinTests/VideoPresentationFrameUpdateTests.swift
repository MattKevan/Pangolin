import Testing
import Foundation
import Combine
import SwiftUI
import AVFoundation
@testable import Pangolin


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
