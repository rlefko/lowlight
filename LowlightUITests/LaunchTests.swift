// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchAndAboutRoundTrip() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Lowlight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["listeningStatus"].exists)
        app.buttons["aboutButton"].tap()
        XCTAssertTrue(app.navigationBars["About Lowlight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Development accelerated with Codex"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Original code: GNU General Public License v3.0 only (GPL-3.0-only)."
            ].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["listeningStatus"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["listeningStatus"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["About Lowlight"].exists)
    }
}
