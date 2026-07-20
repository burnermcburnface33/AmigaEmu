import Foundation

/// User-editable D-pad layout — a list of custom buttons placed on the right
/// side of the D-pad overlay (the joystick arrow cluster on the left is always
/// the standard inverted-T and not customizable). Mirrors the AppleIIGS/dospad
/// design, adapted for the Amiga: a custom button either fires the joystick
/// (`keyCode == fireCode`) or sends a raw Amiga keycode.
///
/// Layouts are persisted per-emulator in UserDefaults.
struct DPadLayout: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var buttons: [DPadCustomButton]

    init(id: UUID = UUID(), name: String, buttons: [DPadCustomButton]) {
        self.id = id; self.name = name; self.buttons = buttons
    }

    /// Bootstrap layout — a FIRE button (joystick) plus Space, the two actions
    /// most Amiga games map to.
    static let `default` = DPadLayout(
        name: "Default",
        buttons: [
            DPadCustomButton(label: "FIRE", keyCode: DPadCustomButton.fireCode,
                             positionX: 0.62, positionY: 0.58),
            DPadCustomButton(label: "SPC", keyCode: Int(AmigaKey.space),
                             positionX: 0.28, positionY: 0.32),
        ])

    /// Default non-overlapping placement for `total` buttons in the short/wide
    /// landscape input area — clusters toward the right edge, wraps past four.
    static func landscapeSlot(_ i: Int, total: Int) -> (x: Double, y: Double) {
        let n = max(total, 1)
        let perRow = n <= 4 ? n : (n + 1) / 2
        let rows = (n + perRow - 1) / perRow
        let col = i % perRow
        let row = i / perRow
        let x: Double = perRow <= 1 ? 0.80
            : 0.50 + (0.95 - 0.50) * Double(col) / Double(perRow - 1)
        let y: Double = rows <= 1 ? 0.50
            : 0.30 + (0.74 - 0.30) * Double(row) / Double(rows - 1)
        return (x, y)
    }
}

/// One customizable button. Coordinates are normalized (0..1) within the right
/// half of the overlay so layouts survive rotation / different screen sizes.
struct DPadCustomButton: Codable, Hashable, Identifiable {
    /// Sentinel keyCode: pull the joystick fire button instead of sending a key.
    static let fireCode = -1

    let id: UUID
    var label: String
    /// `fireCode` (-1) = joystick fire; otherwise a raw Amiga keycode (0x00–0x67).
    var keyCode: Int
    var positionX: Double
    var positionY: Double
    var landscapeX: Double?
    var landscapeY: Double?
    /// If true, tap toggles down/up (good for modifiers held while another key
    /// is pressed). If false the button is momentary (down on touch, up on release).
    var latching: Bool

    init(id: UUID = UUID(), label: String, keyCode: Int,
         positionX: Double, positionY: Double, latching: Bool = false,
         landscapeX: Double? = nil, landscapeY: Double? = nil) {
        self.id = id; self.label = label; self.keyCode = keyCode
        self.positionX = positionX; self.positionY = positionY
        self.landscapeX = landscapeX; self.landscapeY = landscapeY
        self.latching = latching
    }

    var isFire: Bool { keyCode == Self.fireCode }
}

// ─────────────────────────────────────────────────────────────────────
// Amiga key catalogue for the customizer's key picker + the lookup table
// when displaying a saved layout. Codes are raw Amiga keycodes (see
// AmigaKeymap.swift) — what EmulatorBridge.keyDown(_:) expects.
// ─────────────────────────────────────────────────────────────────────
struct AmigaKeyItem: Identifiable, Hashable {
    let symbol: String
    let code: Int          // Amiga keycode, or DPadCustomButton.fireCode for FIRE
    let category: Category

    var id: Int { code }

    enum Category: String, CaseIterable, Identifiable {
        case special   = "Special"
        case letters   = "Letters"
        case numbers   = "Numbers"
        case symbols   = "Symbols"
        case modifiers = "Modifiers"
        case arrows    = "Arrows"
        case function  = "F-keys"
        var id: String { rawValue }
    }

    static let all: [AmigaKeyItem] = {
        var out: [AmigaKeyItem] = []
        // Special actions.
        out.append(AmigaKeyItem(symbol: "FIRE", code: DPadCustomButton.fireCode, category: .special))
        out.append(AmigaKeyItem(symbol: "SPC",  code: Int(AmigaKey.space),     category: .special))
        out.append(AmigaKeyItem(symbol: "RET",  code: Int(AmigaKey.enter),     category: .special))
        out.append(AmigaKeyItem(symbol: "ESC",  code: Int(AmigaKey.esc),       category: .special))
        out.append(AmigaKeyItem(symbol: "TAB",  code: Int(AmigaKey.tab),       category: .special))
        out.append(AmigaKeyItem(symbol: "⌫",    code: Int(AmigaKey.backspace), category: .special))
        out.append(AmigaKeyItem(symbol: "DEL",  code: Int(AmigaKey.del),       category: .special))
        // Letters A–Z (uppercase symbol → lowercase keycode).
        for c in "abcdefghijklmnopqrstuvwxyz" {
            if let code = AmigaKey.unshifted[c] {
                out.append(AmigaKeyItem(symbol: String(c).uppercased(), code: Int(code), category: .letters))
            }
        }
        // Digits 0–9.
        for c in "1234567890" {
            if let code = AmigaKey.unshifted[c] {
                out.append(AmigaKeyItem(symbol: String(c), code: Int(code), category: .numbers))
            }
        }
        // Common symbols.
        for c in "-=[]\\;',./`" {
            if let code = AmigaKey.unshifted[c] {
                out.append(AmigaKeyItem(symbol: String(c), code: Int(code), category: .symbols))
            }
        }
        // Modifiers.
        out.append(AmigaKeyItem(symbol: "⇧",  code: Int(AmigaKey.lshift), category: .modifiers))
        out.append(AmigaKeyItem(symbol: "ctrl", code: Int(AmigaKey.ctrl), category: .modifiers))
        out.append(AmigaKeyItem(symbol: "alt", code: Int(AmigaKey.lalt),  category: .modifiers))
        out.append(AmigaKeyItem(symbol: "◆L", code: Int(AmigaKey.lAmiga), category: .modifiers))
        out.append(AmigaKeyItem(symbol: "◆R", code: Int(AmigaKey.rAmiga), category: .modifiers))
        // Arrows.
        out.append(AmigaKeyItem(symbol: "←", code: Int(AmigaKey.left),  category: .arrows))
        out.append(AmigaKeyItem(symbol: "→", code: Int(AmigaKey.right), category: .arrows))
        out.append(AmigaKeyItem(symbol: "↑", code: Int(AmigaKey.up),    category: .arrows))
        out.append(AmigaKeyItem(symbol: "↓", code: Int(AmigaKey.down),  category: .arrows))
        // F1–F10.
        for n in 1...10 {
            out.append(AmigaKeyItem(symbol: "F\(n)", code: Int(AmigaKey.f(n)), category: .function))
        }
        return out
    }()

    static func name(for code: Int) -> String {
        all.first(where: { $0.code == code })?.symbol ?? "?"
    }
}
