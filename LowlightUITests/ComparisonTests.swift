// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@MainActor
final class ComparisonTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.rlefko.lowlight.profile")

    private func launch(_ mode: String) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOWLIGHT_COMPARISON_REHEARSAL"] == "1",
            "Run the staged playback comparison rehearsal explicitly")
        continueAfterFailure = false
        app.launchEnvironment["LOWLIGHT_COMPARISON_MODE"] = mode
        app.launch()
    }

    private func expectState(_ state: String) {
        let status = app.staticTexts["comparisonStatus"]
        let terminal = NSPredicate(format: "label IN %@", [state, "Failed"])
        expectation(for: terminal, evaluatedWith: status)
        waitForExpectations(timeout: 90)
        let error = app.staticTexts["comparisonError"]
        XCTAssertEqual(status.label, state, error.exists ? error.label : status.debugDescription)
    }

    private func frames() throws -> Int {
        app.buttons["comparisonRefresh"].tap()
        return try XCTUnwrap(Int(app.staticTexts["comparisonFrames"].label))
    }

    private func playback(_ mode: String) throws {
        try launch(mode)
        try expectSilentLaunch()
        app.buttons["comparisonStart"].tap()
        expectState("Playing")
        let first = try frames()
        Thread.sleep(forTimeInterval: 1)
        let second = try frames()
        XCTAssertGreaterThan(second, first)
        app.buttons["comparisonPause"].tap()
        expectState("Paused")
        let paused = try frames()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try frames(), paused)
        app.buttons["comparisonStart"].tap()
        expectState("Playing")
        Thread.sleep(forTimeInterval: 1)
        let resumed = try frames()
        XCTAssertGreaterThan(resumed, paused)
        app.buttons["comparisonStop"].tap()
        expectState("Stopped")
        let stopped = try frames()
        XCTAssertGreaterThanOrEqual(stopped, resumed)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try frames(), stopped)
        attach(
            "\(mode) canonical frames: first \(first), second \(second), paused \(paused), resumed \(resumed), stopped \(stopped)"
        )
        app.terminate()
        app.launch()
        try expectSilentLaunch()
    }

    private func expectSilentLaunch() throws {
        expectState("Ready")
        XCTAssertEqual(try frames(), 0)
    }

    private func attach(_ text: String) {
        let evidence = XCTAttachment(string: text)
        evidence.name = "Observed comparison frames"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testGeneratorPlayback() throws {
        try playback("generator")
    }

    func testAACPlayback() throws {
        try playback("aac")
    }

    func testIdle() throws {
        try launch("idle")
        try expectSilentLaunch()
        app.buttons["comparisonStart"].tap()
        expectState("Running")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try frames(), 0)
        app.buttons["comparisonStop"].tap()
        expectState("Stopped")
        XCTAssertEqual(try frames(), 0)
        attach("idle canonical frames: running 0, stopped 0")
        app.terminate()
        app.launch()
        try expectSilentLaunch()
    }

    private func expectFailure(_ mode: String) throws {
        try launch(mode)
        if app.buttons["comparisonStart"].isEnabled {
            app.buttons["comparisonStart"].tap()
        }
        expectState("Failed")
        XCTAssertFalse(app.staticTexts["comparisonError"].label.isEmpty)
        XCTAssertEqual(app.staticTexts["comparisonFrames"].label, "0")
    }

    func testUnavailableFixture() throws {
        try expectFailure("aac")
    }

    func testCorruptFixture() throws {
        try expectFailure("aac")
    }

    func testInvalidMode() throws {
        try expectFailure("unexpected")
    }
}
