import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var model: VoicePanelModel?

    /// The keyboard background must be the system's *material*, not a color we
    /// picked. Hosts draw furniture we can't paint — iMessage insets our input
    /// view inside a rounded container band, and iOS draws the globe row below
    /// it — both filled with the real keyboard backdrop. Every hand-matched
    /// gray (the lavender wash, then `systemGray4`) landed a shade off, so the
    /// panel read as a darker rectangle sandwiched between them.
    ///
    /// `UIInputView` with the `.keyboard` style *is* that backdrop: it renders
    /// the same blur/vibrancy the system keyboard uses and tracks light/dark,
    /// host appearance, and any future system restyle for free. It only works
    /// if nothing paints over it, so `view.backgroundColor` stays nil and the
    /// SwiftUI host is clear.
    override func loadView() {
        view = UIInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let model = VoicePanelModel(needsInputModeSwitchKey: needsInputModeSwitchKey)
        model.onGlobe = { [weak self] in self?.advanceToNextInputMode() }
        model.insertTextHandler = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        model.deleteBackwardHandler = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.dismissKeyboardHandler = { [weak self] in self?.dismissKeyboard() }
        self.model = model

        let panel = UIHostingController(rootView: VoicePanelView(model: model).tint(Color.appAccent))
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        panel.view.backgroundColor = .clear
        panel.safeAreaRegions = []
        addChild(panel)
        view.addSubview(panel.view)
        panel.didMove(toParent: self)

        // A floor, not a fixed height. `UIInputView` is sized by the system to
        // the host's reserved keyboard frame unless `allowsSelfSizing` is set,
        // which is why pinning this to 291 once changed nothing — so let the
        // host drive the height and fill whatever it gives us. This only stops
        // hosts that offer an unusually short frame from crushing the panel
        // below its content (mic + status + control row ≈ 244pt). Priority 999
        // yields to the system's own height rather than logging a conflict.
        let heightConstraint = view.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        heightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            panel.view.topAnchor.constraint(equalTo: view.topAnchor),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heightConstraint,
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model?.activate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        model?.deactivate()
        super.viewWillDisappear(animated)
    }
}
