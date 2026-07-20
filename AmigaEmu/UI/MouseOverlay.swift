import SwiftUI

/// Trackpad-style mouse → control port 1 (bridge port 0). Drag to move,
/// quick tap to left-click, plus explicit L/R buttons. Battle Chess and
/// Workbench are mouse-driven, so this is the default-feel input.
struct MouseOverlay: View {
    private static let mousePort: Int32 = 0
    private let bridge = EmulatorBridge.shared()
    @EnvironmentObject private var emu: EmulatorController
    @State private var last: CGPoint?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12))
                Text("Trackpad — drag to move, tap to click")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.4))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if let l = last {
                            bridge.mousePort(Self.mousePort,
                                             moveDX: Double(v.location.x - l.x) * emu.mouseSensitivity,
                                             dy: Double(v.location.y - l.y) * emu.mouseSensitivity)
                        }
                        last = v.location
                    }
                    .onEnded { v in
                        if hypot(v.translation.width, v.translation.height) < 8 {
                            clickLeft()
                        }
                        last = nil
                    }
            )

            HStack(spacing: 10) {
                MouseButton(title: "Left",  port: Self.mousePort, button: 1)
                MouseButton(title: "Mid",   port: Self.mousePort, button: 2)
                    .frame(maxWidth: 76)
                MouseButton(title: "Right", port: Self.mousePort, button: 3)
            }
            .frame(height: 48)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clickLeft() {
        bridge.mousePort(Self.mousePort, button: 1, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            bridge.mousePort(Self.mousePort, button: 1, pressed: false)
        }
    }
}

struct MouseButton: View {
    let title: String
    let port: Int32
    let button: Int32
    private let bridge = EmulatorBridge.shared()
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(down ? Color(white: 0.4) : Color(white: 0.2)))
            .foregroundColor(.white)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down {
                            down = true
                            Haptics.tap()
                            bridge.mousePort(port, button: button, pressed: true)
                        }
                    }
                    .onEnded { _ in down = false; bridge.mousePort(port, button: button, pressed: false) }
            )
            // Release a held button if the overlay is torn down mid-press
            // (mode switch, or the portrait↔landscape mouse-split swap).
            .onDisappear {
                if down { down = false; bridge.mousePort(port, button: button, pressed: false) }
            }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Landscape split trackpad: the screen stays full-size in the middle while
// a tall trackpad surface flanks it on the LEFT and the mouse buttons on the
// RIGHT — so mouse mode no longer shrinks the emulator screen in landscape.
// (Used by MainView when inputMode == .mouse && verticalSizeClass == .compact.)
// ─────────────────────────────────────────────────────────────────────

/// Tall relative-drag trackpad surface (for the left side in landscape).
struct TrackpadSurface: View {
    private static let mousePort: Int32 = 0
    private let bridge = EmulatorBridge.shared()
    @EnvironmentObject private var emu: EmulatorController
    @State private var last: CGPoint?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12))
            Text("Trackpad")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.4))
                .rotationEffect(.degrees(-90))
        }
        .padding(6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if let l = last {
                        bridge.mousePort(Self.mousePort,
                                         moveDX: Double(v.location.x - l.x) * emu.mouseSensitivity,
                                         dy: Double(v.location.y - l.y) * emu.mouseSensitivity)
                    }
                    last = v.location
                }
                .onEnded { v in
                    if hypot(v.translation.width, v.translation.height) < 8 {
                        bridge.mousePort(Self.mousePort, button: 1, pressed: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                            bridge.mousePort(Self.mousePort, button: 1, pressed: false)
                        }
                    }
                    last = nil
                }
        )
    }
}

// ─────────────────────────────────────────────────────────────────────
// Direct mouse mode: the emulator picture ITSELF is the trackpad. Drags
// anywhere on the screen move the pointer relatively (same feel as the
// trackpad — not absolute touch position), a quick tap left-clicks, and
// compact semi-transparent L/R buttons float over the right edge so
// press-and-drag (drag & drop) works: hold L, drag on the screen.
// No flanking panels, no bottom strip — maximum screen real estate.
// (Used by MainView as an .overlay on the screen slot; note the drag
// surface swallows the screen's pinch-zoom/double-tap gestures while
// this mode is active.)
// ─────────────────────────────────────────────────────────────────────
struct DirectMouseOverlay: View {
    private static let mousePort: Int32 = 0
    private let bridge = EmulatorBridge.shared()
    @EnvironmentObject private var emu: EmulatorController
    @State private var last: CGPoint?

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if let l = last {
                                bridge.mousePort(Self.mousePort,
                                                 moveDX: Double(v.location.x - l.x) * emu.mouseSensitivity,
                                                 dy: Double(v.location.y - l.y) * emu.mouseSensitivity)
                            }
                            last = v.location
                        }
                        .onEnded { v in
                            if hypot(v.translation.width, v.translation.height) < 8 {
                                bridge.mousePort(Self.mousePort, button: 1, pressed: true)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                                    bridge.mousePort(Self.mousePort, button: 1, pressed: false)
                                }
                            }
                            last = nil
                        }
                )

            VStack(spacing: 8) {
                MouseButton(title: "L", port: Self.mousePort, button: 1)
                    .frame(width: 40, height: 52)
                MouseButton(title: "R", port: Self.mousePort, button: 3)
                    .frame(width: 40, height: 52)
            }
            .opacity(0.45)
            .padding(.trailing, 6)
        }
    }
}

/// Vertical stack of L / R mouse buttons (for the right side in landscape).
struct MouseButtonColumn: View {
    private static let mousePort: Int32 = 0

    var body: some View {
        VStack(spacing: 10) {
            MouseButton(title: "L", port: Self.mousePort, button: 1)
            MouseButton(title: "M", port: Self.mousePort, button: 2)
                .frame(maxHeight: 44)
            MouseButton(title: "R", port: Self.mousePort, button: 3)
        }
        .padding(6)
    }
}
