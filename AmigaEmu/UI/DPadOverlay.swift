import SwiftUI
import UIKit

/// 4-way joystick d-pad. The arrow cluster (left) is the standard inverted-T
/// joystick (always present). The right half is a freeform zone populated by
/// the active `DPadLayout` — custom buttons each mapped to joystick fire or an
/// Amiga keycode. Long-press a button to drag it; the gear opens the editor.
struct DPadOverlay: View {
    @EnvironmentObject private var emu: EmulatorController
    @State private var showingCustomizer = false

    var body: some View {
        DPadOverlayRepresentable(onCustomize: { showingCustomizer = true })
            .environmentObject(emu)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showingCustomizer) {
                DPadCustomizerView().environmentObject(emu)
            }
    }
}

struct DPadOverlayRepresentable: UIViewRepresentable {
    @EnvironmentObject private var emu: EmulatorController
    let onCustomize: () -> Void

    func makeUIView(context: Context) -> DPadUIView {
        let v = DPadUIView()
        v.controller = emu
        v.onCustomize = onCustomize
        v.refreshFromLayout()
        return v
    }
    func updateUIView(_ v: DPadUIView, context: Context) {
        v.controller = emu
        v.onCustomize = onCustomize
        // Only rebuild when the structure actually changed (not mid-drag),
        // so a live drag isn't torn down by a SwiftUI refresh.
        v.refreshFromLayoutIfChanged()
    }
}

final class DPadUIView: UIView {

    weak var controller: EmulatorController?
    private let bridge = EmulatorBridge.shared()
    var onCustomize: (() -> Void)?

    /// Joystick is control port 2 (bridge port 1), matching the original d-pad.
    private let joyPort: Int32 = 1

    private let padRadius: CGFloat = 72
    private let baseCircle = UIView()
    private let centerHub  = UIView()
    private let upPad    = DPadCell(direction: .up)
    private let downPad  = DPadCell(direction: .down)
    private let leftPad  = DPadCell(direction: .left)
    private let rightPad = DPadCell(direction: .right)
    private let gearButton = UIButton(type: .system)

    private var customButtons: [(button: UIButton, model: DPadCustomButton)] = []
    private var renderedIds: [UUID] = []        // structural signature of last build
    private var draggingButton: UIButton?

    private var padTouch: UITouch?
    private var activeDirection: DPadDirection?
    private var latched: Set<UUID> = []

    enum DPadDirection { case up, down, left, right }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        baseCircle.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        baseCircle.layer.cornerRadius = padRadius
        baseCircle.layer.borderColor = UIColor(white: 1.0, alpha: 0.35).cgColor
        baseCircle.layer.borderWidth = 2
        baseCircle.isUserInteractionEnabled = false
        addSubview(baseCircle)
        for cell in [upPad, downPad, leftPad, rightPad] {
            cell.isUserInteractionEnabled = false
            addSubview(cell)
        }
        centerHub.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        centerHub.layer.cornerRadius = 12
        centerHub.isUserInteractionEnabled = false
        addSubview(centerHub)

