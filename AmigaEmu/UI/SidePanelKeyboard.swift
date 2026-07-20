import SwiftUI

/// Landscape-oriented key columns flanking a full-size screen (mirrors the
/// dospad/AppleIIGS side-panel mode). Left = arrows + modifiers + nav +
/// compressed F-keys; right = A–Z + digits. Keys send raw Amiga keycodes.
struct SidePanelKeyboard: View {
    enum Side { case left, right }
    let side: Side
    @Environment(\.verticalSizeClass) private var vClass

    private static let letters: [(String, UInt8)] =
        (0..<26).map { i in
            let ch = Character(UnicodeScalar(97 + i)!)   // a..z
            return (String(ch).uppercased(), AmigaKey.unshifted[ch] ?? 0)
        }
    private static let digits: [(String, UInt8)] =
        "1234567890".map { (String($0), AmigaKey.unshifted[$0] ?? 0) }
    private static let fkeys: [(String, UInt8)] =
        (1...10).map { (String($0), AmigaKey.f($0)) }

    var body: some View {
        let compact = vClass == .compact
        let spacing: CGFloat = compact ? 4 : 6
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: spacing) {
                if side == .left { leftColumn(spacing) } else { rightColumn(spacing) }
            }
            .padding(.vertical, compact ? 6 : 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .background(Color(white: 0.05))
    }

    @ViewBuilder private func leftColumn(_ spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                Color.clear.frame(maxWidth: .infinity)
                PanelKey(.momentary("▲", AmigaKey.up), prominent: true)
                Color.clear.frame(maxWidth: .infinity)
            }
            HStack(spacing: spacing) {
                PanelKey(.momentary("◀", AmigaKey.left), prominent: true)
                PanelKey(.momentary("▼", AmigaKey.down), prominent: true)
                PanelKey(.momentary("▶", AmigaKey.right), prominent: true)
            }
        }
        Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
        HStack(spacing: spacing) {
            PanelKey(.latching("ctrl", AmigaKey.ctrl))
            PanelKey(.latching("⇧", AmigaKey.lshift))
            PanelKey(.latching("◆", AmigaKey.lAmiga))
            PanelKey(.latching("alt", AmigaKey.lalt))
        }
        PanelKey(.momentary("esc", AmigaKey.esc))
        PanelKey(.momentary("tab", AmigaKey.tab))
        PanelKey(.momentary("⏎", AmigaKey.enter))
        PanelKey(.momentary("space", AmigaKey.space))
        PanelKey(.momentary("⌫", AmigaKey.backspace))
        Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 6),
                  spacing: spacing) {
            ForEach(Self.fkeys, id: \.1) { PanelKey(.momentary($0.0, $0.1), mini: true) }
        }
    }

    @ViewBuilder private func rightColumn(_ spacing: CGFloat) -> some View {
        let letterCols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        let numCols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 5)
        LazyVGrid(columns: letterCols, spacing: spacing) {
            ForEach(Self.letters, id: \.1) { PanelKey(.momentary($0.0, $0.1)) }
        }
        LazyVGrid(columns: numCols, spacing: spacing) {
            ForEach(Self.digits, id: \.1) { PanelKey(.momentary($0.0, $0.1)) }
        }
    }
}

private struct PanelKey: View {
    enum Kind {
        case momentary(String, UInt8)
        case latching(String, UInt8)
    }
    let kind: Kind
    let prominent: Bool
    let mini: Bool
    init(_ kind: Kind, prominent: Bool = false, mini: Bool = false) {
        self.kind = kind; self.prominent = prominent; self.mini = mini
    }

    @Environment(\.verticalSizeClass) private var vClass
    @State private var pressed = false
    @State private var latchedOn = false
    private let bridge = EmulatorBridge.shared()

    private var label: String {
        switch kind { case .momentary(let l, _), .latching(let l, _): return l }
    }
    private var code: UInt8 {
        switch kind { case .momentary(_, let c), .latching(_, let c): return c }
    }
    private var isMomentary: Bool {
        if case .momentary = kind { return true }; return false
    }
    private var fill: Color {
        if latchedOn { return .blue }
        if pressed { return Color(white: 0.42) }
        return Color(white: 0.22)
    }
    private var minHeight: CGFloat {
        let compact = vClass == .compact
        if prominent { return compact ? 40 : 48 }
        if mini { return compact ? 26 : 30 }
        return compact ? 30 : 38
    }

    var body: some View {
        Text(label)
            .font(.system(size: prominent ? 18 : (mini ? 12 : 14), weight: .semibold))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .foregroundColor(.white)
            .contentShape(Rectangle())
            .modifier(KeyTouch(momentary: isMomentary, pressed: $pressed,
                               latched: $latchedOn, code: code, bridge: bridge))
            .onDisappear {
                if pressed { pressed = false; bridge.keyUp(code) }
                if latchedOn { latchedOn = false; bridge.keyUp(code) }
            }
    }
}

/// Momentary keys press/release on touch-down/up (zero-distance drag);
/// latching keys (modifiers) toggle held state on tap.
private struct KeyTouch: ViewModifier {
    let momentary: Bool
    @Binding var pressed: Bool
    @Binding var latched: Bool
    let code: UInt8
    let bridge: EmulatorBridge

    func body(content: Content) -> some View {
        if momentary {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; Haptics.tap(); bridge.keyDown(code) } }
                    .onEnded { _ in pressed = false; bridge.keyUp(code) }
            )
        } else {
            content.onTapGesture {
                latched.toggle()
                Haptics.tap()
                if latched { bridge.keyDown(code) } else { bridge.keyUp(code) }
            }
        }
    }
}
