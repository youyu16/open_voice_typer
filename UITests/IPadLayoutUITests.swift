import UIKit
import XCTest

/// iPad-shaped checks on the containing app.
///
/// The app was built and tuned on iPhone, where the window is always narrow
/// and effectively always portrait. iPad breaks both assumptions at once: the
/// window is three times as wide, `TabView` renders as a top tab bar rather
/// than a bottom one, and landscape is the orientation most people hold the
/// device in. None of that had ever been exercised.
final class IPadLayoutUITests: XCTestCase {
    private let tabs = ["Dictate", "History", "Templates", "Dictionary", "Settings"]

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    /// Every tab has to survive a rotation. A layout that only ever ran in one
    /// aspect ratio is exactly where a hard-coded width or an unscrollable
    /// container strands content off-screen, and on iPad the user can rotate
    /// at any moment — including while a tab is open.
    @MainActor
    func testEveryTabSurvivesRotation() {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding"]
        app.launch()

        XCTAssertTrue(app.tabButton("Dictate").waitForExistence(timeout: 20), "no tab bar")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let name = orientation == .portrait ? "portrait" : "landscape"

            for tab in tabs {
                let button = app.tabButton(tab)
                XCTAssertTrue(
                    button.waitForExistence(timeout: 10),
                    "\(tab) tab is missing in \(name)"
                )
                button.tap()
                XCTAssertTrue(
                    button.isHittable,
                    "\(tab) tab is not reachable in \(name) — is something covering the tab bar?"
                )
            }

            app.tabButton("Dictate").tap()
            XCTAssertTrue(
                app.buttons["Start recording"].waitForExistence(timeout: 10),
                "the record button is missing in \(name)"
            )

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "home-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// The record button is the one control the whole app exists for, so it
    /// must stay within thumb reach rather than being flung to the middle of a
    /// 13-inch canvas. Asserting it sits in the lower half of the window is a
    /// cheap proxy that a full-bleed layout hasn't centred it into the void.
    @MainActor
    func testRecordButtonStaysReachableOnAWideScreen() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-specific geometry")

        let app = XCUIApplication()
        app.launchArguments = ["--skip-onboarding"]
        app.launch()

        let record = app.buttons["Start recording"]
        XCTAssertTrue(record.waitForExistence(timeout: 20), "record button missing")

        let window = app.windows.firstMatch.frame
        let button = record.frame
        XCTAssertGreaterThan(
            button.midY, window.midY,
            "the record button drifted into the upper half of the iPad window"
        )
        XCTAssertLessThan(
            abs(button.midX - window.midX), window.width * 0.1,
            "the record button is no longer horizontally centred"
        )
    }
}
