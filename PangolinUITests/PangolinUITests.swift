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
            // Ignore saved window state so each run starts from a known layout.
            "-ApplePersistenceIgnoreState", "YES"
        ]
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// End-to-end smoke: the app must launch, render a window, and reach a
    /// deterministic UI surface (the library sidebar, or the startup error
    /// surface) within the startup budget — without crashing.
    @MainActor
    func testAppLaunchesToLibraryUI() throws {
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 30),
            "App window did not appear after launch"
        )

        let sidebarProjects = app.descendants(matching: .any)["sidebar-projects"]
        let sidebarAppeared = sidebarProjects.waitForExistence(timeout: 30)
        if !sidebarAppeared {
            // A first run in a fresh container may surface the startup/error
            // view instead of the library — both prove the app rendered.
            let startupError = app.staticTexts["Couldn't Open Library"]
            XCTAssertTrue(
                startupError.waitForExistence(timeout: 15),
                "App rendered neither the library sidebar nor the startup surface"
            )
        }
    }

    /// Real launch measurement: every iteration starts and terminates the app.
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTClockMetric()]) {
            app.launch()
            app.terminate()
        }
    }
}
