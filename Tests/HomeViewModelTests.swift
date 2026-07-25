import XCTest
@testable import OpenVoiceTyper

@MainActor
final class HomeViewModelTests: XCTestCase {
    /// Home's waveform and the record button's pulse both hang off
    /// `SessionController.onUILevel`, which is a *single* slot — last writer
    /// wins.
    ///
    /// `@State private var model = HomeViewModel()` re-evaluates
    /// `HomeViewModel()` every time the view struct is re-created, and SwiftUI
    /// throws all but the first away. Subscribing from `init` therefore hands
    /// the level feed to whichever instance was built last — a corpse, whose
    /// `[weak self]` closure quietly does nothing. HomeView lives inside the
    /// TabView, so the first unrelated re-render is enough to kill it, and the
    /// waveform sits flat for the rest of the launch.
    func testLevelsReachTheLiveModelAfterTheViewStructIsRecreated() {
        let live = HomeViewModel()
        live.connect()
        live.isRecording = true

        // SwiftUI re-creating HomeView: constructed, then immediately dropped.
        for _ in 0..<3 { _ = HomeViewModel() }

        SessionController.shared.onUILevel?(0.8)

        XCTAssertEqual(
            live.audioLevel, 0.8, accuracy: 0.0001,
            "a discarded HomeViewModel stole the level feed — the button stops pulsing"
        )
        XCTAssertEqual(
            live.levelHistory.last, 0.8,
            "the waveform never received a sample, so it renders flat"
        )
    }

    /// Levels are only meaningful while capturing; outside a recording the
    /// meter must fall back to rest rather than freeze on the last sample.
    func testLevelsAreIgnoredWhenNotRecording() {
        let model = HomeViewModel()
        model.connect()
        model.isRecording = false

        SessionController.shared.onUILevel?(0.9)

        XCTAssertEqual(model.audioLevel, 0, "a level outside a recording must not drive the UI")
    }
}
