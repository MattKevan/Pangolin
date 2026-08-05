import Testing
import Foundation
import Combine
import SwiftUI
import AVFoundation
@testable import Pangolin


struct VideoPresentationHostLayoutTests {
    @Test("Available bounds subtract safe-area insets")
    func subtractsSafeAreaInsets() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 390, height: 844),
            insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        ) == CGRect(x: 0, y: 59, width: 390, height: 751))
    }

    @Test("Oversized safe-area insets produce empty bounds")
    func rejectsOversizedInsets() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 100, height: 100),
            insets: EdgeInsets(top: 80, leading: 60, bottom: 30, trailing: 60)
        ) == .zero)
    }

    @Test("Safe-area bounds at or below two edge insets are unusable")
    func rejectsSafeAreaBoundsWithoutPositiveInsetArea() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 32, height: 100),
            insets: EdgeInsets()
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 40, height: 40),
            insets: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        ) == .zero)
    }

    @Test("Safe-area bounds above two edge insets remain usable")
    func acceptsSafeAreaBoundsWithPositiveInsetArea() {
        #expect(VideoPresentationHostLayout.availableBounds(
            size: CGSize(width: 33, height: 33),
            insets: EdgeInsets()
        ) == CGRect(x: 0, y: 0, width: 33, height: 33))
    }

    @Test("Detail viewport excludes the sidebar while retaining inspector-side width")
    func excludesSidebarAndRetainsInspectorWidth() {
        let outerBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(x: 260, y: 60, width: 700, height: 700)
        ) == CGRect(x: 260, y: 60, width: 940, height: 700))
    }

    @Test("Invalid detail viewport falls back to outer safe bounds")
    func invalidViewportFallsBack() {
        let outerBounds = CGRect(x: 0, y: 59, width: 390, height: 751)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(
                x: 0,
                y: CGFloat.nan,
                width: 390,
                height: 700
            )
        ) == outerBounds)
    }

    @Test("Missing detail viewport falls back to outer safe bounds")
    func missingViewportFallsBack() {
        let outerBounds = CGRect(x: 0, y: 59, width: 390, height: 751)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: nil
        ) == outerBounds)
    }

    @Test("Missing viewport only falls back to pane-usable outer bounds")
    func missingViewportRejectsUnusableOuterBounds() {
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 32, height: 100),
            presentationViewportFrame: nil
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 33, height: 33),
            presentationViewportFrame: nil
        ) == CGRect(x: 0, y: 0, width: 33, height: 33))
    }

    @Test("Detail viewport disjoint on either horizontal side produces empty bounds")
    func horizontallyDisjointViewportIsEmpty() {
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            presentationViewportFrame: CGRect(x: 1300, y: 60, width: 700, height: 700)
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            presentationViewportFrame: CGRect(x: -700, y: 60, width: 600, height: 700)
        ) == .zero)
    }

    @Test("Viewport intersection must leave positive area inside pane edge insets")
    func viewportIntersectionRequiresPositiveInsetArea() {
        let outerBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(x: 1168, y: 60, width: 100, height: 700)
        ) == .zero)
        #expect(VideoPresentationHostLayout.availableBounds(
            outerBounds: outerBounds,
            presentationViewportFrame: CGRect(x: 1167, y: 60, width: 100, height: 700)
        ) == CGRect(x: 1167, y: 60, width: 33, height: 700))
    }
}


@Suite("Phone video route pop policy")
struct PhoneVideoRoutePopPolicyTests {
    @Test("Popping an active collection video route unwinds the store detail")
    func removedVideoRouteNavigatesBack() {
        let videoID = UUID()

        #expect(PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [videoID],
            newVideoRouteIDs: [],
            selectedVideoID: videoID,
            isVideoDetailActive: true
        ))
    }

    @Test("A steady active video route leaves store detail unchanged")
    func steadyVideoRouteDoesNotNavigateBack() {
        let videoID = UUID()

        #expect(!PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [videoID],
            newVideoRouteIDs: [videoID],
            selectedVideoID: videoID,
            isVideoDetailActive: true
        ))
    }

    @Test("Removing a different video route does not unwind the active detail")
    func unrelatedVideoRouteDoesNotNavigateBack() {
        let selectedVideoID = UUID()

        #expect(!PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [UUID()],
            newVideoRouteIDs: [],
            selectedVideoID: selectedVideoID,
            isVideoDetailActive: true
        ))
    }

    @Test("Programmatic route removal for an inactive origin does not behave like native Back")
    func inactiveOriginRemovalDoesNotNavigateBack() {
        let videoID = UUID()

        #expect(!PhoneVideoRoutePopPolicy.shouldNavigateBack(
            oldVideoRouteIDs: [videoID],
            newVideoRouteIDs: [],
            selectedVideoID: videoID,
            isVideoDetailActive: false
        ))
    }
}


@Suite("Phone video route sync policy")
struct PhoneVideoRouteSyncPolicyTests {
    @Test("Selecting the first collection video appends a route")
    func firstCollectionVideoAppendsRoute() {
        #expect(PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: [],
            selectedVideoID: UUID()
        ) == .append)
    }

    @Test("Selecting another search result replaces the existing terminal video route")
    func nextVideoReplacesRoute() {
        let oldVideoID = UUID()
        let newVideoID = UUID()

        #expect(PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: [oldVideoID],
            selectedVideoID: newVideoID
        ) == .replace)
    }

    @Test("Selecting the routed video again does not duplicate it")
    func selectedRouteIsNotDuplicated() {
        let videoID = UUID()

        #expect(PhoneVideoRouteSyncPolicy.action(
            existingVideoRouteIDs: [videoID],
            selectedVideoID: videoID
        ) == .none)
    }
}


@Suite("Phone video route deactivation policy")
struct PhoneVideoRouteDeactivationPolicyTests {
    @Test("Deactivating a tab removes its stale video route")
    func activeRouteIsRemoved() {
        #expect(PhoneVideoRouteDeactivationPolicy.action(
            existingVideoRouteIDs: [UUID()]
        ) == .removeVideoRoutes)
    }

    @Test("Deactivating a root tab leaves its path unchanged")
    func rootPathIsUnchanged() {
        #expect(PhoneVideoRouteDeactivationPolicy.action(
            existingVideoRouteIDs: []
        ) == .none)
    }

    @Test("Removing a project video route preserves the project route")
    func projectRouteIsPreserved() {
        let projectID = UUID()

        #expect(PhoneProjectsPathPolicy.removingVideoRoutes(from: [
            .project(projectID),
            .video(UUID())
        ]) == [.project(projectID)])
    }
}
