import SwiftUI

/// The keyboard's dictation surface, laid out like Typeless: a header with the
/// brand mark and context control on the left and the Dictate/Translate toggle
/// on the right; then a centered stadium mic with a `return` pill beneath it,
/// and the secondary keys in a column pinned to the trailing edge. All colors
/// are semantic so the panel adapts to the host app's light or dark keyboard.
struct VoicePanelView: View {
    @Bindable var model: VoicePanelModel
    @Namespace private var modeHighlight

    // Typeless's proportions, measured off its keyboard at 393pt wide and kept
    // fixed rather than proportional: these are thumb targets, so they should
    // not grow with the screen the way a layout container would.
    private let micSize = CGSize(width: 136, height: 62)
    private let returnSize = CGSize(width: 112, height: 42)
    private let utilityKeySide: CGFloat = 36

    var body: some View {
        VStack(spacing: 8) {
            headerRow
            Spacer(minLength: 6)
            actionCluster
            // Typeless settles `return` near the panel's bottom edge rather
            // than centering the cluster in the leftover space. Capping the
            // trailing spacer sends the slack to the flexible one above, so a
            // host that hands us a tall frame grows the gap under the header
            // instead of stranding the keys in the middle.
            Spacer(minLength: 0).frame(maxHeight: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Keep controls reachable on iPad instead of stretching edge to edge.
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        // Deliberately no background: the panel sits directly on the system
        // keyboard material supplied by the `UIInputView` in
        // KeyboardViewController, so iMessage's container band above us and the
        // globe row below are the same backdrop with no visible seam. Anything
        // opaque here — even a subtle wash — reintroduces that seam. The brand
        // lives in the colored controls instead.
    }

    /// Elevated key-cap look shared by all tappable keys — white (or lifted
    /// gray in dark keyboards) with a crisp edge shadow, like system keys.
    private func keycap(cornerRadius: CGFloat = 9) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.keyCap)
            .shadow(color: .black.opacity(0.22), radius: 0.5, y: 1)
    }

    // MARK: Header

    /// Mark + context on the left, mode toggle hard right — Typeless's header
    /// split. The toggle no longer needs the centering overlay it used to use,
    /// because it's now pinned to an edge rather than floated in the middle.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LinearGradient.brandMark)
                .accessibilityLabel("Voice Typer")

            contextControl

            Spacer(minLength: 8)

