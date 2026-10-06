import Testing
@testable import Pangolin

struct ActivityIndicatorPolicyTests {
    private func presentation(
        active: Int = 0,
        failedTasks: Int = 0,
        transferIssues: Int = 0,
        progress: Double? = nil
    ) -> ActivityIndicatorPolicy.Presentation? {
        ActivityIndicatorPolicy.presentation(
            activeCount: active,
            failedTaskCount: failedTasks,
            transferIssueCount: transferIssues,
            progress: progress
        )
    }

    @Test("The widget is hidden when nothing is running and nothing failed")
    func hiddenWhenIdle() {
        #expect(presentation() == nil)
    }

    @Test("Running work with known progress shows a ring")
    func ringWhenProgressIsKnown() {
        #expect(presentation(active: 1, progress: 0.4) == .init(style: .progress(0.4), badgeCount: 0))
    }

    @Test("Progress is kept within zero and one")
    func progressIsClamped() {
        #expect(presentation(active: 1, progress: 1.7)?.style == .progress(1))
        #expect(presentation(active: 1, progress: -0.2)?.style == .progress(0))
    }

    @Test("Running work with unknown progress shows a spinner")
    func spinnerWhenProgressIsUnknown() {
        #expect(presentation(active: 2)?.style == .spinner)
    }

    @Test("Only failures show a warning")
    func warningWhenOnlyFailures() {
        #expect(presentation(failedTasks: 1)?.style == .warning)
        #expect(presentation(transferIssues: 2)?.style == .warning)
    }

    @Test("The badge counts the work beyond the first item")
    func badgeCountsExtraWork() {
        #expect(presentation(active: 1, progress: 0.1)?.badgeCount == 0)
        #expect(presentation(active: 3, progress: 0.1)?.badgeCount == 2)
    }

    @Test("Problems take over the badge from the work count")
    func issuesTakeOverTheBadge() {
        #expect(presentation(active: 3, failedTasks: 1, transferIssues: 2, progress: 0.5)?.badgeCount == 3)
    }
}
