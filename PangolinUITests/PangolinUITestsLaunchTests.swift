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

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        XCTAssertNotNil(app)
    }
}
