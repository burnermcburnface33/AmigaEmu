import Foundation

/// User-editable *landscape* custom panel — the customizable sibling of the
/// fixed `SidePanelKeyboard`. Where the D-pad custom mode (`DPadLayout`) is the
/// portrait, overlay-positioned custom mode, this one lays small keyboard-style
/// keys out in the left/right flanks around a full-size screen, with an optional
/// inverted-T arrow pad at the top of the left flank.
///
/// A panel key either fires the joystick (`keyCode == DPadCustomButton.fireCode`)
/// or sends a raw Amiga keycode (momentary or latching). Keys are split in
/// declaration order across the two flanks — reordering decides which side a key
/// lands on. Layouts are persisted independently of the D-pad layouts in
/// UserDefaults (`AmigaCustomPanelLayouts` / `AmigaCustomPanelActiveID`).
struct PanelLayout: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// Whether the inverted-T arrow pad is shown atop the left flank (ON by
    /// default). The arrow pad always sends the four Amiga arrow keys.
    var showDPad: Bool
    var keys: [PanelKeyItem]

    init(id: UUID = UUID(), name: String, showDPad: Bool = true, keys: [PanelKeyItem]) {
        self.id = id; self.name = name; self.showDPad = showDPad; self.keys = keys
    }

    /// Bootstrap layout — arrow pad on, plus the four actions most Amiga games
    /// map to (FIRE + Space + Return + Esc).
    static let starter = PanelLayout(
        name: "Default",
        showDPad: true,
        keys: [
            PanelKeyItem(label: "FIRE", keyCode: DPadCustomButton.fireCode),
            PanelKeyItem(label: "SPC",  keyCode: Int(AmigaKey.space)),
            PanelKeyItem(label: "RET",  keyCode: Int(AmigaKey.enter)),
            PanelKeyItem(label: "ESC",  keyCode: Int(AmigaKey.esc)),
        ])
}

/// One customizable panel key. `fireCode` (-1) = joystick fire; otherwise a raw
/// Amiga keycode (0x00–0x67).
struct PanelKeyItem: Codable, Hashable, Identifiable {
    let id: UUID
    var label: String
    var keyCode: Int
    /// If true, tap toggles down/up (good for modifiers held while another key
    /// is pressed). If false the key is momentary (down on touch, up on release).
    var latching: Bool

    init(id: UUID = UUID(), label: String, keyCode: Int, latching: Bool = false) {
        self.id = id; self.label = label; self.keyCode = keyCode; self.latching = latching
    }

    var isFire: Bool { keyCode == DPadCustomButton.fireCode }
}
