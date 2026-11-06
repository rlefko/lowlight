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
        let transport = app.buttons["playPauseButton"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(transport.label, "Play")
        XCTAssertTrue(app.buttons["nextButton"].exists)
        transport.tap()
        expectation(for: NSPredicate(format: "label == %@", "Pause"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        transport.tap()
        expectation(for: NSPredicate(format: "label == %@", "Play"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        app.buttons["aboutButton"].tap()
        XCTAssertTrue(app.navigationBars["About Lowlight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Development accelerated with Codex"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Original code: GNU General Public License v3.0 only (GPL-3.0-only)."
            ].exists)
        app.swipeUp()
        app.buttons["softwareNoticesLink"].tap()
        XCTAssertTrue(app.navigationBars["Software Notices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["softwareNoticeText"].label.contains("Melissa"))
        XCTAssertTrue(app.staticTexts["softwareNoticeText"].label.contains("NumPy Developers"))
        XCTAssertTrue(app.staticTexts["softwareNoticeText"].label.contains("Christian Steinmetz"))
        app.navigationBars["Software Notices"].buttons["About Lowlight"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["listeningStatus"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["listeningStatus"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["About Lowlight"].exists)
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Play")
    }

    @MainActor
    func testControlsPersistWithoutStartingPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let preset = app.buttons["presetPicker"]
        XCTAssertTrue(preset.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: preset)
        waitForExpectations(timeout: 10)
        preset.tap()
        app.buttons["Reflective"].tap()
        XCTAssertEqual(preset.value as? String, "Reflective")
        retainScreenshot(app, named: "Reflective listening controls")
        let more = app.buttons["moreControlsButton"]
        if !more.isHittable { app.swipeUp() }
        more.tap()
        XCTAssertTrue(app.navigationBars["Listening Controls"].waitForExistence(timeout: 5))
        let automatic = app.switches["autoTempoToggle"]
        XCTAssertEqual(automatic.value as? String, "1")
        automatic.switches.firstMatch.tap()
        XCTAssertEqual(automatic.value as? String, "0")
        let tempo = app.sliders["tempoSlider"]
        XCTAssertTrue(tempo.waitForExistence(timeout: 5))
        let originalTempoValue = try XCTUnwrap(tempo.value as? String)
        reveal(tempo, in: app)
        tempo.adjust(toNormalizedSliderPosition: 0.75)
        let tempoValue = try XCTUnwrap(tempo.value as? String)
        XCTAssertNotEqual(tempoValue, originalTempoValue)
        let spaceValue = try adjustEffect("Space", to: 0.28, in: app)
        let textureValue = try adjustEffect("Texture", to: 0.32, in: app)
        retainScreenshot(app, named: "Space and texture")
        let variation = app.sliders["variationSlider"]
        reveal(variation, in: app)
        let originalVariationValue = try XCTUnwrap(variation.value as? String)
        let variationThumb = variation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let variationTarget = variation.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        variationThumb.press(forDuration: 0.05, thenDragTo: variationTarget)
        let variationValue = try XCTUnwrap(variation.value as? String)
        XCTAssertNotEqual(variationValue, originalVariationValue)
        retainScreenshot(app, named: "Variation")
        app.buttons["Done"].tap()
        let warmthValue = try adjustEffect("Warmth", to: 0.45, in: app)
        let energy = app.sliders["energySlider"]
        let originalEnergyValue = try XCTUnwrap(energy.value as? String)
        reveal(energy, in: app)
        energy.adjust(toNormalizedSliderPosition: 0.7)
        let energyValue = try XCTUnwrap(energy.value as? String)
        XCTAssertNotEqual(energyValue, originalEnergyValue)
        let mood = app.sliders["moodSlider"]
        let originalMoodValue = try XCTUnwrap(mood.value as? String)
        reveal(mood, in: app)
        mood.adjust(toNormalizedSliderPosition: 0.8)
        let moodValue = try XCTUnwrap(mood.value as? String)
        XCTAssertNotEqual(moodValue, originalMoodValue)
        XCTAssertEqual(preset.value as? String, "Custom")
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Play")

        app.terminate()
        app.launch()
        XCTAssertTrue(preset.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: preset)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(preset.value as? String, "Custom")
        XCTAssertEqual(app.buttons["playPauseButton"].label, "Play")
        XCTAssertEqual(app.sliders["warmthSlider"].value as? String, warmthValue)
        XCTAssertEqual(energy.value as? String, energyValue)
        XCTAssertEqual(mood.value as? String, moodValue)
        reveal(energy, in: app)
        retainScreenshot(app, named: "Restored custom controls")
        if !more.isHittable { app.swipeUp() }
        more.tap()
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "0")
        XCTAssertEqual(tempo.value as? String, tempoValue)
        for (name, expected) in [
            ("spaceSlider", spaceValue), ("textureSlider", textureValue),
            ("variationSlider", variationValue),
        ] {
            let slider = app.sliders[name]
            reveal(slider, in: app)
            XCTAssertEqual(slider.value as? String, expected)
        }
        reveal(automatic, in: app, searchAbove: true)
        automatic.switches.firstMatch.tap()
        XCTAssertEqual(automatic.value as? String, "1")
        XCTAssertFalse(tempo.exists)
        retainScreenshot(app, named: "Automatic tempo")
        app.buttons["Done"].tap()
    }

    @MainActor
    private func adjustEffect(_ name: String, to position: CGFloat, in app: XCUIApplication) throws
        -> String
    {
        let slider = app.sliders[name.lowercased() + "Slider"]
        reveal(slider, in: app)
        XCTAssertEqual(slider.label, name)
        let original = try XCTUnwrap(slider.value as? String)
        slider.adjust(toNormalizedSliderPosition: position)
        let changed = try XCTUnwrap(slider.value as? String)
        XCTAssertNotEqual(original, changed)
        return changed
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, searchAbove: Bool = false)
    {
        let bounds = app.frame
        let visible = CGRect(
            x: bounds.minX, y: bounds.minY + 160,
            width: bounds.width, height: bounds.height - 220)
        for _ in 0..<6 {
            if !element.exists {
                // Offscreen Form rows can leave the accessibility tree entirely.
                if searchAbove { app.swipeDown() } else { app.swipeUp() }
                continue
            }
            let frame = element.frame
            if element.isHittable, visible.contains(frame) { return }
            if frame.midY > visible.midY { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func retainScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
