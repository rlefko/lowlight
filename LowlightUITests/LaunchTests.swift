// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchAndAboutRoundTrip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LOWLIGHT_COMPARISON_MODE"] = "generator"
        app.launch()

        XCTAssertFalse(app.buttons["comparisonStart"].exists)
        XCTAssertTrue(app.navigationBars["Lowlight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["listeningStatus"].exists)
        let transport = app.buttons["playPauseButton"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(transport.label, "Play")
        XCTAssertTrue(app.buttons["nextButton"].exists)
        retainScreenshot(app, named: "Listening at rest")
        try audit(app, disabledNext: app.buttons["nextButton"])
        transport.tap()
        expectation(for: NSPredicate(format: "label == %@", "Pause"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        retainScreenshot(app, named: "Playback requested")
        transport.tap()
        expectation(for: NSPredicate(format: "label == %@", "Play"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        app.buttons["aboutButton"].tap()
        XCTAssertTrue(app.navigationBars["About Lowlight"].waitForExistence(timeout: 5))
        retainScreenshot(app, named: "About Lowlight")
        let credit = app.staticTexts["Development accelerated with Codex"]
        reveal(credit, in: app)
        let license = app.staticTexts[
            "Original code: GNU General Public License v3.0 only (GPL-3.0-only)."]
        reveal(license, in: app)
        let notices = app.buttons["softwareNoticesLink"]
        reveal(notices, in: app)
        notices.tap()
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
        if !more.isHittable { reveal(more, in: app) }
        more.tap()
        XCTAssertTrue(app.navigationBars["Listening Controls"].waitForExistence(timeout: 5))
        let automatic = app.switches["autoTempoToggle"]
        XCTAssertEqual(automatic.value as? String, "1")
        // Audit a freshly presented sheet before the tempo toggle replaces its form rows.
        try audit(app)
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
        drag(variation, to: 0.2)
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
        if !more.isHittable { reveal(more, in: app) }
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
    private func audit(_ app: XCUIApplication, disabledNext: XCUIElement? = nil) throws {
        try app.performAccessibilityAudit(for: .contrast) { issue in
            // UIKit dims the unavailable button. Restrict this exception to its own label and bounds.
            guard issue.auditType == .contrast, let disabledNext, !disabledNext.isEnabled,
                let element = issue.element
            else { return false }
            return element.label == disabledNext.label && element.frame == disabledNext.frame
        }
        try app.performAccessibilityAudit(for: [
            .hitRegion, .sufficientElementDescription, .textClipped, .dynamicType,
        ])
    }

    @MainActor
    private func adjustEffect(_ name: String, to position: CGFloat, in app: XCUIApplication) throws
        -> String
    {
        let slider = app.sliders[name.lowercased() + "Slider"]
        reveal(slider, in: app)
        XCTAssertEqual(slider.label, name)
        let original = try XCTUnwrap(slider.value as? String)
        drag(slider, to: position)
        let changed = try XCTUnwrap(slider.value as? String)
        XCTAssertNotEqual(original, changed)
        return changed
    }

    @MainActor
    private func drag(_ slider: XCUIElement, to position: CGFloat) {
        let thumb = slider.coordinate(
            withNormalizedOffset: CGVector(dx: slider.normalizedSliderPosition, dy: 0.5))
        let target = slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5))
        thumb.press(
            forDuration: 0.10, thenDragTo: target, withVelocity: 100, thenHoldForDuration: 0.20)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, searchAbove: Bool = false)
    {
        let bounds = app.frame
        let bar = app.navigationBars.firstMatch
        let top = (bar.exists ? bar.frame.maxY : bounds.minY) + 4
        let bottom = bounds.maxY - 20
        let center = (top + bottom) / 2
        let maxDrag = (bottom - top) * 0.40
        for _ in 0..<14 {
            var distance = searchAbove ? -maxDrag : maxDrag
            if element.exists {
                let frame = element.frame
                if element.isHittable, frame.maxY > top, frame.minY < bottom,
                    (top...bottom).contains(frame.midY) || frame.height > bottom - top
                {
                    return
                }
                distance = min(maxDrag, max(-maxDrag, frame.midY - center))
            }
            // Scroll from the gutter in short controlled drags. A full flick can jump
            // past the entire control on a compact phone at an accessibility text size.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(
                CGVector(dx: bounds.width * 0.045, dy: center + distance / 2))
            let end = start.withOffset(CGVector(dx: 0, dy: -distance))
            start.press(
                forDuration: 0.04, thenDragTo: end, withVelocity: 460, thenHoldForDuration: 0.15)
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
