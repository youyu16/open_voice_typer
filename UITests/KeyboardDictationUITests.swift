import UIKit
import XCTest

/// The full Typeless-style journey, automated end to end:
///
///   1. Enable the Voice Typer keyboard (+ Full Access) in the Settings app
///   2. Open Open Voice Typer — the mic session auto-starts on foreground
///   3. Switch to a DIFFERENT app, focus a text field, long-press the globe
///      key, and pick Voice Typer
///   4. Tap the speak pill, "speak", tap again — the dictated text must be
///      inserted into the other app's text field
///
/// Provider calls are faked via `OVT_FAKE_PIPELINE` (the simulator has no
/// working Apple speech stack and CI has no API keys). Everything else is
/// real: the extension process, App Group bridge, Darwin notifications, the
/// backgrounded session's audio capture, and proxy text insertion.
final class KeyboardDictationUITests: XCTestCase {
    private let dictatedText = "Hello from Open Voice Typer."
    private let keyboardName = "Voice Typer"

    @MainActor
    func testDictationInsertsTextInAnotherApp() throws {
        enableVoiceKeyboardInSettings()

        // Foregrounding the app is all the session setup there is.
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding"]
        app.launchEnvironment["OVT_FAKE_PIPELINE"] = dictatedText
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Voice keyboard ready — dictate in any app."]
                .waitForExistence(timeout: 20),
            "mic did not come up on launch — is permission pre-granted (simctl privacy)?"
        )

        // Over to a different app with a text field.
        let (host, field) = try openHostTextField()

        guard switchToVoiceKeyboard(in: host) else {
            captureScreen(host, name: "keyboard-switch-failed")
            XCTFail("could not switch to the \(keyboardName) keyboard via the globe key")
            return
        }
        captureScreen(host, name: "voice-keyboard-open")
        assertKeyboardHasAnExit(in: host)

        // Dictate: tap → (speak) → tap. The fake pipeline returns the text
        // regardless of audio content; capture itself is real.
        let speak = host.buttons["Tap to speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 5), "speak pill missing")
        speak.tap()

        let stop = host.buttons["Stop and insert"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: TimeInterval(5)),
            "recording never started — app did not acknowledge the start command"
        )
        Thread.sleep(forTimeInterval: 1.5)
        stop.tap()