        gearButton.setImage(UIImage(systemName: "slider.horizontal.3",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)), for: .normal)
        gearButton.tintColor = .white
        gearButton.backgroundColor = UIColor(white: 0.0, alpha: 0.65)
        gearButton.layer.cornerRadius = 18
        gearButton.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        gearButton.layer.borderWidth = 1
        gearButton.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
        addSubview(gearButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func gearTapped() { onCustomize?() }

    // MARK: Custom button rebuild

    /// Rebuild only if the set of button ids changed (add/remove/switch layout).
    func refreshFromLayoutIfChanged() {
        let ids = controller?.dpadLayout.buttons.map(\.id) ?? []
        if ids != renderedIds { refreshFromLayout() }
        else {
            // Same buttons — just refresh labels/models in place.
            if let layout = controller?.dpadLayout {
                for (i, m) in layout.buttons.enumerated() where i < customButtons.count {
                    customButtons[i].model = m
                    customButtons[i].button.setTitle(m.label, for: .normal)
                }
                setNeedsLayout()
            }
        }
    }

    func refreshFromLayout() {
        // The rebuilt buttons come back visually unlatched — release the keys
        // they were holding so the core matches what the user sees.
        releaseLatchedAndHeld()
        for (b, _) in customButtons { b.removeFromSuperview() }
        customButtons.removeAll()
        guard let layout = controller?.dpadLayout else { renderedIds = []; return }
        for model in layout.buttons {
            let b = makeCustomButton(model: model)
            addSubview(b)
            customButtons.append((b, model))
        }
        renderedIds = layout.buttons.map(\.id)
        setNeedsLayout()
    }

    private func makeCustomButton(model: DPadCustomButton) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(model.label, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.5
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = model.isFire ? UIColor(red: 0.85, green: 0.45, blue: 0.12, alpha: 1)
                                         : UIColor(red: 0.75, green: 0.13, blue: 0.13, alpha: 1)
        b.layer.cornerRadius = 30
        b.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        b.layer.borderWidth = 1
        if model.latching {
            b.addTarget(self, action: #selector(latchTapped(_:)), for: .touchUpInside)
        } else {
            b.addTarget(self, action: #selector(momentaryDown(_:)), for: [.touchDown, .touchDragEnter])
            b.addTarget(self, action: #selector(momentaryUp(_:)),
                        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        }
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(beginDrag(_:)))
        lp.minimumPressDuration = 0.45
        b.addGestureRecognizer(lp)
        return b
    }

    private func model(for button: UIButton) -> DPadCustomButton? {
        customButtons.first(where: { $0.button === button })?.model
    }

    private func press(_ m: DPadCustomButton, down: Bool) {
        if m.isFire {
            bridge.joyPort(joyPort, fire: down)
        } else {
            if down { bridge.keyDown(UInt8(m.keyCode)) } else { bridge.keyUp(UInt8(m.keyCode)) }
        }
    }

    @objc private func momentaryDown(_ s: UIButton) { if let m = model(for: s) { Haptics.tap(); press(m, down: true) } }
    @objc private func momentaryUp(_ s: UIButton)   { if let m = model(for: s) { press(m, down: false) } }
    @objc private func latchTapped(_ s: UIButton) {
        guard let m = model(for: s) else { return }
        Haptics.tap()
        if latched.contains(m.id) {
            latched.remove(m.id); press(m, down: false)
            s.backgroundColor = UIColor(red: 0.75, green: 0.13, blue: 0.13, alpha: 1)
        } else {
            latched.insert(m.id); press(m, down: true)
            s.backgroundColor = .systemBlue
        }
    }

    // MARK: Drag-to-reposition — move the frame live, commit on release.

    @objc private func beginDrag(_ g: UILongPressGestureRecognizer) {
        guard let b = g.view as? UIButton, let m = model(for: b) else { return }
        switch g.state {
        case .began:
            draggingButton = b
            UIView.animate(withDuration: 0.15) { b.alpha = 0.7 }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            b.center = g.location(in: self)
        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.15) { b.alpha = 1.0 }
            draggingButton = nil
            let zone = rightZone
            let nx = (b.center.x - zone.minX) / zone.width
            let ny = (b.center.y - zone.minY) / zone.height
            controller?.moveDPadButton(m.id, toX: Double(nx), y: Double(ny),
                                       landscape: isLandscapeOrientation)
        default: break
        }
    }

    // MARK: Layout

    private var rightZone: CGRect {
        let availW = min(bounds.width, UIScreen.main.bounds.width)
        let leftSide: CGFloat = 30 + padRadius * 2 + 20
        let zoneW = max(80, availW - leftSide - 20)
        return CGRect(x: leftSide, y: 10, width: zoneW, height: bounds.height - 20)
    }

    /// Landscape detection that also works on iPad, where `verticalSizeClass`
    /// is always `.regular`. Prefer the window-scene interface orientation;
    /// fall back to the compact height class / screen geometry.
    private var isLandscapeOrientation: Bool {
        if let o = window?.windowScene?.interfaceOrientation, o != .unknown {
            return o.isLandscape
        }
        if traitCollection.verticalSizeClass == .compact { return true }
        return UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let padCY = max(padRadius + 10, h - padRadius - 10)
        let padCX = padRadius + 30
        baseCircle.frame = CGRect(x: padCX - padRadius, y: padCY - padRadius,
                                  width: padRadius * 2, height: padRadius * 2)
        let armLen: CGFloat = 48, armBreadth: CGFloat = 40
        upPad.frame    = CGRect(x: padCX - armBreadth/2, y: padCY - armLen, width: armBreadth, height: armLen)
        downPad.frame  = CGRect(x: padCX - armBreadth/2, y: padCY, width: armBreadth, height: armLen)
        leftPad.frame  = CGRect(x: padCX - armLen, y: padCY - armBreadth/2, width: armLen, height: armBreadth)
        rightPad.frame = CGRect(x: padCX, y: padCY - armBreadth/2, width: armLen, height: armBreadth)
        centerHub.frame = CGRect(x: padCX - 12, y: padCY - 12, width: 24, height: 24)

        let zone = rightZone
        let btnSize: CGFloat = 60
        let landscape = isLandscapeOrientation
        let total = customButtons.count
        for (idx, (b, m)) in customButtons.enumerated() {
            if b === draggingButton { continue }   // don't fight the live drag
            let nx: CGFloat, ny: CGFloat
            if landscape {
                if let lx = m.landscapeX, let ly = m.landscapeY { nx = CGFloat(lx); ny = CGFloat(ly) }
                else { let s = DPadLayout.landscapeSlot(idx, total: total); nx = CGFloat(s.x); ny = CGFloat(s.y) }
            } else {
                nx = CGFloat(m.positionX); ny = CGFloat(m.positionY)
            }
            let cx = zone.minX + nx * zone.width
            let cy = zone.minY + ny * zone.height
            b.frame = CGRect(x: cx - btnSize/2, y: cy - btnSize/2, width: btnSize, height: btnSize)
        }

        let visibleW = min(bounds.width, UIScreen.main.bounds.width)
        let gearSize: CGFloat = 36
        gearButton.frame = CGRect(x: visibleW - gearSize - 10, y: 10, width: gearSize, height: gearSize)
        bringSubviewToFront(gearButton)
    }

    // MARK: Joystick arrow tracking (left half)

    private func directionForPoint(_ p: CGPoint) -> DPadDirection? {
        let dx = p.x - baseCircle.frame.midX
        let dy = p.y - baseCircle.frame.midY
        let mag = sqrt(dx*dx + dy*dy)
        if mag < 14 || mag > padRadius + 30 { return nil }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    private func dirIndex(_ d: DPadDirection) -> Int {
        switch d { case .up: return 0; case .down: return 1; case .left: return 2; case .right: return 3 }
    }

    private func setActive(_ dir: DPadDirection?) {
        if activeDirection == dir { return }
        if let prev = activeDirection {
            bridge.joy(joyPort, direction: dirIndex(prev), pressed: false)
            cellFor(prev).setPressed(false)
        }
        activeDirection = dir
        if let new = dir {
            Haptics.tap()   // on direction change only, not continuously
            bridge.joy(joyPort, direction: dirIndex(new), pressed: true)
            cellFor(new).setPressed(true)
        }
    }

    private func cellFor(_ dir: DPadDirection) -> DPadCell {
        switch dir { case .up: return upPad; case .down: return downPad; case .left: return leftPad; case .right: return rightPad }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let loc = touch.location(in: self)
            if loc.x < bounds.width / 2 && padTouch == nil {
                padTouch = touch
                setActive(directionForPoint(loc))
            }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = padTouch, touches.contains(t) else { return }
        setActive(directionForPoint(t.location(in: self)))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = padTouch, touches.contains(t) { padTouch = nil; setActive(nil) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// Torn down (mode switch / rotation). UIKit doesn't reliably cancel the
    /// active touches of a removed view, and latched keys have no touch at all
    /// — sweep-release everything this pad might be holding in the core.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        padTouch = nil
        setActive(nil)
        releaseLatchedAndHeld()
    }

    /// Release latched custom buttons plus any held momentary key/fire.
    private func releaseLatchedAndHeld() {
        for (_, model) in customButtons where latched.contains(model.id) {
            press(model, down: false)
        }
        latched.removeAll()
        bridge.joyPort(joyPort, fire: false)   // a held momentary FIRE button
        bridge.keyReleaseAll()                 // any held momentary key button
    }
}

private final class DPadCell: UIView {
    enum Direction { case up, down, left, right }
    let direction: Direction
    init(direction: Direction) {
        self.direction = direction
        super.init(frame: .zero)
        backgroundColor = idleColor
        layer.cornerRadius = 6
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        layer.borderWidth = 1
        let arrow = UILabel(frame: .zero)
        arrow.text = glyph
        arrow.textAlignment = .center
        arrow.font = .systemFont(ofSize: 24, weight: .bold)
        arrow.textColor = .white
        arrow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrow)
        NSLayoutConstraint.activate([
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    private var glyph: String {
        switch direction { case .up: return "▲"; case .down: return "▼"; case .left: return "◀"; case .right: return "▶" }
    }
    private let idleColor    = UIColor(red: 0.65, green: 0.11, blue: 0.11, alpha: 1.0)
    private let pressedColor = UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1.0)
    func setPressed(_ pressed: Bool) { backgroundColor = pressed ? pressedColor : idleColor }
}
