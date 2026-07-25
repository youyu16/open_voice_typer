import Foundation
import SwiftUI

/// Keyboard-side state machine. Talks to the main app exclusively through
/// `DictationBridge`; performs text insertion through closures wired to the
/// `UIInputViewController`'s text document proxy.
@MainActor
@Observable
final class VoicePanelModel {
    enum Phase: Equatable {
        case noFullAccess
        case noSession
        case idle
        case recording
        case processing
        case error(String)

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    /// The app must acknowledge a start command (by publishing a recording
    /// state) within this window, or the tap is declared failed instead of
    /// letting the user talk into a dead mic.
    static let startAckTimeout: TimeInterval = 3
    /// Ceiling for ASR + polish; beyond it the keyboard stops waiting. Sized
    /// to allow both stages to exhaust their timeout-retry budget (3 attempts
    /// × 20s each) in the pathological all-timeout case.
    static let resultTimeout: TimeInterval = 130
    /// A tap-start-to-stop shorter than this is treated as a misclick and
    /// discarded locally — no round trip to the app, nothing to wait for.
    static let minRecordingSeconds: TimeInterval = 0.6
    /// Gap between insertion steps, and the number of steps any transcript is
    /// allowed — together they cap the typing animation at ~0.4 s however long
    /// the dictation was (it used to run to 1.5 s, all of it after the text
    /// was already in hand).
    static let insertionStepMS = 6
    static let maxInsertionSteps = 66

    /// Dictate inserts what you said (via the selected template); Translate
    /// rides the built-in Translate style into the configured target language.
    enum Mode: Equatable {
        case dictate
        case translate
    }

    var phase: Phase = .idle
    var audioLevel: Float = 0
    var styles: [Style] = []
    var selectedStyleID: String = Style.light.id {
        didSet {
            var settings = SettingsStore.load()
            settings.selectedStyleID = selectedStyleID
            if selectedStyleID != Style.translate.id {
                settings.lastDictateStyleID = selectedStyleID
            }
            SettingsStore.save(settings)
        }
    }
    /// Shown next to the Translate mode; refreshed on activation.
    private(set) var targetLanguage = "English"

    /// True when the host will *not* draw a keyboard-switch affordance for us
    /// and the panel has to supply one itself — which is the case on iPad.
    /// See `VoicePanelView.systemKeyColumn`.
    let needsInputModeSwitchKey: Bool
    var onGlobe: () -> Void = {}
    var insertTextHandler: (String) -> Void = { _ in }
    var deleteBackwardHandler: () -> Void = {}
    var dismissKeyboardHandler: () -> Void = {}

    /// Deep link that launches the containing app (which auto-starts the mic
    /// session on foreground). Opened via a SwiftUI `Link`.
    static let openAppURL = URL(string: "openvoicetyper://open")!

    /// The start-command id of the dictation this keyboard is waiting on.
    /// Deliberately instance-only (never shared through the bridge): each
    /// host app runs its own keyboard extension process, so a result is only
    /// ever inserted by the very instance that requested it — app A's
    /// transcript can't surface in app B.
    private var awaitingCommandID: UUID?
    private var startAcknowledged = false
    private var recordingStartedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    /// The in-flight character-by-character insertion, so a dismissal can stop
    /// it typing into a text field that is no longer ours.
    private var insertionTask: Task<Void, Never>?
    private var lastInsertedText = ""
    private var tokens: [DarwinNotifier.ObservationToken] = []
    private var pollTimer: Timer?

    init(needsInputModeSwitchKey: Bool) {
        self.needsInputModeSwitchKey = needsInputModeSwitchKey
    }

    var canDictate: Bool {
        switch phase {
        case .idle, .error: true
        default: false
        }
    }

    var canUndo: Bool {
        !lastInsertedText.isEmpty && phase != .recording && phase != .processing
    }

    var selectedStyleName: String {
        styles.first { $0.id == selectedStyleID }?.name ?? "Style"
    }

    /// The mode is just a view on the selected style — Translate style means
    /// translate mode, anything else is dictate.
    var mode: Mode {
        selectedStyleID == Style.translate.id ? .translate : .dictate
    }

    /// Templates offered in dictate mode; Translate lives behind the toggle.
    var dictateStyles: [Style] {
        styles.filter { $0.id != Style.translate.id }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        switch newMode {
        case .translate:
            // lastDictateStyleID already holds the current template — every
            // non-translate selection is stashed there on write.
            selectedStyleID = Style.translate.id
        case .dictate:
            selectedStyleID = SettingsStore.load().lastDictateStyleID
        }
    }

