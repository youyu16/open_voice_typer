import XCTest

/// Snapshots the Settings → Polish section for each provider so a
/// registry-driven refactor of the UI can be eyeballed. Not asserting layout,
/// just proving the section renders and switches without crashing.
final class SettingsSnapshotUITests: XCTestCase {
    @MainActor
    func testPolishSectionRendersForEachProvider() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15), "no tabs")
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["Polish"].waitForExistence(timeout: 10), "Polish section missing")

        // Settings persist between runs, so pin speech-to-text to on-device:
        // its cloud rows are labelled the same as polish's ("Model", "API
        // Key", "Base URL") and would make the assertions below ambiguous.
        app.buttons["On-device"].tap()

        XCTAssertTrue(app.staticTexts["Model"].firstMatch.waitForExistence(timeout: 5),
                      "polish Model row missing")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-polish"
        shot.lifetime = .keepAlways
        add(shot)

        // Every registered backend must be offered. The section is generated
        // from `PolishBackendSpec`, so a provider that is declared but never
        // reaches the picker is exactly the failure this catches. The picker
        // is a menu button labelled "Provider, <current selection>".
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Provider,'"))
            .firstMatch
            .tap()
        for name in ["OpenAI-compatible", "Anthropic", "Google Gemini", "Groq",
                     "OpenRouter", "DeepSeek", "xAI (Grok)", "Mistral"] {
            XCTAssertTrue(
                app.buttons[name].waitForExistence(timeout: 5),
                "\(name) is missing from the polish provider picker"
            )
        }

        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "settings-polish-providers"
        picker.lifetime = .keepAlways
        add(picker)

        // Pick a newly added one and prove its rows render: a fixed-endpoint
        // backend shows Model and API Key, and offers no Base URL to edit.
        app.buttons["Mistral"].tap()
        XCTAssertTrue(app.staticTexts["Model"].firstMatch.waitForExistence(timeout: 5),
                      "Mistral has no Model row")
        XCTAssertTrue(app.staticTexts["API Key"].firstMatch.waitForExistence(timeout: 5),
                      "Mistral has no API Key row")
        XCTAssertFalse(app.staticTexts["Base URL"].exists,
                       "a fixed-endpoint backend must not offer a Base URL field")

        // Cloud speech-to-text is configured by preset rather than by a
        // provider picker, so its menu is the equivalent surface to check.
        app.buttons["Cloud"].tap()
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Preset'"))
            .firstMatch
            .tap()
        for name in ["OpenAI", "Groq", "Together", "DeepInfra", "Fireworks",
                     "Lemonfox", "Mistral (Voxtral)", "Local server"] {
            XCTAssertTrue(
                app.buttons[name].waitForExistence(timeout: 5),
                "\(name) is missing from the speech-to-text preset menu"
            )
        }

        let asrPresets = XCTAttachment(screenshot: app.screenshot())
        asrPresets.name = "settings-asr-presets"
        asrPresets.lifetime = .keepAlways
        add(asrPresets)
    }
}
