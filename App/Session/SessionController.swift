import AVFoundation
import Foundation
import SwiftData
import UIKit

/// Runs a keyboard dictation session: keeps the audio engine (and therefore
/// the backgrounded app) alive, heartbeats liveness to the keyboard, executes
/// keyboard commands off the bridge, and publishes pipeline states/results.
@MainActor
@Observable
final class SessionController {
    static let shared = SessionController()

    /// SwiftData container shared with the UI (history inserts land here).
    let modelContainer: ModelContainer

    private(set) var isActive = false
    private(set) var startedAt: Date?
    var lastError: String?

    let recorder = AudioRecorder()

    /// UI-facing mic level for the in-app dictation button (the bridge gets
    /// its levels separately, only during keyboard-initiated captures).
    var onUILevel: ((Float) -> Void)?

    private var heartbeatTimer: Timer?
    private var autoEndTimer: Timer?
    /// Non-nil while `start()` is between the permission request and going
    /// active; concurrent callers await it instead of starting a second time.
    private var startInFlight: Task<Void, Never>?
    private var commandToken: DarwinNotifier.ObservationToken?
    private var interruptionObserver: (any NSObjectProtocol)?
    private var activeCommand: KeyboardCommand?
    private var lastLevelPublish: Date = .distantPast
    /// Ids already executed — the command queue is append-only (the keyboard
    /// owns the slot), so replay protection lives here, not in clearing.
    private var handledCommandIDs: [UUID] = []
    /// Commands older than this are leftovers from a dead keyboard/app
    /// lifetime and must not fire a surprise recording.
    private static let commandMaxAge: TimeInterval = 20
    /// When the engine has resisted every revival attempt for this long, the
    /// session is declared dead rather than left hanging (see `beat`).
    private static let unrecoverableAfter: TimeInterval = 30
    /// When the current run of engine failures began; nil while healthy.
    private var unhealthySince: Date?