    var statusText: String {
        switch phase {
        case .recording: "Listening… tap to finish"
        case .processing: "Working…"
        case .error(let message): message
        default: "Tap to speak"
        }
    }

    // MARK: Lifecycle (wired from KeyboardViewController)

    func activate() {
        guard DictationBridge.isAvailable else {
            phase = .noFullAccess
            return
        }
        styles = SharedCatalog.loadStyles()
        let settings = SettingsStore.load()
        selectedStyleID = settings.selectedStyleID
        targetLanguage = settings.targetLanguage

        tokens = [
            DarwinNotifier.observe(.resultPosted) { [weak self] in
                Task { @MainActor in self?.consumeResult() }
            },
            DarwinNotifier.observe(.statePosted) { [weak self] in
                Task { @MainActor in self?.consumeState() }
            },
            DarwinNotifier.observe(.sessionChanged) { [weak self] in
                Task { @MainActor in self?.refreshSessionState() }
            },
        ]
        // Darwin delivery to extensions is reliable in the foreground, but a
        // slow poll catches anything missed (e.g. a heartbeat going stale).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSessionState()
                self?.consumeResult()
            }
        }

        // A fresh keyboard instance is not waiting on anything, so any result
        // sitting in the shared slot belongs to a *previous* dictation —
        // very likely in another app. Discard it so it can't leak into this
        // app's text field. (consumeResult only ever inserts a result whose
        // id matches this instance's own awaitingCommandID, which is nil here.)
        if DictationBridge.latestResult() != nil {
            DictationBridge.clearResult()
        }
        refreshSessionState()
    }

    func deactivate() {
        // Abandon any dictation in flight when the keyboard closes so its
        // result can never surface in whatever app opens next; an active
        // recording is also told to stop capturing. Clearing the awaited id
        // is what guarantees a result is only inserted by the still-open
        // instance that asked for it.
        if phase == .recording {
            DictationBridge.send(KeyboardCommand(kind: .cancelDictation, styleID: selectedStyleID))
        }
        // The dictation is abandoned either way, so the transient phases are no
        // longer true — and leaving one set strands the panel. This model
        // outlives a dismissal (the view controller reuses it across
        // appearances), and refreshSessionState() only clears .recording /
        // .processing when the session is *dead*. With the app still alive, a
        // keyboard dismissed mid-dictation therefore came back showing
        // "Listening…" or "Working…" forever: nothing was awaited, so no result
        // could land, and no timeout was armed to break out of it.
        if phase == .recording || phase == .processing {
            phase = .idle
        }
        awaitingCommandID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        // Stop mid-stream rather than typing the rest of a transcript into
        // whatever field the next host app puts in front of us.
        insertionTask?.cancel()
        insertionTask = nil
        tokens = []
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Dictation

    func toggleDictation() {
        switch phase {
        case .idle, .error:
            let command = KeyboardCommand(kind: .startDictation, styleID: selectedStyleID)
            awaitingCommandID = command.id
            startAcknowledged = false
            recordingStartedAt = Date()
            DictationBridge.send(command)
            phase = .recording
            audioLevel = 0
            scheduleTimeout(after: Self.startAckTimeout, ifStillAwaiting: command.id) { [weak self] in
                guard let self, !self.startAcknowledged, self.phase == .recording else { return }
                DictationBridge.send(KeyboardCommand(kind: .cancelDictation, styleID: self.selectedStyleID))
                self.fail("The app didn't start recording. Open Open Voice Typer once, then try again.")
            }
        case .recording:
            // Defence in depth: stopping without an awaited id would arm no
            // timeout (scheduleTimeout ignores a nil id) and match no result,
            // parking the panel in .processing with no way out. Nothing is in
            // flight, so just go back to idle.
            guard awaitingCommandID != nil else {
                recordingStartedAt = nil
                phase = .idle
                return
            }
            // A quick tap-tap (misclick) produced too little audio to be worth
            // transcribing — cancel it locally so there's nothing to wait for.
            if let startedAt = recordingStartedAt,
               Date().timeIntervalSince(startedAt) < Self.minRecordingSeconds {
                DictationBridge.send(KeyboardCommand(kind: .cancelDictation, styleID: selectedStyleID))
                awaitingCommandID = nil
                recordingStartedAt = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                phase = .error("Hold the button while you speak.")
                return
            }
            recordingStartedAt = nil
            let id = awaitingCommandID
            DictationBridge.send(KeyboardCommand(kind: .stopDictation, styleID: selectedStyleID))
            phase = .processing
            scheduleTimeout(after: Self.resultTimeout, ifStillAwaiting: id) { [weak self] in
                self?.fail("Timed out waiting for the result. Try again.")
            }
        default:
            break
        }
    }

    /// Arms the single failure timer for the dictation identified by `id`;
    /// any state advance re-arms or cancels it.
    private func scheduleTimeout(
        after seconds: TimeInterval,
        ifStillAwaiting id: UUID?,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.awaitingCommandID == id, id != nil else { return }
            onTimeout()
        }
    }

    private func fail(_ message: String) {
        awaitingCommandID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        phase = .error(message)
    }

    private func consumeResult() {
        guard let result = DictationBridge.latestResult(),
              result.commandID == awaitingCommandID
        else { return }
        DictationBridge.clearResult()
        awaitingCommandID = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        if let message = result.errorMessage {
            phase = .error(message)
            return
        }
        insert(result.polishedText)
    }

    private func consumeState() {
        guard let state = DictationBridge.currentState() else { return }
        guard state.commandID == awaitingCommandID, awaitingCommandID != nil else { return }
        if phase == .recording, state.phase == .recording {
            startAcknowledged = true
            audioLevel = state.audioLevel
        }
    }

    private func refreshSessionState() {
        guard DictationBridge.isAvailable else {
            phase = .noFullAccess
            return
        }
        let alive = DictationBridge.isSessionAlive
        switch phase {
        case .noSession where alive:
            phase = .idle
        case .idle where !alive, .error where !alive:
            phase = .noSession
        case .recording where !alive, .processing where !alive:
            // The app died mid-dictation.
            awaitingCommandID = nil
            timeoutTask?.cancel()
            phase = .noSession
        default:
            break
        }
    }

    // MARK: Text operations

    func insertText(_ text: String) {
        insertTextHandler(text)
    }

    func deleteBackward() {
        deleteBackwardHandler()
    }

    /// Hands the input session to the next keyboard (the globe key's job).
    func switchToNextKeyboard() {
        onGlobe()
    }

    /// Puts the keyboard away. Only reachable where the system draws no row of
    /// its own to do it — see `needsInputModeSwitchKey`.
    func dismissKeyboard() {
        dismissKeyboardHandler()
    }

    /// Streams the text in for a typing feel, one step every
    /// `insertionStepMS`. The animation is a feel, not a feature: it must
    /// never be the slowest part of a dictation, so a long transcript arrives
    /// in small chunks instead of crawling character by character. That also
    /// bounds the number of proxy writes — each one is a hop into the host app
    /// and a re-layout of its text view, so a 600-character transcript must
    /// not cost 600 of them.
    private func insert(_ text: String) {
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        let chunkSize = max(1, Int((Double(text.count) / Double(Self.maxInsertionSteps)).rounded(.up)))
        phase = .processing
        // `lastInsertedText` is what undo deletes, one deleteBackward per
        // character, so it must record what actually *landed* — not what we
        // set out to insert. Assigning the whole string up front meant an
        // interrupted stream (the keyboard dismissed mid-insert) left undo
        // believing it had inserted more than it had, and it would then eat
        // that many characters of the user's own surrounding text.
        lastInsertedText = ""
        insertionTask?.cancel()
        insertionTask = Task { @MainActor in
            var index = text.startIndex
            while index < text.endIndex {
                guard !Task.isCancelled else { break }
                let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                let chunk = String(text[index..<end])
                insertTextHandler(chunk)
                lastInsertedText.append(chunk)
                index = end
                try? await Task.sleep(for: .milliseconds(Self.insertionStepMS))
            }
            insertionTask = nil
            // Don't stomp a phase set while this was streaming (a dismissal
            // resets to .idle, the session may have dropped to .noSession).
            if phase == .processing { phase = .idle }
        }
    }

    func undoLastInsert() {
        guard !lastInsertedText.isEmpty else { return }
        for _ in 0..<lastInsertedText.count {
            deleteBackwardHandler()
        }
        lastInsertedText = ""
    }
}
