import XCTest

/// The Settings toggle that reveals per-dictation latency in History, and the
/// breakdown it reveals. Seeded with a measured dictation via a DEBUG launch
/// argument — a UI test has no microphone and no provider keys, so it cannot
/// produce a timed entry the honest way.
final class HistoryTimingsUITests: XCTestCase {
    @MainActor
    func testTimingsAreHiddenUntilTurnedOnInSettings() throws {
        let app = XCUIApplication()
        // `--timings-off` only on this first launch: the preference persists in
        // the App Group, so without it this test would inherit whatever an
        // earlier run left switched on.
        app.launchArguments = ["--skip-onboarding", "--seed-timed-history", "--timings-off"]
        app.launch()

        XCTAssertTrue(app.tabButton("Settings").waitForExistence(timeout: 15), "no tabs")

        // Off by default: the seeded dictation shows its metadata but no times.
        openSeededDictation(in: app)
        XCTAssertTrue(app.staticTexts["uitest-fake"].waitForExistence(timeout: 5),
                      "the seeded dictation didn't open")
        XCTAssertFalse(app.staticTexts["Total"].exists,
                       "timings should stay hidden until asked for")
        app.swipeDown(velocity: .fast)

        // Turn it on. Diagnostics sits below the provider sections, so the
        // Form starts scrolled above it.
        app.tabButton("Settings").tap()
        let toggle = app.switches["Show timings in History"]
        // Scroll until it is actually *hittable*, not merely present — the
        // last row can exist while sitting under the tab bar, where a tap
        // lands on the tab bar instead of the switch.
        for _ in 0..<10 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.isHittable, "no reachable timings toggle in Settings")
        // The matched element spans the whole row; tapping its centre lands on
        // the label. The switch control itself sits at the trailing edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["Show timings in History"].value as? String, "1",
                       "the toggle didn't switch on")

        let settingsShot = XCTAttachment(screenshot: app.screenshot())
        settingsShot.name = "settings-timings-toggle"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)

        // Relaunch rather than navigating on: it clears any menu still open
        // over the form, and proves the preference actually persisted rather
        // than living in view state.
        app.terminate()
        app.launchArguments = ["--skip-onboarding", "--seed-timed-history"]
        app.launch()
        XCTAssertTrue(app.tabButton("History").waitForExistence(timeout: 15), "no tabs")

        // Now the same dictation explains where its time went.
        openSeededDictation(in: app)
        XCTAssertTrue(app.staticTexts["Total"].waitForExistence(timeout: 5), "no timing breakdown")
        XCTAssertTrue(app.staticTexts["2.4 s"].exists, "total should read as seconds")
        XCTAssertTrue(app.staticTexts["Speech"].exists)
        XCTAssertTrue(app.staticTexts["1.5 s"].exists)
        XCTAssertTrue(app.staticTexts["Polish"].exists)
        XCTAssertTrue(app.staticTexts["800 ms"].exists, "sub-second stages should read as ms")

        let breakdown = XCTAttachment(screenshot: app.screenshot())
        breakdown.name = "history-timing-breakdown"
        breakdown.lifetime = .keepAlways
        add(breakdown)
    }

    @MainActor
    private func openSeededDictation(in app: XCUIApplication) {
        app.tabButton("History").tap()
        let entry = app.buttons.containing(.staticText, identifier: "Hello there.").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "seeded dictation missing from History")
        entry.tap()
    }
}
