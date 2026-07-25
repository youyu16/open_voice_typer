import SwiftUI

/// In-app dictation: record, transcribe, polish, copy. There is no
/// user-facing "session" — opening the app keeps the microphone ready in
/// the background (that's what powers the keyboard in other apps), and the
/// mic button here rides the same engine.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var model = HomeViewModel()
    @State private var session = SessionController.shared

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundWash
                VStack(spacing: 20) {
                    styleChips
                    Spacer()
                    recordButton
                    statusZone
                    Spacer()
                    resultSection
                    keyboardFooter
                }
                .padding()
                .animation(.spring(duration: 0.4), value: model.polishedText.isEmpty)
            }
            .navigationTitle("Open Voice Typer")
            .sensoryFeedback(.impact(weight: .medium), trigger: model.isRecording)
            .sensoryFeedback(.success, trigger: model.polishedText.isEmpty) { old, new in
                old && !new
            }
            .onAppear {
                model.onCompleted = { record in modelContext.insert(record) }
            }
            .alert("Dictation failed", isPresented: $model.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage)
            }
        }
    }

    /// A quiet accent mesh flowing out of the top corners — enough depth
    /// that the glass surfaces have something to refract, never loud.
    private var backgroundWash: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                // Teal glows out of the top-right and fades into indigo — the
                // brand two-tone, kept quiet as an ambient wash.
                Color.appAccent.opacity(0.32), Color.appAccentLight.opacity(0.16), Color.appTeal.opacity(0.22),
                Color.appAccent.opacity(0.10), Color.appAccent.opacity(0.03), Color.appTeal.opacity(0.06),
                Color.clear, Color.appAccent.opacity(0.04), Color.clear,
            ]
        )
        .ignoresSafeArea()
    }

    /// Template picker as glass capsule chips — same design language as
    /// History's filters, and it doesn't cramp when custom templates exist.
    private var styleChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.styles) { style in
                    let isOn = style.id == model.selectedStyleID
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            model.selectedStyleID = style.id
                        }
                    } label: {
                        Text(style.name)
                            .font(.subheadline.weight(isOn ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if isOn {
                                    Capsule().fill(LinearGradient.appAccentFill)
                                        .shadow(color: Color.appAccent.opacity(0.3), radius: 6, y: 3)
                                } else {
                                    Capsule().fill(.ultraThinMaterial)
                                    Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                                }
                            }
                            .foregroundStyle(isOn ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
        }
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.5 : 1)
    }

    private var recordButton: some View {
        Button(action: { model.toggleRecording() }) {
            ZStack {
                if model.isRecording {
                    PulseRing(delay: 0)
                    PulseRing(delay: 0.7)
                }
                // Frosted halo the colored button sits on — the glass reads
                // against the mesh behind it.
                Circle()
                    .fill(.clear)
                    .frame(width: 134, height: 134)
                    .glassEffect(.regular, in: .circle)
                Circle()
                    .fill(model.isRecording ? LinearGradient.recordingFill : .appAccentFill)
                    .frame(width: 106, height: 106)
                    .scaleEffect(1 + CGFloat(model.audioLevel) * 0.3)
                    .animation(.easeOut(duration: 0.1), value: model.audioLevel)
                    .shadow(
                        color: (model.isRecording ? Color.red : Color.appAccent).opacity(0.5),
                        radius: 22, y: 11
                    )
                    .overlay {
                        // Specular top edge, like a pressed glass bead.
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.5
                            )
                    }
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(width: 190, height: 190)
            .animation(.spring(duration: 0.35), value: model.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(model.isTranscribing)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")
    }

    /// Fixed-height zone under the button: hint → live waveform + elapsed
    /// time → progress. Fixed so the button never jumps between states.
    private var statusZone: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .idle:
                Text("Tap to dictate")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            case .recording:
                LiveWaveform(levels: model.levelHistory)
                    .transition(.opacity)
                if let beganAt = model.recordingBeganAt {
                    TimelineView(.periodic(from: beganAt, by: 0.5)) { context in
                        Text(
                            Duration.seconds(context.date.timeIntervalSince(beganAt)),
                            format: .time(pattern: .minuteSecond)
                        )
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    }
                    .transition(.opacity)
                }
            case .transcribing:
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(LinearGradient.brandMark)
                    Text("Transcribing & polishing…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .frame(height: 64)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
    }

    @ViewBuilder
    private var resultSection: some View {
        if !model.polishedText.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Result", systemImage: "text.quote")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    CopyButton(text: model.polishedText)
                }
                // Hug short results; long ones truncate — the full text is
                // one tap away in History and Copy always copies everything.
                Text(model.polishedText)
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if model.rawText != model.polishedText {
                    DisclosureGroup("Raw transcript") {
                        Text(model.rawText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// One quiet line about the keyboard, in place of the old session card.
    private var keyboardFooter: some View {
        Group {
            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if session.isActive {
                Label("Voice keyboard ready — dictate in any app.", systemImage: "keyboard")
                    .foregroundStyle(.secondary)
            } else {
                Label("Microphone is off — it turns on whenever this app opens.", systemImage: "mic.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
    }
}

/// Expanding ring that radiates from the mic button while recording.
private struct PulseRing: View {
    let delay: Double
    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.4), lineWidth: 2)
            .frame(width: 106, height: 106)
            .scaleEffect(animating ? 1.7 : 1)
            .opacity(animating ? 0 : 0.8)
            .animation(
                .easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(delay),
                value: animating
            )
            .onAppear { animating = true }
    }
}

/// Voice Memos-style live level meter: recent mic levels as bars, newest
/// on the right.
private struct LiveWaveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient.recordingFill)
                    .frame(width: 3, height: 5 + CGFloat(levels[index]) * 38)
            }
        }
        .frame(height: 44)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// Copy with a moment of visible confirmation.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .tint(copied ? .green : .appAccent)
    }
}

