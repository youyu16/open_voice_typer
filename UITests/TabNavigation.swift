import XCTest

extension XCUIApplication {
    /// The button for one of the app's five tabs, on either idiom.
    ///
    /// `TabView` does not produce a `tabBar` on iPad. iPhone gets the familiar
    /// bottom bar, which XCUITest exposes as `app.tabBars`; iPad renders the
    /// same `TabView` as a strip across the top whose container is a plain
    /// `Other` element, so `app.tabBars.buttons["Settings"]` matches nothing
    /// and every tab-driven test fails at its first line with "no tabs".
    ///
    /// Matching the button directly works on both, so prefer the tab bar when
    /// there is one (it disambiguates a label that also appears in page
    /// content) and fall back to a plain button lookup.
    func tabButton(_ name: String) -> XCUIElement {
        let inBar = tabBars.buttons[name]
        return inBar.exists ? inBar : buttons[name].firstMatch
    }

    /// Waits for the tab strip to come up, then switches to `name`.
    /// Returns false if the tab never appeared.
    @discardableResult
    func openTab(_ name: String, timeout: TimeInterval = 15) -> Bool {
        let tab = tabButton(name)
        guard tab.waitForExistence(timeout: timeout) else { return false }
        tab.tap()
        return true
    }
}
