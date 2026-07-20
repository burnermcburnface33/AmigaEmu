import Foundation

/// Raw Amiga hardware keycodes (0x00–0x67) — what `EmulatorBridge.keyDown:`
/// expects. These follow the physical Amiga keyboard matrix, not ASCII.
/// Table from vAmiga's AmigaKey / the web key_translation_map.
enum AmigaKey {
    static let backtick: UInt8 = 0x00
    static let minus: UInt8 = 0x0B
    static let equal: UInt8 = 0x0C
    static let backslash: UInt8 = 0x0D
    static let leftBracket: UInt8 = 0x1A
    static let rightBracket: UInt8 = 0x1B
    static let semicolon: UInt8 = 0x29
    static let quote: UInt8 = 0x2A
    static let comma: UInt8 = 0x38
    static let period: UInt8 = 0x39
    static let slash: UInt8 = 0x3A

    static let space: UInt8 = 0x40
    static let backspace: UInt8 = 0x41
    static let tab: UInt8 = 0x42
    static let enter: UInt8 = 0x44
    static let esc: UInt8 = 0x45
    static let del: UInt8 = 0x46
    static let help: UInt8 = 0x5F

    static let up: UInt8 = 0x4C
    static let down: UInt8 = 0x4D
    static let right: UInt8 = 0x4E
    static let left: UInt8 = 0x4F

    static let lshift: UInt8 = 0x60
    static let rshift: UInt8 = 0x61
    static let capsLock: UInt8 = 0x62
    static let ctrl: UInt8 = 0x63
    static let lalt: UInt8 = 0x64
    static let ralt: UInt8 = 0x65
    static let lAmiga: UInt8 = 0x66
    static let rAmiga: UInt8 = 0x67

    /// F1…F10 = 0x50…0x59.
    static func f(_ n: Int) -> UInt8 { UInt8(0x50 + (n - 1)) }

    /// Unshifted printable character → keycode.
    static let unshifted: [Character: UInt8] = {
        var m: [Character: UInt8] = [
            "`": 0x00, "-": 0x0B, "=": 0x0C, "\\": 0x0D,
            "[": 0x1A, "]": 0x1B, ";": 0x29, "'": 0x2A,
            ",": 0x38, ".": 0x39, "/": 0x3A, " ": 0x40,
        ]
        // Digits 1..9 0 = 0x01..0x0A
        for (i, c) in "1234567890".enumerated() { m[c] = UInt8(0x01 + i) }
        // QWERTY row 0x10..0x19
        for (i, c) in "qwertyuiop".enumerated() { m[c] = UInt8(0x10 + i) }
        // ASDF row 0x20..0x28
        for (i, c) in "asdfghjkl".enumerated() { m[c] = UInt8(0x20 + i) }
        // ZXCV row 0x31..0x37
        for (i, c) in "zxcvbnm".enumerated() { m[c] = UInt8(0x31 + i) }
        return m
    }()

    /// Shifted printable character → base keycode (caller holds SHIFT).
    static let shifted: [Character: UInt8] = [
        "~": 0x00, "!": 0x01, "@": 0x02, "#": 0x03, "$": 0x04, "%": 0x05,
        "^": 0x06, "&": 0x07, "*": 0x08, "(": 0x09, ")": 0x0A,
        "_": 0x0B, "+": 0x0C, "|": 0x0D, "{": 0x1A, "}": 0x1B,
        ":": 0x29, "\"": 0x2A, "<": 0x38, ">": 0x39, "?": 0x3A,
    ]

    /// Resolve a typed character to (keycode, needsShift). Uppercase letters
    /// map to their lowercase keycode + shift.
    static func resolve(_ ch: Character) -> (code: UInt8, shift: Bool)? {
        if let c = unshifted[ch] { return (c, false) }
        if ch.isUppercase, let c = unshifted[Character(ch.lowercased())] { return (c, true) }
        if let c = shifted[ch] { return (c, true) }
        return nil
    }
}
