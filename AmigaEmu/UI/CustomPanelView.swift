import SwiftUI

/// Landscape custom split-panel — the user-customizable sibling of
/// `SidePanelKeyboard`. Small keyboard-style keys from the active `PanelLayout`
/// are split across the left and right flanks that surround the full-size
/// screen; the left flank leads with a gear (opens the editor) and an optional
/// inverted-T arrow pad (always sends the four Amiga arrow keys). Keys send raw
/// Amiga keycodes, or pull joystick fire for the FIRE sentinel.
struct CustomPanelView: View {
    enum Side { case left, right }
    let side: Side
    @EnvironmentObject var emu: EmulatorController
    @Environment(\.verticalSizeClass) private var vClass
    @State private var showingCustomizer = false

    var body: some View {
        if side == .left {
            panel.sheet(isPresented: $showingCustomizer) {
                CustomPanelCustomizerView().environmentObject(emu)
            }
        } else {
            panel
        }
    }

    private var panel: some View {
        let compact = vClass == .compact
        let spacing: CGFloat = compact ? 4 : 6
        let ks = emu.panelLayout.keys
        let half = (ks.count + 1) / 2
        let leftKeys = Array(ks.prefix(half))
        let rightKeys = Array(ks.dropFirst(half))
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: spacing) {
                if side == .left {
                    HStack {
                        Spacer(minLength: 0)
                        Button { showingCustomizer = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.18)))
                        }
                    }
                    if emu.panelLayout.showDPad {
                        ArrowTPad(spacing: spacing)
                        Divider().background(Color.white.opacity(0.15)).padding(.vertical, 2)
                    }
                    keyGrid(leftKeys, spacing: spacing)
                } else {
                    keyGrid(rightKeys, spacing: spacing)
                }
            }
            .padding(.vertical, compact ? 6 : 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .background(Color(white: 0.05))
    }

    @ViewBuilder private func keyGrid(_ keys: [PanelKeyItem], spacing: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 2),
                  spacing: spacing) {
            ForEach(keys) { PanelKeyButton(item: $0) }
        }
    }
}

/// Send helper shared by the momentary/latching gesture path and the teardown
/// release — FIRE pulls the joystick, otherwise a raw Amiga keycode.
private func panelSend(_ item: PanelKeyItem, _ bridge: EmulatorBridge, down: Bool) {
    if item.isFire {
        bridge.joyPort(1, fire: down)
    } else if down {
        bridge.keyDown(UInt8(item.keyCode))
    } else {
        bridge.keyUp(UInt8(item.keyCode))
    }
}

/// The inverted-T arrow pad atop the left flank — UP centered above LEFT/DOWN/
/// RIGHT. Always sends the four Amiga arrow keys regardless of the custom keys.
private struct ArrowTPad: View {
    let spacing: CGFloat
    var body: some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                Color.clear.frame(maxWidth: .infinity)
                ArrowKey(label: "▲", code: AmigaKey.up)
                Color.clear.frame(maxWidth: .infinity)
            }
            HStack(spacing: spacing) {
                ArrowKey(label: "◀", code: AmigaKey.left)
                ArrowKey(label: "▼", code: AmigaKey.down)
                ArrowKey(label: "▶", code: AmigaKey.right)
            }
        }
    }
}

/// A prominent momentary key sending one fixed Amiga arrow keycode.
private struct ArrowKey: View {
    let label: String
    let code: UInt8
    @Environment(\.verticalSizeClass) private var vClass
    @State private var pressed = false
    private let bridge = EmulatorBridge.shared()

    private var minHeight: CGFloat { vClass == .compact ? 40 : 48 }

    var body: some View {
        Text(label)
            .font(.system(size: 18, weight: .semibold))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(pressed ? Color(white: 0.42) : Color(white: 0.22)))
            .foregroundColor(.white)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; Haptics.tap(); bridge.keyDown(code) } }
                    .onEnded { _ in pressed = false; bridge.keyUp(code) }
            )
            .onDisappear { if pressed { pressed = false; bridge.keyUp(code) } }
    }
}

/// One `PanelKeyItem` rendered as a small keyboard-style key. Momentary keys
/// press/release on touch-down/up (zero-distance drag); latching keys toggle a
/// held state on tap (blue while on). Everything held is released on teardown.
private struct PanelKeyButton: View {
    let item: PanelKeyItem
    @Environment(\.verticalSizeClass) private var vClass
    @State private var pressed = false
    @State private var latchedOn = false
    private let bridge = EmulatorBridge.shared()

    private var fill: Color {
        if latchedOn { return .blue }
        if pressed { return Color(white: 0.42) }
        return Color(white: 0.22)
    }
    private var minHeight: CGFloat { vClass == .compact ? 30 : 36 }

    var body: some View {
        Text(item.label)
            .font(.system(size: 14, weight: .semibold))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .foregroundColor(.white)
            .contentShape(Rectangle())
            .modifier(PanelKeyTouch(item: item, pressed: $pressed, latched: $latchedOn, bridge: bridge))
            .onDisappear {
                if pressed { pressed = false; panelSend(item, bridge, down: false) }
                if latchedOn { latchedOn = false; panelSend(item, bridge, down: false) }
            }
            // Edited in place in the customizer (same id → SwiftUI keeps this
            // view + its @State). Release whatever the OLD definition was
            // holding so a stale keycode/fire can't stay stuck, and reset the
            // visual to match.
            .onChange(of: item) { oldItem, _ in
                if pressed || latchedOn {
                    panelSend(oldItem, bridge, down: false)
                    pressed = false
                    latchedOn = false
                }
            }
    }
}

/// Momentary keys press/release on touch-down/up; latching keys toggle held
/// state on tap.
private struct PanelKeyTouch: ViewModifier {
    let item: PanelKeyItem
    @Binding var pressed: Bool
    @Binding var latched: Bool
    let bridge: EmulatorBridge

    func body(content: Content) -> some View {
        if !item.latching {
            content.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; Haptics.tap(); panelSend(item, bridge, down: true) } }
                    .onEnded { _ in pressed = false; panelSend(item, bridge, down: false) }
            )
        } else {
            content.onTapGesture {
                latched.toggle()
                Haptics.tap()
                panelSend(item, bridge, down: latched)
            }
        }
    }
}
