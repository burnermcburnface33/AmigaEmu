import SwiftUI

/// Digital joystick (drag the stick) + fire button → control port 2
/// (bridge port 1), the conventional Amiga joystick port.
struct JoystickOverlay: View {
    private static let joyPort: Int32 = 1

    var body: some View {
        HStack {
            AnalogStick(port: Self.joyPort)
            Spacer()
            VStack(spacing: 14) {
                FireButton(port: Self.joyPort, label: "FIRE", secondary: false)
                FireButton(port: Self.joyPort, label: "2", secondary: true)
            }
        }
        .padding(.leading, 28)
        // Extra trailing room — at 28pt the fire buttons grazed the right
        // screen edge in portrait.
        .padding(.trailing, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AnalogStick: View {
    let port: Int32
    private let bridge = EmulatorBridge.shared()
    private let radius: CGFloat = 70
    @State private var offset: CGSize = .zero
    @State private var dirX = 0
    @State private var dirY = 0

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.10))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 2))
                .frame(width: radius * 2, height: radius * 2)
            Circle().fill(Color(white: 0.32))
                .frame(width: 60, height: 60)
                .offset(offset)
        }
        .frame(width: radius * 2, height: radius * 2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.translation.width, dy = v.translation.height
                    let mag = max(hypot(dx, dy), 0.0001)
                    let cl = min(mag, radius)
                    offset = CGSize(width: dx / mag * cl, height: dy / mag * cl)
                    let t: CGFloat = 22
                    setDir(x: dx < -t ? -1 : (dx > t ? 1 : 0),
                           y: dy < -t ? -1 : (dy > t ? 1 : 0))
                }
                .onEnded { _ in offset = .zero; setDir(x: 0, y: 0) }
        )
        // Drag gestures get no cancel callback when the view is torn down
        // (mode switch / rotation mid-drag) — release the held direction.
        .onDisappear { offset = .zero; setDir(x: 0, y: 0) }
    }

    private func setDir(x: Int, y: Int) {
        // Haptic on a direction *change* to a pressed state (not continuous).
        if (x != dirX && x != 0) || (y != dirY && y != 0) { Haptics.tap() }
        if x != dirX {
            if dirX != 0 { bridge.joy(port, direction: dirX < 0 ? 2 : 3, pressed: false) }
            if x != 0    { bridge.joy(port, direction: x < 0 ? 2 : 3, pressed: true) }
            dirX = x
        }
        if y != dirY {
            if dirY != 0 { bridge.joy(port, direction: dirY < 0 ? 0 : 1, pressed: false) }
            if y != 0    { bridge.joy(port, direction: y < 0 ? 0 : 1, pressed: true) }
            dirY = y
        }
    }
}

private struct FireButton: View {
    let port: Int32
    let label: String
    let secondary: Bool
    private let bridge = EmulatorBridge.shared()
    @State private var down = false

    var body: some View {
        Circle()
            .fill(down ? Color.red : Color(red: 0.55, green: 0.14, blue: 0.14))
            .frame(width: secondary ? 60 : 84, height: secondary ? 60 : 84)
            .overlay(Text(label).foregroundColor(.white).font(.headline.bold()))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; Haptics.tap(); fire(true) } }
                    .onEnded { _ in down = false; fire(false) }
            )
            // Release a held fire button if the overlay is torn down mid-press.
            .onDisappear { if down { down = false; fire(false) } }
    }
    private func fire(_ on: Bool) {
        // Secondary fire is button 2 — modelled here as the d-pad's up.
        if secondary { bridge.joy(port, direction: 0, pressed: on) }
        else { bridge.joyPort(port, fire: on) }
    }
}

/// Convenience bridging so call sites stay terse.
extension EmulatorBridge {
    func joy(_ port: Int32, direction: Int, pressed: Bool) {
        self.joyPort(port, direction: Int32(direction), pressed: pressed)
    }
}
