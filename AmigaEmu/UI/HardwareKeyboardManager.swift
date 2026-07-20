import Foundation
import GameController

/// Bluetooth / Smart Connector hardware keyboards → real Amiga key-down/up.
///
/// The UIKeyInput responder (keyboard mode) never sees hardware keys on a
/// custom responder, and text insertion has no held-key semantics anyway.
/// GCKeyboard reports every physical key transition, so:
///   • holding a key repeats/holds inside the guest (games!)
///   • shift/ctrl/alt/⌘ work as REAL modifiers (the Amiga does the shifting)
///   • the keyboard works in EVERY input mode (type while the joystick
///     overlay is up)
/// ⌘ maps to the Amiga keys (left ⌘ → ◆L, right ⌘ → ◆R). Started once from
/// EmulatorController.bootstrap(); a keyboard disconnect releases exactly the
/// keys it was holding.
final class HardwareKeyboardManager {
    static let shared = HardwareKeyboardManager()
    private let bridge = EmulatorBridge.shared()
    private var started = false
    /// HID codes currently held — released precisely on disconnect.
    private var heldHID: Set<Int> = []

    /// True while a physical keyboard is attached (used by the soft-keyboard
    /// responder paths to avoid double input).
    static var isConnected: Bool { GCKeyboard.coalesced != nil }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
            if let kb = note.object as? GCKeyboard { self?.attach(kb) }
        }
        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.releaseHeld()
        }
        if let kb = GCKeyboard.coalesced { attach(kb) }
    }

    private func attach(_ keyboard: GCKeyboard) {
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            let hid = keyCode.rawValue
            guard let amiga = Self.hidToAmiga[hid] else { return }
            DispatchQueue.main.async {
                if pressed {
                    self.heldHID.insert(hid)
                    self.bridge.keyDown(amiga)
                } else {
                    self.heldHID.remove(hid)
                    self.bridge.keyUp(amiga)
                }
            }
        }
    }

    private func releaseHeld() {
        for hid in heldHID {
            if let amiga = Self.hidToAmiga[hid] { bridge.keyUp(amiga) }
        }
        heldHID.removeAll()
    }

    /// USB HID keyboard usage → raw Amiga keycode.
    private static let hidToAmiga: [Int: UInt8] = {
        var map: [Int: UInt8] = [:]
        // Letters a–z: HID 4…29.
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            if let code = AmigaKey.unshifted[ch] { map[4 + i] = code }
        }
        // Digits 1–9, 0: HID 30…39.
        for (i, ch) in "1234567890".enumerated() {
            if let code = AmigaKey.unshifted[ch] { map[30 + i] = code }
        }
        map[40] = AmigaKey.enter
        map[41] = AmigaKey.esc
        map[42] = AmigaKey.backspace
        map[43] = AmigaKey.tab
        map[44] = AmigaKey.space
        map[45] = AmigaKey.minus
        map[46] = AmigaKey.equal
        map[47] = AmigaKey.leftBracket
        map[48] = AmigaKey.rightBracket
        map[49] = AmigaKey.backslash
        map[51] = AmigaKey.semicolon
        map[52] = AmigaKey.quote
        map[53] = AmigaKey.backtick
        map[54] = AmigaKey.comma
        map[55] = AmigaKey.period
        map[56] = AmigaKey.slash
        map[57] = AmigaKey.capsLock
        for n in 1...10 { map[58 + (n - 1)] = AmigaKey.f(n) }   // F1–F10
        map[73] = AmigaKey.help      // Insert → Help (no Insert on the Amiga)
        map[76] = AmigaKey.del       // forward-delete
        map[79] = AmigaKey.right
        map[80] = AmigaKey.left
        map[81] = AmigaKey.down
        map[82] = AmigaKey.up
        map[117] = AmigaKey.help     // dedicated Help key
        map[224] = AmigaKey.ctrl     // left ctrl (Amiga has one Ctrl)
        map[225] = AmigaKey.lshift
        map[226] = AmigaKey.lalt
        map[227] = AmigaKey.lAmiga   // left ⌘
        map[228] = AmigaKey.ctrl     // right ctrl
        map[229] = AmigaKey.rshift
        map[230] = AmigaKey.ralt
        map[231] = AmigaKey.rAmiga   // right ⌘
        return map
    }()
}