            modeToggle
        }
    }

    /// Dictate (waveform) | Translate (dictionary), with a gradient thumb
    /// that slides between them and the active glyph animating on select.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeSegment("waveform", label: "Dictate", mode: .dictate)
            modeSegment("character.book.closed", label: "Translate", mode: .translate)
        }
        .padding(3)
        .background(.quaternary, in: Capsule())
        .disabled(!model.canDictate)
    }

    private func modeSegment(_ systemImage: String, label: String, mode: VoicePanelModel.Mode) -> some View {
        let isOn = model.mode == mode
        return Button {
            withAnimation(.spring(duration: 0.3)) {
                model.setMode(mode)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .frame(width: 40, height: 28)
                .background {
                    if isOn {
                        Capsule()
                            .fill(LinearGradient.appAccentFill)
                            .matchedGeometryEffect(id: "thumb", in: modeHighlight)
                    }
                }
                .foregroundStyle(isOn ? .white : .primary)
                // Animate the glyph whenever this segment becomes active.
                .symbolEffect(.bounce, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Dictate mode: the template picker. Translate mode: where the words
    /// will land (target language is configured in the app's Settings).
    @ViewBuilder
    private var contextControl: some View {
        if model.mode == .translate {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.semibold))
                Text(model.targetLanguage)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appAccent.opacity(0.14), in: Capsule())
        } else {
            Menu {
                ForEach(model.dictateStyles) { style in
                    Button {
                        model.selectedStyleID = style.id
                    } label: {
                        if style.id == model.selectedStyleID {
                            Label(style.name, systemImage: "checkmark")
                        } else {
                            Text(style.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text(model.selectedStyleName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appAccent.opacity(0.14), in: Capsule())
            }
            .disabled(!model.canDictate)
        }
    }

    // MARK: Action cluster

    /// Typeless's arrangement: the primary control and `return` stacked down
    /// the panel's centerline, with the secondary keys in columns pinned to the
    /// edges — delete/undo trailing everywhere, globe/hide leading on iPad.
    /// Overlaying those columns instead of giving them rows of their own is
    /// what keeps the mic optically centered and lets the keys span the mic and
    /// `return` rows the way Typeless's do.
    private var actionCluster: some View {
        VStack(spacing: 10) {
            primaryArea
            returnKey
        }
        .frame(maxWidth: .infinity)
        // Overlays rather than stack siblings: neither column may take part in
        // laying the cluster out, or the mic stops being optically centered.
        .overlay(alignment: .leading) { systemKeyColumn }
        .overlay(alignment: .trailing) { utilityColumn }
    }

    @ViewBuilder
    private var primaryArea: some View {
        switch model.phase {
        case .noFullAccess:
            guidance(
                icon: "lock.shield",
                title: "Allow Full Access",
                message: "Settings → General → Keyboard → Keyboards → Voice Typer → Allow Full Access"
            )
        case .noSession:
            // A SwiftUI Link is the only reliable way to open the containing
            // app from a keyboard extension on iOS 18+ — Apple broke the old
            // selector/openURL responder-chain hack, and extensions can't call
            // UIApplication.open. Needs Full Access.
            Link(destination: VoicePanelModel.openAppURL) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.title2)
                    Text("Open Voice Typer")
                        .font(.subheadline.weight(.semibold))
                    Text("The mic turned off. Tap to reopen the app — it restarts automatically, then swipe back here to speak.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.appAccent)
                // Clear the utility column so the copy never runs under it.
                .padding(.horizontal, utilityKeySide + 16)
            }
        case .idle, .recording, .processing, .error:
            VStack(spacing: 10) {
                Text(model.statusText)
                    .font(model.phase.isError ? .caption : .footnote)
                    .foregroundStyle(model.phase.isError ? .red : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, utilityKeySide + 16)

                micKey
            }
        }
    }

    /// The stadium mic — Typeless's shape. A wide capsule is a much larger
    /// tap target than the circle it replaces at the same height, which is the
    /// point: this is the one control the user hits every time.
    private var micKey: some View {
        Button {
            model.toggleDictation()
        } label: {
            ZStack {
                Capsule()
                    .fill(
                        model.phase == .recording
                            ? LinearGradient.recordingFill
                            : LinearGradient.appAccentFill
                    )
                    .overlay(
                        // Hairline top-lit rim so the button reads as a glossy
                        // dome, not a flat disc (redesign recipe).
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8)
                            .blendMode(.plusLighter)
                    )
                    .frame(width: micSize.width, height: micSize.height)
                    .scaleEffect(model.phase == .recording ? 1 + CGFloat(model.audioLevel) * 0.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: model.audioLevel)
                    .shadow(
                        color: model.phase == .recording
                            ? Color.red.opacity(0.5)
                            : Color.appAccent.opacity(0.5),
                        radius: 11, y: 8
                    )
                if model.phase == .processing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .buttonStyle(KeyPressStyle())
        .disabled(model.phase == .processing)
        .accessibilityLabel(model.phase == .recording ? "Stop and insert" : "Tap to speak")
    }

    /// Inserts a newline — which is what "send" means in a chat host like
    /// iMessage. Named `return` after the key it actually is, as Typeless does.
    private var returnKey: some View {
        Button {
            model.insertText("\n")
        } label: {
            Text("return")
                .font(.subheadline.weight(.medium))
                .frame(width: returnSize.width, height: returnSize.height)
                .background { keycap(cornerRadius: returnSize.height / 2) }
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel("Return")
    }

    /// Globe and hide, stacked at the leading edge to mirror the utility
    /// column — and to sit where the system keyboard puts the same two keys.
    ///
    /// iPhone draws its own globe row *underneath* every custom keyboard, so
    /// this column would be a duplicate there and stays hidden. iPad draws no
    /// such row: without these keys the panel is a dead end — no way back to
    /// the alphabet keyboard and no way to put the keyboard away. That is
    /// exactly the condition `needsInputModeSwitchKey` reports, so it gates
    /// both keys rather than a device check.
    @ViewBuilder
    private var systemKeyColumn: some View {
        if model.needsInputModeSwitchKey {
            VStack(spacing: 10) {
                utilityKey("globe", label: "Next keyboard") {
                    model.switchToNextKeyboard()
                }
                .accessibilityIdentifier("ovt-next-keyboard")

                utilityKey("keyboard.chevron.compact.down", label: "Hide keyboard") {
                    model.dismissKeyboard()
                }
                .accessibilityIdentifier("ovt-hide-keyboard")
            }
        }
    }

    /// Delete and undo, stacked at the trailing edge. Typeless puts an "@" in
    /// the lower slot; undo is the better use of it here — the model already
    /// tracks the last insertion, and after a long dictation lands wrong,
    /// one tap beats holding delete.
    private var utilityColumn: some View {
        VStack(spacing: 10) {
            HoldRepeatKey {
                model.deleteBackward()
            } label: { isPressed in
                utilityKeyFace("delete.left", isPressed: isPressed)
            }
            // A gesture-driven view is not a Button, so the trait and the
            // activation action have to be restated or VoiceOver sees an inert
            // image and offers no way to delete at all.
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.deleteBackward() }

            utilityKey("arrow.uturn.backward", label: "Undo dictation") {
                model.undoLastInsert()
            }
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.4)
        }
    }

    private func utilityKey(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            utilityKeyFace(systemImage, isPressed: false)
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(label)
    }

    private func utilityKeyFace(_ systemImage: String, isPressed: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.footnote)
            .frame(width: utilityKeySide, height: utilityKeySide)
            .background { keycap(cornerRadius: utilityKeySide / 2) }
            .opacity(isPressed ? KeyPressStyle.pressedOpacity : 1)
            .scaleEffect(isPressed ? KeyPressStyle.pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    private func guidance(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        // Clear the utility column so the copy never runs under it.
        .padding(.horizontal, utilityKeySide + 16)
    }
}

/// Touch feedback for keys. `.buttonStyle(.plain)` draws no pressed state at
/// all, so every key on this panel used to look inert under the thumb while
/// system keys visibly react — the one cue that a tap registered on a surface
/// where the result (inserted text) is often off-screen behind the keyboard.
private struct KeyPressStyle: ButtonStyle {
    static let pressedOpacity: Double = 0.55
    static let pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Self.pressedOpacity : 1)
            .scaleEffect(configuration.isPressed ? Self.pressedScale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A key that fires once on touch-down and then repeats while held, matching
/// the system keyboard's delete cadence (~0.4s before the run starts, then
/// about eleven a second).
///
/// A plain Button fires once on release, which made holding ⌫ appear broken:
/// the only way to clear a dictation that landed wrong was to tap once per
/// character. It's built on a 0-distance DragGesture rather than a Button
/// because the repeat has to begin on touch-*down* and end on lift, and a
/// Button exposes neither edge.
private struct HoldRepeatKey<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label

    /// UIKit's key-repeat timings.
    private static var delay: Duration { .milliseconds(400) }
    private static var interval: Duration { .milliseconds(90) }

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label(isPressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // onChanged fires repeatedly as the thumb settles; only
                        // the first crossing is the actual press.
                        guard !isPressed else { return }
                        isPressed = true
                        action()
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(for: Self.delay)
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: Self.interval)
                            }
                        }
                    }
                    .onEnded { _ in endPress() }
            )
            // A keyboard can be torn down mid-hold (the host dismisses it, the
            // user switches keyboards); without this the loop would keep
            // deleting into a proxy that is no longer ours.
            .onDisappear(perform: endPress)
    }

    private func endPress() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}
