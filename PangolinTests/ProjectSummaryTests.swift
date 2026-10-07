import Testing
@testable import Pangolin

struct ProjectSummaryTests {
    @Test("Durations read in hours and minutes")
    func durations() {
        #expect(ProjectSummary.duration(0) == "0 min")
        #expect(ProjectSummary.duration(20) == "1 min")
        #expect(ProjectSummary.duration(45 * 60) == "45 min")
        #expect(ProjectSummary.duration(3600) == "1 hr")
        #expect(ProjectSummary.duration(23 * 3600 + 5 * 60) == "23 hr 5 min")
    }

    @Test("The stats line pluralises the video count")
    func statsLine() {
        #expect(ProjectSummary.stats(videoCount: 1, duration: 3600) == "1 video • 1 hr")
        #expect(ProjectSummary.stats(videoCount: 21, duration: 23 * 3600) == "21 videos • 23 hr")
        #expect(ProjectSummary.stats(videoCount: 0, duration: 0) == "0 videos • 0 min")
    }
}
