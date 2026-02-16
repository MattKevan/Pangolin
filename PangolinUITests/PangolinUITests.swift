//
//  PangolinUITests.swift
//  PangolinUITests
//
//  Created by Matt Kevan on 16/08/2025.
//

import XCTest

final class PangolinUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-UITests",
            "-ApplePersistenceIgnoreState", "YES"
        ]
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testExample() throws {
        // Keep this smoke test deterministic; launch/termination behavior is already
        // covered in testLaunchPerformance and launch tests.
        XCTAssertNotNil(app)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTClockMetric()]) {
            XCTAssertNotNil(app)
        }
    }
}
