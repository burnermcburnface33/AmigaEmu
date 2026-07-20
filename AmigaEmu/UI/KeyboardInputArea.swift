import SwiftUI
import UIKit

/// Keyboard input mode: brings up the iOS system keyboard (mapping typed
/// characters → raw Amiga keycodes) and floats an accessory bar of the
/// special keys the soft keyboard lacks (esc, modifiers, Amiga keys, arrows).
struct KeyboardInputArea: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AmigaKeyboardController { AmigaKeyboardController() }
    func updateUIViewController(_ vc: AmigaKeyboardController, context: Context) {}
}

final class AmigaKeyboardController: UIViewController, UIKeyInput {
    private let bridge = EmulatorBridge.shared()
    private var latched: Set<UInt8> = []

    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// Leaving keyboard mode destroys this controller — release any latched
    /// modifiers first or they'd stay held down in the core forever.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for code in latched { bridge.keyUp(code) }
        latched.removeAll()
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        for ch in text {
            switch ch {
            case "\n": tap(AmigaKey.enter)
            case "\t": tap(AmigaKey.tab)
            default:
                guard let r = AmigaKey.resolve(ch) else { continue }
                if r.shift { bridge.keyDown(AmigaKey.lshift) }
                bridge.keyDown(r.code); bridge.keyUp(r.code)
                if r.shift { bridge.keyUp(AmigaKey.lshift) }
            }
        }
    }

    func deleteBackward() { tap(AmigaKey.backspace) }

    private func tap(_ code: UInt8) { bridge.keyDown(code); bridge.keyUp(code) }

    // MARK: Accessory bar

    private lazy var accessory: UIView = makeAccessory()
    override var inputAccessoryView: UIView? { accessory }

    private func makeAccessory() -> UIView {
        // Two rows so the function keys are present in portrait too (matching
        // dospad/DOSBox, which surfaces F-keys in both orientations).
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 98),
                              inputViewStyle: .keyboard)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
        ])

        // Row 1 — special keys + arrows.
        stack.addArrangedSubview(makeRow([
            momentary("esc", AmigaKey.esc),
            latch("ctrl", AmigaKey.ctrl),
            latch("◆L", AmigaKey.lAmiga),
            latch("◆R", AmigaKey.rAmiga),
            latch("alt", AmigaKey.lalt),
            momentary("←", AmigaKey.left),
            momentary("↑", AmigaKey.up),
            momentary("↓", AmigaKey.down),
            momentary("→", AmigaKey.right),
        ]))
        // Row 2 — function keys F1–F10.
        stack.addArrangedSubview(makeRow((1...10).map { momentary("F\($0)", AmigaKey.f($0)) }))
        return bar
    }

    private func makeRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 5
        return row
    }

    private func styled(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.5
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(white: 0.22, alpha: 1)
        b.layer.cornerRadius = 6
        b.tag = 0
        return b
    }

    private func momentary(_ title: String, _ code: UInt8) -> UIButton {
        let b = styled(title)
        objc_setAssociatedObject(b, &codeKey, NSNumber(value: code), .OBJC_ASSOCIATION_RETAIN)
        b.addTarget(self, action: #selector(momentaryDown(_:)), for: [.touchDown, .touchDragEnter])
        b.addTarget(self, action: #selector(momentaryUp(_:)),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return b
    }

    private func latch(_ title: String, _ code: UInt8) -> UIButton {
        let b = styled(title)
        objc_setAssociatedObject(b, &codeKey, NSNumber(value: code), .OBJC_ASSOCIATION_RETAIN)
        b.addTarget(self, action: #selector(latchTapped(_:)), for: .touchUpInside)
        return b
    }

    private func code(of b: UIButton) -> UInt8 {
        (objc_getAssociatedObject(b, &codeKey) as? NSNumber)?.uint8Value ?? 0
    }

    @objc private func momentaryDown(_ s: UIButton) { Haptics.tap(); bridge.keyDown(code(of: s)) }
    @objc private func momentaryUp(_ s: UIButton)   { bridge.keyUp(code(of: s)) }
    @objc private func latchTapped(_ s: UIButton) {
        let c = code(of: s)
        Haptics.tap()
        if latched.contains(c) {
            latched.remove(c); bridge.keyUp(c)
            s.backgroundColor = UIColor(white: 0.22, alpha: 1)
        } else {
            latched.insert(c); bridge.keyDown(c)
            s.backgroundColor = .systemBlue
        }
    }
}

private var codeKey: UInt8 = 0
