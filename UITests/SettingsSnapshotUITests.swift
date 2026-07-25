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

        XCTAssertTrue(app.tabButton("Settings").waitForExistence(timeout: 15), "no tabs")
        app.tabButton("Settings").tap()

        XCTAssertTrue(app.staticTexts["Polish"].waitForExistence(timeout: 10), "Polish section missing")

        // Settings persist between runs, so pin speech-to-text to on-device:
        // its cloud rows are labelled the same as polish's ("Model", "API
        // Key", "Base URL") and would make the assertions below ambiguous.
        selectEngine("On-device", in: app)

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
        selectEngine("Cloud (OpenAI-compatible)", in: app)
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
        app.buttons["OpenAI"].tap() // dismiss the menu

        // Scribe speaks its own protocol, so it is an engine rather than a
        // preset: fixed endpoint, its own model list and its own key row.
        selectEngine("ElevenLabs Scribe", in: app)
        XCTAssertTrue(app.staticTexts["Model"].firstMatch.waitForExistence(timeout: 5),
                      "Scribe has no Model row")
        XCTAssertTrue(app.staticTexts["API Key"].firstMatch.waitForExistence(timeout: 5),
                      "Scribe has no API Key row")
        XCTAssertFalse(app.staticTexts["Base URL"].exists,
                       "Scribe is a fixed endpoint and must not offer a Base URL field")

        let scribe = XCTAttachment(screenshot: app.screenshot())
        scribe.name = "settings-asr-elevenlabs"
        scribe.lifetime = .keepAlways
        add(scribe)
    }

    /// Typing into any Settings field used to trap the user: the system
    /// keyboard covers the tab bar, and a Form has no built-in way to dismiss
    /// it, so there was no way back to the other tabs without force-quitting.
    @MainActor
    func testTypingInSettingsDoesNotTrapTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.tabButton("Settings").waitForExistence(timeout: 15), "no tabs")
        app.tabButton("Settings").tap()
        XCTAssertTrue(app.staticTexts["Polish"].waitForExistence(timeout: 10), "Polish section missing")

        // Cloud speech-to-text gives us an editable Base URL field to focus.
        selectEngine("Cloud (OpenAI-compatible)", in: app)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no editable field in Settings")
        field.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "no way to dismiss the keyboard — the tab bar stays covered")
        done.tap()

        XCTAssertTrue(app.tabButton("History").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabButton("History").isHittable,
                      "the tab bar is still covered by the keyboard")
        app.tabButton("History").tap()
        XCTAssertTrue(app.tabButton("History").isSelected, "could not leave Settings")
    }

    /// The engine picker is a menu button labelled "Engine, <selection>".
    @MainActor
    private func selectEngine(_ name: String, in app: XCUIApplication) {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Engine,'"))
            .firstMatch
            .tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5),
                      "\(name) is missing from the speech-to-text engine picker")
        app.buttons[name].tap()
    }
}