@MainActor
@Observable
final class HomeViewModel {
    enum HomePhase: Equatable {
        case idle
        case recording
        case transcribing
    }

    var styles: [Style] = SharedCatalog.loadStyles()
    var selectedStyleID: String = SettingsStore.load().selectedStyleID {
        didSet {
            var settings = SettingsStore.load()
            settings.selectedStyleID = selectedStyleID
            if selectedStyleID != Style.translate.id {
                settings.lastDictateStyleID = selectedStyleID
            }
            SettingsStore.save(settings)
        }
    }

    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    /// Rolling window of recent mic levels feeding the live waveform.
    var levelHistory: [Float] = HomeViewModel.flatWaveform
    var recordingBeganAt: Date?
    var rawText = ""
    var polishedText = ""
    var showError = false
    var errorMessage = ""
    var onCompleted: ((TranscriptRecord) -> Void)?

    private static let flatWaveform = [Float](repeating: 0, count: 28)

    var isBusy: Bool { isRecording || isTranscribing }

    var phase: HomePhase {
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        return .idle
    }

    private let session = SessionController.shared

    init() {
        session.onUILevel = { [weak self] level in
            guard let self else { return }
            guard isRecording else {
                audioLevel = 0
                return
            }
            audioLevel = level
            levelHistory.removeFirst()
            levelHistory.append(level)
        }
    }

    func toggleRecording() {
        isRecording ? finishRecording() : startRecording()
    }

    private func startRecording() {
        Task {
            // In-app dictation shares the background engine that serves the
            // keyboard; first ever tap prompts for mic permission via start().
            if !session.isActive {
                await session.start()
            }
            guard session.isActive else {
                errorMessage = session.lastError
                    ?? AudioRecorderError.microphonePermissionDenied.localizedDescription
                showError = true
                return
            }
            session.recorder.beginCapture()
            isRecording = true
            recordingBeganAt = Date()
            levelHistory = Self.flatWaveform
            rawText = ""
            polishedText = ""
        }
    }

    private func finishRecording() {
        // The engine keeps running for the keyboard; only the capture ends.
        let wav = session.recorder.endCapture()
        isRecording = false
        recordingBeganAt = nil
        levelHistory = Self.flatWaveform
        isTranscribing = true

        let settings = SettingsStore.load()
        let style = SharedCatalog.style(id: selectedStyleID) ?? .light
        Task {
            defer { isTranscribing = false }
            do {
                let outcome = try await DictationPipeline(settings: settings).run(wavData: wav, style: style)
                rawText = outcome.rawText
                polishedText = outcome.polishedText
                onCompleted?(TranscriptRecord(
                    rawText: outcome.rawText,
                    polishedText: outcome.polishedText,
                    styleID: style.id,
                    source: .app,
                    engineName: outcome.engineName,
                    audioSeconds: outcome.audioSeconds,
                    totalMilliseconds: outcome.totalMilliseconds,
                    asrMilliseconds: outcome.asrMilliseconds,
                    polishMilliseconds: outcome.polishMilliseconds
                ))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

#Preview {
    HomeView()
}
