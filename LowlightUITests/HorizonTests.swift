// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import OSLog
import XCTest

@MainActor
final class HorizonTests: XCTestCase {
    private let app = XCUIApplication()

    func testPlayingAccessibility() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOWLIGHT_VISUAL_EVIDENCE"] == "1",
            "Audit audible playback in the Release simulator run")
        try beginPlayback()
        XCTAssertTrue(app.buttons["nextButton"].wait(for: \.isEnabled, toEqual: true, timeout: 30))
        try app.performAccessibilityAudit(for: [
            .contrast, .hitRegion, .sufficientElementDescription, .textClipped, .dynamicType,
        ])
    }

    func testVisualPlaybackCost() throws {
        guard let mode = ProcessInfo.processInfo.environment["LOWLIGHT_VISUAL_TRIAL"] else {
            throw XCTSkip("Run the paired visual measurements explicitly")
        }
        continueAfterFailure = false
        XCTAssertTrue(["animated", "static"].contains(mode))
        if mode == "static" { app.launchEnvironment["LOWLIGHT_VISUAL_STATIC"] = "1" }
        app.launchEnvironment["LOWLIGHT_VISUAL_GATE_TRACE"] = "1"
        let logger = Logger(subsystem: "com.rlefko.lowlight", category: "HorizonEvidence")
        try beginPlayback()
        let options = XCTMeasureOptions()
        // XCTest runs one warmup followed by one measured window on this same passage.
        options.iterationCount = 1
        logger.notice("begin cost \(mode, privacy: .public)")
        measure(
            metrics: [
                XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
            ],
            options: options
        ) {
            Thread.sleep(forTimeInterval: 30)
        }
        logger.notice("end cost \(mode, privacy: .public)")
        XCTAssertEqual(app.staticTexts["listeningStatus"].label, "Playing")
    }

    @MainActor
    func testHorizonVisibility() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOWLIGHT_VISUAL_EVIDENCE"] == "1",
            "Run explicitly with a simulator log stream for visual measurements.")
        continueAfterFailure = false
        let app = XCUIApplication()
        let logger = Logger(subsystem: "com.rlefko.lowlight", category: "HorizonEvidence")
        let device = XCUIDevice.shared
        let originalOrientation = device.orientation
        defer { device.orientation = originalOrientation }
        device.orientation = .landscapeLeft
        app.launchEnvironment["LOWLIGHT_VISUAL_TRACE"] = "1"

        func window(_ name: String) {
            // Exclude transition invalidations, then measure a fixed interval in both processes.
            Thread.sleep(forTimeInterval: 0.8)
            logger.notice("begin \(name, privacy: .public)")
            Thread.sleep(forTimeInterval: 3)
            logger.notice("end \(name, privacy: .public)")
        }
        func scrollToTop() {
            let scroll = app.scrollViews.firstMatch
            // Keep the finger inside the scrollable margin, away from sliders and system edges.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.80))
            for _ in 0..<3 {
                start.press(forDuration: 0.06, thenDragTo: end)
            }
        }
        func startPlayback() {
            app.launch()
            let play = app.buttons["playPauseButton"]
            XCTAssertTrue(play.waitForExistence(timeout: 12))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play)
            waitForExpectations(timeout: 10)
            play.tap()
            expectation(
                for: NSPredicate(format: "label == %@", "Playing"),
                evaluatedWith: app.staticTexts["listeningStatus"])
            waitForExpectations(timeout: 90)
        }

        startPlayback()
        window("active")
        app.buttons["aboutButton"].tap()
        XCTAssertTrue(app.navigationBars["About Lowlight"].waitForExistence(timeout: 5))
        window("about")
        app.buttons["Done"].tap()
        window("afterAbout")
        app.buttons["moreControlsButton"].tap()
        XCTAssertTrue(app.navigationBars["Listening Controls"].waitForExistence(timeout: 5))
        window("controls")
        app.buttons["Done"].tap()
        window("offscreen")
        scrollToTop()
        window("afterScroll")
        device.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        window("background")
        app.activate()
        XCTAssertTrue(app.buttons["playPauseButton"].waitForExistence(timeout: 5))
        window("foreground")
        app.buttons["playPauseButton"].tap()
        expectation(
            for: NSPredicate(format: "label == %@", "Play"),
            evaluatedWith: app.buttons["playPauseButton"])
        waitForExpectations(timeout: 5)
        window("paused")
        app.terminate()

        for (key, name) in [
            ("LOWLIGHT_VISUAL_LOW_POWER", "lowPower"),
            ("LOWLIGHT_VISUAL_REDUCE_MOTION", "reduceMotion"),
            ("LOWLIGHT_VISUAL_STATIC", "disabled"),
        ] {
            app.launchEnvironment[key] = "1"
            startPlayback()
            window(name)
            app.terminate()
            app.launchEnvironment.removeValue(forKey: key)
        }
    }

    private func beginPlayback() throws {
        continueAfterFailure = false
        app.launch()
        let button = app.buttons["playPauseButton"]
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        button.tap()
        XCTAssertTrue(
            app.staticTexts["listeningStatus"].wait(for: \.label, toEqual: "Playing", timeout: 180))
    }

}
