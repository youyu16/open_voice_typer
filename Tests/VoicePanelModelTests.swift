import XCTest
@testable import OpenVoiceTyper

/// The keyboard-side state machine. It had no coverage at all until the
/// stranded-panel bug below, which is exactly the kind of fault it hides: the
/// phase is the only thing standing between the user and a dead mic button,
/// and nothing outside the model can put it right.
@MainActor
final class VoicePanelModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DictationBridge.clearCommands()
        DictationBridge.clearResult()
        // A live session, so refreshSessionState() leaves .idle alone instead
        // of dropping the model into .noSession.
        DictationBridge.publish(SessionHeartbeat(startedAt: .now, lastBeatAt: .now))
    }

    override func tearDown() {
        DictationBridge.clearCommands()
        DictationBridge.clearResult()
        super.tearDown()
    }

    private func makeModel() -> VoicePanelModel {
        VoicePanelModel(needsInputModeSwitchKey: false)
    }

    // MARK: Stranded panel

    /// The regression: dismissing the keyboard mid-recording used to leave the
    /// phase at .recording. The model outlives a dismissal, and
    /// refreshSessionState() only clears the transient phases when the session
    /// is *dead* — so with the app still alive the panel came back showing
    /// "Listening…" forever, awaiting nothing and with no timeout armed.
    func testDeactivateClearsRecordingPhase() {
        let model = makeModel()
        model.activate()
        XCTAssertEqual(model.phase, .idle, "a live session should start idle")

        model.toggleDictation()
        XCTAssertEqual(model.phase, .recording)

        model.deactivate()
        XCTAssertEqual(model.phase, .idle, "a dismissed keyboard must not stay in .recording")

        // Reopening must land on a usable panel, not a stranded one.
        model.activate()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.canDictate, "the mic must be tappable again after reopening")
    }

    /// Same fault on the other transient phase: .processing is what a keyboard
    /// dismissed while waiting for a transcript would have been stuck in, and
    /// unlike .recording it also disables the mic button.
    func testDeactivateClearsProcessingPhase() {
        let model = makeModel()
        model.activate()
        model.toggleDictation()
        model.phase = .processing

        model.deactivate()
        XCTAssertEqual(model.phase, .idle, "a dismissed keyboard must not stay in .processing")

        model.activate()
        XCTAssertTrue(model.canDictate)
    }

    /// Deactivating while recording must also tell the app to stop capturing,
    /// or the session keeps recording into a dictation nobody is waiting for.
    func testDeactivateCancelsTheInFlightDictation() {
        let model = makeModel()
        model.activate()
        DictationBridge.clearCommands()

        model.toggleDictation()
        model.deactivate()

        XCTAssertEqual(
            DictationBridge.commandQueue().last?.kind, .cancelDictation,
            "an abandoned recording must be cancelled app-side"
        )
    }

    /// Defence in depth: stopping with nothing awaited would arm no timeout and
    /// match no result, parking the panel in .processing permanently.
    func testStoppingWithNothingAwaitedReturnsToIdle() {
        let model = makeModel()
        model.activate()
        model.phase = .recording // no awaited command id

        model.toggleDictation()

        XCTAssertEqual(model.phase, .idle, "a stop with nothing in flight must not hang in .processing")
    }

    // MARK: Result routing

    /// A result the model never asked for belongs to a previous dictation —
    /// very likely one raised in a different host app — and inserting it would
    /// leak app A's transcript into app B's text field.
    func testUnrequestedResultIsNotInserted() {
        let model = makeModel()
        var inserted = ""
        model.insertTextHandler = { inserted += $0 }
        model.activate()

        DictationBridge.publish(DictationResult(
            commandID: UUID(),
            styleID: Style.light.id,
            rawText: "raw",
            polishedText: "should not appear"
        ))

        model.activate() // the poll/notification path re-reads the slot
        XCTAssertTrue(inserted.isEmpty, "a foreign result must never be inserted")
    }

    /// Activating discards whatever is sitting in the shared single-slot
    /// mailbox, so a stale transcript cannot surface in the next host app.
    func testActivateDiscardsStaleResult() {
        DictationBridge.publish(DictationResult(
            commandID: UUID(),
            styleID: Style.light.id,
            rawText: "raw",
            polishedText: "stale"
        ))

        let model = makeModel()
        model.activate()

        XCTAssertNil(DictationBridge.latestResult(), "a fresh keyboard must clear the result slot")
    }

    // MARK: Mode

    func testModeFollowsSelectedStyle() {
        let model = makeModel()
        model.activate()

        model.setMode(.translate)
        XCTAssertEqual(model.mode, .translate)
        XCTAssertEqual(model.selectedStyleID, Style.translate.id)

        model.setMode(.dictate)
        XCTAssertEqual(model.mode, .dictate)
        XCTAssertNotEqual(model.selectedStyleID, Style.translate.id)
    }

    /// Translate is reachable from the toggle, so it must not also appear in
    /// the style menu the toggle sits next to.
    func testDictateStylesExcludeTranslate() {
        let model = makeModel()
        model.activate()
        XCTAssertFalse(model.dictateStyles.contains { $0.id == Style.translate.id })
    }

    // MARK: Undo

    func testUndoIsUnavailableWithNothingInserted() {
        let model = makeModel()
        model.activate()
        XCTAssertFalse(model.canUndo, "undo must stay disabled until something is dictated")
    }

    /// Undo issues one deleteBackward per character it believes it inserted,
    /// so that count must match what actually landed in the field. It used to
    /// be set to the whole transcript before streaming began, so an insertion
    /// cut short left undo deleting into the user's own surrounding text.
    func testUndoDeletesExactlyWhatWasInserted() async throws {
        let model = makeModel()
        var inserted = ""
        var deletions = 0
        model.insertTextHandler = { inserted += $0 }
        model.deleteBackwardHandler = { deletions += 1 }
        model.activate()

        let text = try await dictate("Hello there", into: model)
        XCTAssertEqual(inserted, text, "the whole transcript should have landed")

        model.undoLastInsert()
        XCTAssertEqual(
            deletions, inserted.count,
            "undo must delete exactly the characters it inserted, no more"
        )
        XCTAssertFalse(model.canUndo, "undo must not repeat")
    }

    /// A long dictation must not turn into a long typing animation: the text
    /// is already in hand by then, and every step is a hop into the host app
    /// plus a re-layout of its text view. Long transcripts therefore stream in
    /// chunks — the whole text still lands, and undo still matches it exactly.
    func testLongTranscriptStreamsInBoundedStepsAndLandsWhole() async throws {
        let model = makeModel()
        var inserted = ""
        var steps = 0
        var deletions = 0
        model.insertTextHandler = { inserted += $0; steps += 1 }
        model.deleteBackwardHandler = { deletions += 1 }
        model.activate()

        let text = String(repeating: "the quick brown fox ", count: 30) // 600 characters
        try await dictate(text, into: model)

        XCTAssertEqual(inserted, text, "the whole transcript should have landed")
        XCTAssertLessThanOrEqual(
            steps, VoicePanelModel.maxInsertionSteps,
            "600 characters must not cost 600 proxy writes"
        )
        model.undoLastInsert()
        XCTAssertEqual(deletions, text.count, "undo still deletes one character per character inserted")
    }

    /// Dismissing the keyboard mid-insert must stop the stream — otherwise the
    /// rest of the transcript types itself into whatever field the next host
    /// app puts in front of us — and undo must then account only for the part
    /// that actually landed.
    func testDismissalStopsInsertionAndUndoStaysAccurate() async throws {
        let model = makeModel()
        var inserted = ""
        var deletions = 0
        model.insertTextHandler = { inserted += $0 }
        model.deleteBackwardHandler = { deletions += 1 }
        model.activate()

        // Cut the stream from inside the insert callback rather than racing it
        // with a sleep: the handler runs synchronously on the MainActor inside
        // the streaming loop, so dismissing on the step that crosses `cutAfter`
        // interrupts at exactly that step every time, however loaded the
        // machine is. (A long transcript streams in chunks, so the crossing
        // step lands at or just past `cutAfter`, not exactly on it.)
        let cutAfter = 5
        let text = String(repeating: "a", count: 400)
        var dismissed = false
        model.insertTextHandler = { [weak model] chunk in
            inserted += chunk
            guard !dismissed, inserted.count >= cutAfter else { return }
            dismissed = true
            model?.deactivate()
        }

        try await beginDictation(text, into: model)
        let deadline = Date().addingTimeInterval(5)
        while !dismissed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let atDismissal = inserted.count
        XCTAssertTrue(dismissed, "the stream should have been cut mid-flight")
        XCTAssertGreaterThanOrEqual(atDismissal, cutAfter)
        XCTAssertLessThan(atDismissal, text.count)

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(inserted.count, atDismissal, "insertion must stop when the keyboard goes away")

        model.undoLastInsert()
        XCTAssertEqual(deletions, atDismissal, "undo must only remove what actually landed")
    }

    // MARK: Helpers

    /// Drives a dictation through the real bridge — start, then a published
    /// result carrying the start command's id — and waits for the insertion.
    @discardableResult
    private func dictate(_ text: String, into model: VoicePanelModel) async throws -> String {
        try await beginDictation(text, into: model)
        let deadline = Date().addingTimeInterval(5)
        while model.phase == .processing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return text
    }

    private func beginDictation(_ text: String, into model: VoicePanelModel) async throws {
        DictationBridge.clearCommands()
        model.toggleDictation()
        guard let start = DictationBridge.commandQueue().last else {
            return XCTFail("no start command reached the bridge")
        }
        // Stopping sooner than `minRecordingSeconds` is discarded as a misclick,
        // so dwell past it or the dictation never reaches the result stage.
        try await Task.sleep(for: .seconds(VoicePanelModel.minRecordingSeconds + 0.15))
        model.toggleDictation() // stop -> awaiting a result for `start.id`

        DictationBridge.publish(DictationResult(
            commandID: start.id,
            styleID: Style.light.id,
            rawText: text,
            polishedText: text
        ))
        // Darwin delivery is in-process here but still asynchronous.
        let deadline = Date().addingTimeInterval(3)
        while DictationBridge.latestResult() != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
