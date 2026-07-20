import Foundation
import GameController

/// Maps any connected MFi / Bluetooth extended gamepad onto the Amiga
/// joystick in control port 2 (bridge port 1) — the same bridge calls the
/// on-screen JoystickOverlay uses (left thumbstick + d-pad → directions,
/// button A → fire). Active regardless of the selected input mode, so a
/// physical pad "just works". Started once from EmulatorController.bootstrap().
final class GamepadManager {
    static let shared = GamepadManager()
    private let bridge = EmulatorBridge.shared()
    private let joyPort: Int32 = 1     // control port 2, like JoystickOverlay

    private var started = false
    private var dirX = 0
    private var dirY = 0
    private var firePressed = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let c = note.object as? GCController { self?.configure(c) }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.releaseAll()   // don't leave a direction/fire stuck on unplug
        }
        GCController.controllers().forEach(configure(_:))
        // Pick up controllers paired while the app was backgrounded
        // (parity with the AppleIIGS/dospad managers).
        GCController.startWirelessControllerDiscovery()
    }

    private func configure(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] pad, _ in self?.poll(pad) }
    }

    private func poll(_ pad: GCExtendedGamepad) {
        // Left thumbstick OR d-pad → 4-way digital joystick. Stick-up is +Y
        // in GameController but "up" (direction 0) on the Amiga.
        let t: Float = 0.35
        let sx = pad.leftThumbstick.xAxis.value
        let sy = pad.leftThumbstick.yAxis.value
        var x = sx < -t ? -1 : (sx > t ? 1 : 0)
        var y = sy > t ? -1 : (sy < -t ? 1 : 0)
        if pad.dpad.left.isPressed { x = -1 } else if pad.dpad.right.isPressed { x = 1 }
        if pad.dpad.up.isPressed   { y = -1 } else if pad.dpad.down.isPressed  { y = 1 }
        // Button B = secondary fire, modelled as joystick-up — the classic
        // one-button-Amiga convention (jump), same as the on-screen "2" button.
        if pad.buttonB.isPressed { y = -1 }
        setDir(x: x, y: y)

        let fire = pad.buttonA.isPressed
        if fire != firePressed {
            firePressed = fire
            bridge.joyPort(joyPort, fire: fire)
        }
    }

    /// Same press/release protocol as the on-screen AnalogStick
    /// (0=up 1=down 2=left 3=right; releasing a direction releases its axis).
    private func setDir(x: Int, y: Int) {
        if x != dirX {
            if dirX != 0 { bridge.joy(joyPort, direction: dirX < 0 ? 2 : 3, pressed: false) }
            if x != 0    { bridge.joy(joyPort, direction: x < 0 ? 2 : 3, pressed: true) }
            dirX = x
        }
        if y != dirY {
            if dirY != 0 { bridge.joy(joyPort, direction: dirY < 0 ? 0 : 1, pressed: false) }
            if y != 0    { bridge.joy(joyPort, direction: y < 0 ? 0 : 1, pressed: true) }
            dirY = y
        }
    }

    private func releaseAll() {
        setDir(x: 0, y: 0)
        if firePressed {
            firePressed = false
            bridge.joyPort(joyPort, fire: false)
        }
    }
}