        // The polished text must land in the host app's field.
        let inserted = NSPredicate(format: "value CONTAINS %@", dictatedText)
        expectation(for: inserted, evaluatedWith: field)
        waitForExpectations(timeout: 30)
        captureScreen(host, name: "text-inserted")
    }

    // MARK: - Settings: add keyboard + full access

    /// In Settings the keyboard can surface under the extension's display
    /// name or the app's, depending on the screen.
    private var keyboardNames: [String] { [keyboardName, "Open Voice Typer"] }

    /// Walks the real Settings UI. Fails the test if the keyboard is not in
    /// the enabled list at the end — everything downstream depends on it.
    @MainActor
    private func enableVoiceKeyboardInSettings() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        XCTAssertTrue(tapRow(settings, ["General"]), "Settings: General row not found")
        captureScreen(settings, name: "settings-general")
        XCTAssertTrue(tapRow(settings, ["Keyboard"]), "Settings: Keyboard row not found")
        captureScreen(settings, name: "settings-keyboard")
        // The "Keyboards" drill-in row (labelled with a count, e.g. "Keyboards, 2").
        let keyboardsRow = settings.cells.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Keyboards'")
        ).firstMatch
        if keyboardsRow.waitForExistence(timeout: 5) {
            keyboardsRow.tap()
        }
        captureScreen(settings, name: "settings-keyboards-list")

        if !anyRow(settings, keyboardNames).waitForExistence(timeout: 3) {
            XCTAssertTrue(
                tapRow(settings, ["Add New Keyboard", "Add New Keyboard…"]),
                "Settings: Add New Keyboard row not found"
            )
            captureScreen(settings, name: "settings-add-keyboard-sheet")
            XCTAssertTrue(
                tapRow(settings, keyboardNames),
                "Settings: our keyboard is not offered — is the app installed?"
            )
            captureScreen(settings, name: "settings-after-add")
        }

        // Open the keyboard's own page and grant Full Access.
        let ourRow = anyRow(settings, keyboardNames)
        XCTAssertTrue(ourRow.waitForExistence(timeout: 5), "keyboard missing from enabled list after adding")
        ourRow.tap()
        let fullAccess = settings.switches["Allow Full Access"].firstMatch
        if fullAccess.waitForExistence(timeout: 3) {
            if (fullAccess.value as? String) == "0" {
                fullAccess.tap()
                let allow = settings.alerts.buttons["Allow"]
                if allow.waitForExistence(timeout: 3) { allow.tap() }
            }
            captureScreen(settings, name: "settings-full-access")
            settings.navigationBars.buttons.firstMatch.tap() // back
        }
        settings.terminate()
    }

    /// First matching row among candidate labels (static texts or buttons).
    @MainActor
    private func anyRow(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        for label in labels {
            let text = app.cells.staticTexts[label].firstMatch
            if text.exists { return text }
        }
        return app.cells.staticTexts[labels[0]].firstMatch
    }

    /// Taps a row by any of its candidate labels, scrolling to find it.
    /// Returns false if none was found.
    @MainActor
    @discardableResult
    private func tapRow(_ app: XCUIApplication, _ labels: [String]) -> Bool {
        for _ in 0..<7 {
            for label in labels {
                for query in [app.staticTexts[label], app.buttons[label], app.cells[label]] {
                    let row = query.firstMatch
                    if row.exists, row.isHittable {
                        row.tap()
                        return true
                    }
                }
            }
            app.swipeUp()
        }
        return false
    }

    // MARK: - Escape hatch

    /// A custom keyboard the user cannot leave is worse than no keyboard, and
    /// the two platforms hand out that escape differently: iPhone draws a
    /// globe row underneath every custom keyboard, iPad draws nothing at all.
    /// So on iPad the panel must supply its own globe and hide keys, and on
    /// iPhone it must not — a second globe next to the system's is confusing.
    @MainActor
    private func assertKeyboardHasAnExit(in host: XCUIApplication) {
        let globe = host.buttons["ovt-next-keyboard"]
        let hide = host.buttons["ovt-hide-keyboard"]

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(
                globe.waitForExistence(timeout: 5),
                "iPad draws no system globe row — without our own key the user is stuck in Voice Typer"
            )
            XCTAssertTrue(hide.exists, "iPad has no system way to put the keyboard away either")
        } else {
            XCTAssertFalse(globe.exists, "iPhone already gets a system globe row")
            XCTAssertFalse(hide.exists, "iPhone already gets a system dismiss affordance")
        }
    }

    // MARK: - Host app

    /// First launches of system apps show one-off interstitials (welcome
    /// screens, Safari's search-suggestions sheet, the QuickPath typing
    /// tutorial). Tap through anything dismissible before proceeding.
    @MainActor
    private func dismissInterstitials(_ app: XCUIApplication, rounds: Int = 4) {
        for _ in 0..<rounds {
            var tapped = false
            for label in ["Continue", "Get Started", "Not Now", "OK", "Done", "Dismiss"] {
                let button = app.buttons[label].firstMatch
                if button.exists, button.isHittable {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { return }
            Thread.sleep(forTimeInterval: 0.7)
        }
    }

    /// Opens another app and focuses a text input, returning (app, element
    /// whose `value` will contain the inserted text). Tries Reminders first,
    /// then Safari's address bar.
    @MainActor
    private func openHostTextField() throws -> (XCUIApplication, XCUIElement) {
        let reminders = XCUIApplication(bundleIdentifier: "com.apple.reminders")
        reminders.launch()
        dismissInterstitials(reminders)
        let newReminder = reminders.buttons["New Reminder"].firstMatch
        if newReminder.waitForExistence(timeout: 8) {
            newReminder.tap()
            let field = reminders.textViews.firstMatch
            if field.waitForExistence(timeout: 5) {
                dismissInterstitials(reminders) // typing tutorial over the keyboard
                return (reminders, field)
            }
        }
        captureScreen(reminders, name: "reminders-no-field")
        reminders.terminate()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        dismissInterstitials(safari) // search-suggestions first-run sheet
        for identifier in ["Address", "URL", "TabBarItemTitle"] {
            let bar = safari.textFields[identifier].firstMatch
            if bar.waitForExistence(timeout: 4) {
                bar.tap()
                dismissInterstitials(safari) // typing tutorial over the keyboard
                return (safari, safariEditableField(safari, labelled: identifier))
            }
        }
        captureScreen(safari, name: "safari-no-field")
        throw XCTSkip("no automatable host text field found (Reminders/Safari)")
    }

    /// The one Safari field that actually receives the typing.
    ///
    /// On iPad there are *two* text fields labelled "Address": the live search
    /// field (identifier `SearchFieldItemView…`) and the tab bar's title
    /// (`TabBarItemTitleContainer`). `firstMatch` resolves to the tab title,
    /// whose `value` never changes — so the dictated text landed correctly and
    /// the assertion still timed out. iPhone has only the one field, which is
    /// why this never surfaced there.
    @MainActor
    private func safariEditableField(
        _ safari: XCUIApplication,
        labelled identifier: String
    ) -> XCUIElement {
        let searchField = safari.textFields
            .matching(NSPredicate(format: "identifier BEGINSWITH 'SearchFieldItemView'"))
            .firstMatch
        return searchField.exists ? searchField : safari.textFields[identifier].firstMatch
    }

    // MARK: - Keyboard switching

    /// Makes the custom keyboard current: long-press the globe key and pick
    /// it from the menu, falling back to tap-cycling through keyboards.
    @MainActor
    private func switchToVoiceKeyboard(in host: XCUIApplication) -> Bool {
        let speak = host.buttons["Tap to speak"]
        if speak.waitForExistence(timeout: 2) { return true }

        let globe = host.buttons["Next keyboard"].firstMatch
        guard globe.waitForExistence(timeout: 8) else { return false }

        globe.press(forDuration: 1.2)
        let menuItem = host.staticTexts[keyboardName].firstMatch
        if menuItem.waitForExistence(timeout: 3) {
            menuItem.tap()
            if speak.waitForExistence(timeout: 5) { return true }
        }

        // Menu didn't show or didn't take: cycle with taps.
        for _ in 0..<4 {
            if speak.exists { return true }
            let nextGlobe = host.buttons["Next keyboard"].firstMatch
            guard nextGlobe.waitForExistence(timeout: 3) else { break }
            nextGlobe.tap()
            _ = speak.waitForExistence(timeout: 2)
        }
        return speak.waitForExistence(timeout: 3)
    }

    @MainActor
    private func captureScreen(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
