// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

#if LOWLIGHT_PLAYBACK_COMPARISON
    import XCTest

    final class ComparisonFailureTests: XCTestCase {
        @MainActor
        func testMissingAndInvalidModesCannotStart() {
            for value in [nil, "unknown"] as [String?] {
                let app = XCUIApplication()
                app.launchEnvironment["LOWLIGHT_COMPARISON_MODE"] = value
                app.launch()
                XCTAssertTrue(app.staticTexts["comparisonError"].waitForExistence(timeout: 10))
                XCTAssertFalse(app.buttons["comparisonStart"].isEnabled)
                XCTAssertFalse(app.buttons["comparisonPause"].isEnabled)
                app.terminate()
            }
        }

        @MainActor
        func testStopBeforeStartMakesTheTrialTerminal() {
            let app = XCUIApplication()
            app.launchEnvironment["LOWLIGHT_COMPARISON_MODE"] = "idle"
            app.launch()
            XCTAssertEqual(app.staticTexts["comparisonMode"].label, "idle")
            XCTAssertEqual(app.staticTexts["comparisonStatus"].label, "Ready")
            app.buttons["comparisonStop"].tap()
            XCTAssertEqual(app.staticTexts["comparisonStatus"].label, "Stopped")
            XCTAssertFalse(app.buttons["comparisonStart"].isEnabled)
            app.buttons["comparisonRefresh"].tap()
            XCTAssertEqual(app.staticTexts["comparisonFrames"].label, "0")
        }

        @MainActor
        func testMalformedTrialIdentifierCannotStart() {
            let app = XCUIApplication()
            app.launchEnvironment["LOWLIGHT_COMPARISON_MODE"] = "idle"
            app.launchEnvironment["LOWLIGHT_COMPARISON_TRIAL_ID"] = "bad-trial"
            app.launch()
            XCTAssertTrue(app.staticTexts["comparisonError"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["comparisonStart"].isEnabled)
        }
    }
#endif