    private init() {
        modelContainer = try! ModelContainer(for: TranscriptRecord.self)
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                self?.publishLevel(level)
                self?.onUILevel?(level)
            }
        }
    }

    // MARK: Session lifecycle

    /// Starts a session without user interaction when possible. Called on
    /// app launch and on every foreground, so opening the app is all the setup
    /// a dictation needs (Typeless-style); never prompts for permission — the
    /// first manual Start does that. Also repairs an already-active session
    /// whose engine died while backgrounded (an interruption that couldn't be
    /// recovered until the app came forward), so reopening the app always
    /// fixes things.
    func autoStartIfPossible() async {
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        if isActive {
            repairIfNeeded()
            return
        }
        await start()
    }

    /// Foregrounding must always leave a working microphone behind. The
    /// dangerous case is a session that is still `isActive` but whose engine is
    /// dead: the keyboard sees no heartbeat and tells the user to open the app,
    /// while `isActive` short-circuits `autoStartIfPossible()` — so opening the
    /// app changed nothing, and the mic stayed dead until the app was
    /// force-quit. Recovery alone isn't enough, because the failure that
    /// survives backgrounding is exactly the one it can't fix (see
    /// `AudioRecorder.restartEngine`).
    private func repairIfNeeded() {
        guard isActive, !recorder.isEngineHealthy else { return }
        guard reviveEngine() else {
            // Out of options, and the user is standing right here — no reason to
            // sit on the watchdog's budget. Drop the session so `isActive` stops
            // claiming a microphone we don't have (the app said "Voice keyboard
            // ready" throughout this failure) and so the next foreground takes
            // the clean `start()` path instead of landing here again.
            lastError = AudioRecorderError.engineUnavailable.localizedDescription
            stop()
            return
        }
        lastError = nil
        unhealthySince = nil
        // Don't make the keyboard wait out the 2s timer to learn we're back.
        beat()
    }

    func start() async {
        // `start()` suspends on the permission request, so two foreground
        // triggers arriving together (launch and scene-active) could both clear
        // the `isActive` guard and run the body twice — installing a second
        // heartbeat timer and a second set of observers, with only the last of
        // each retained and the rest leaked and firing forever.
        if let startInFlight {
            await startInFlight.value
            return
        }
        guard !isActive else { return }
        let task = Task { @MainActor in await performStart() }
        startInFlight = task
        await task.value
        startInFlight = nil
    }

    private func performStart() async {
        guard await AudioRecorder.requestPermission() else {
            lastError = AudioRecorderError.microphonePermissionDenied.localizedDescription
            return
        }
        do {
            try recorder.startEngine()
            // startEngine() is a no-op when it believes the engine is already
            // running, so a wedged engine left over from a previous session
            // would otherwise be adopted as a live one — never publish a
            // heartbeat for a microphone that isn't actually recording.
            if !recorder.isEngineHealthy { try recorder.restartEngine() }
        } catch {
            lastError = error.localizedDescription
            return
        }

        isActive = true
        startedAt = .now
        lastError = nil

        commandToken = DarwinNotifier.observe(.commandPosted) {
            Task { @MainActor in SessionController.shared.handlePendingCommands() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .ended
            Task { @MainActor in
                if ended { _ = SessionController.shared.reviveEngine() }
            }
        }

        beat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SessionController.shared.beat() }
        }

        scheduleAutoEnd()

        DictationBridge.publish(PipelineState(phase: .idle))
        // Catch a command the keyboard may have queued while we were starting.
        handlePendingCommands()
    }

    /// (Re)arms the idle auto-end timer. Called on start and on every
    /// dictation so the window measures inactivity, not session age — an
    /// actively used session never expires mid-use. 0 minutes means never.
    private func scheduleAutoEnd() {
        autoEndTimer?.invalidate()
        autoEndTimer = nil
        let minutes = SettingsStore.load().sessionAutoEndMinutes
        guard minutes > 0 else { return }
        autoEndTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes * 60),
            repeats: false
        ) { _ in
            Task { @MainActor in SessionController.shared.stop() }
        }
    }

    func stop() {
        guard isActive else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        autoEndTimer?.invalidate()
        autoEndTimer = nil
        commandToken = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        recorder.stopEngine()
        isActive = false
        startedAt = nil
        activeCommand = nil
        unhealthySince = nil
        DictationBridge.publish(nil as SessionHeartbeat?)
        DictationBridge.publish(PipelineState(phase: .idle))
    }

    /// The heartbeat doubles as an engine watchdog. If the engine was
    /// interrupted (a call, Siri, another audio app, the screen locking) it
    /// tries to bring it back — and does NOT tear the session down for a
    /// transient failure, or the user would have to reopen the app after every
    /// blip. While the engine is unhealthy it simply withholds the heartbeat,
    /// so the keyboard shows "open the app" for the outage and resumes on its
    /// own once recovery succeeds (or the app is foregrounded).
    private func beat() {
        guard startedAt != nil else { return }
        guard reviveEngine() else {
            // Past the budget, this isn't an outage — it's a session that will
            // never beat again. Left standing it is invisible to the user (the
            // app claims the keyboard is ready) and unfixable without a force
            // quit, so declare it dead: the keyboard's "open the app" prompt
            // becomes true, and the next foreground takes the clean start path.
            let since = unhealthySince ?? .now
            unhealthySince = since
            if Date.now.timeIntervalSince(since) >= Self.unrecoverableAfter {
                lastError = AudioRecorderError.engineUnavailable.localizedDescription
                stop()
            }
            return
        }
        unhealthySince = nil
        DictationBridge.publish(SessionHeartbeat(startedAt: startedAt ?? .now, lastBeatAt: .now))
    }

    /// Brings the engine back if it died under us, escalating from a cheap kick
    /// to a full rebuild. Returns whether the engine is healthy afterwards.
    @discardableResult
    private func reviveEngine() -> Bool {
        if recorder.isEngineHealthy { return true }
        try? recorder.recoverEngine()
        if recorder.isEngineHealthy { return true }
        // Recovery reuses a tap bound to the input format sampled at start, so
        // an interruption that changed the route wedges it permanently — every
        // later attempt throws the same error. Only a rebuild clears that.
        try? recorder.restartEngine()
        return recorder.isEngineHealthy
    }

    // MARK: Command handling

    private func handlePendingCommands() {
        guard isActive else { return }
        for command in DictationBridge.commandQueue() {
            guard !handledCommandIDs.contains(command.id) else { continue }
            handledCommandIDs.append(command.id)
            if handledCommandIDs.count > 64 { handledCommandIDs.removeFirst(32) }
            guard Date.now.timeIntervalSince(command.issuedAt) < Self.commandMaxAge else { continue }
            execute(command)
        }
    }

    private func execute(_ command: KeyboardCommand) {
        // Any dictation activity resets the idle auto-end window.
        scheduleAutoEnd()
        switch command.kind {
        case .startDictation:
            guard activeCommand == nil else { return }
            activeCommand = command
            recorder.beginCapture()
            DictationBridge.publish(PipelineState(phase: .recording, commandID: command.id))
            // The user is talking now, and the providers their transcript will
            // visit are already known — so get the handshakes and the
            // on-device model out of the way here, where the wait is free,
            // instead of after they stop, where every millisecond is felt.
            let settings = SettingsStore.load()
            let style = SharedCatalog.style(id: command.styleID) ?? .light
            Task { await DictationPipeline(settings: settings).prewarm(style: style) }

        case .stopDictation:
            // Results are attributed to the START command's id; the keyboard
            // remembers that id and matches it when the result arrives.
            guard let active = activeCommand else { return }
            activeCommand = nil
            let wav = recorder.endCapture()
            DictationBridge.publish(PipelineState(phase: .transcribing, commandID: active.id))
            runPipeline(command: active, wavData: wav)

        case .cancelDictation:
            activeCommand = nil
            recorder.cancelCapture()
            DictationBridge.publish(PipelineState(phase: .idle))
        }
    }

    private func runPipeline(command: KeyboardCommand, wavData: Data) {
        let settings = SettingsStore.load()
        let style = SharedCatalog.style(id: command.styleID) ?? .light

        Task {
            do {
                let outcome = try await DictationPipeline(settings: settings)
                    .run(wavData: wavData, style: style)
                DictationBridge.publish(DictationResult(
                    commandID: command.id,
                    styleID: style.id,
                    rawText: outcome.rawText,
                    polishedText: outcome.polishedText
                ))
                saveHistory(outcome: outcome, styleID: style.id)
            } catch {
                DictationBridge.publish(DictationResult(
                    commandID: command.id,
                    styleID: style.id,
                    rawText: "",
                    polishedText: "",
                    errorMessage: error.localizedDescription
                ))
            }
            DictationBridge.publish(PipelineState(phase: .idle))
        }
    }

    private func saveHistory(outcome: DictationPipeline.Outcome, styleID: String) {
        let context = modelContainer.mainContext
        context.insert(TranscriptRecord(
            rawText: outcome.rawText,
            polishedText: outcome.polishedText,
            styleID: styleID,
            source: .keyboard,
            engineName: outcome.engineName,
            audioSeconds: outcome.audioSeconds
        ))
        // Save explicitly rather than trusting autosave. These inserts happen
        // while the app is backgrounded behind the keyboard, and autosave is
        // driven by the run loop and app-lifecycle events — a suspension can
        // land before it ever fires, silently losing the transcript the user
        // just dictated. Failing to persist history must not take down the
        // dictation itself (the text is already on its way to the keyboard),
        // so this surfaces the error rather than throwing.
        do {
            try context.save()
        } catch {
            lastError = "Couldn't save to history: \(error.localizedDescription)"
        }
    }

    // MARK: Level metering

    private func publishLevel(_ level: Float) {
        guard isActive, activeCommand != nil else { return }
        // Throttle bridge writes; the keyboard animates between updates.
        let now = Date.now
        guard now.timeIntervalSince(lastLevelPublish) > 0.15 else { return }
        lastLevelPublish = now
        DictationBridge.publish(PipelineState(
            phase: .recording,
            commandID: activeCommand?.id,
            audioLevel: level
        ))
    }
}
