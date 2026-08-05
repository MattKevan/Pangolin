//
//  PangolinUITestsLaunchTests.swift
//  PangolinUITests
//
//  Created by Matt Kevan on 16/08/2025.
//

import XCTest

final class PangolinUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app process must actually launch for this configuration.
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.state == .runningForeground, "App did not reach running state")
        app.terminate()
    }
}
