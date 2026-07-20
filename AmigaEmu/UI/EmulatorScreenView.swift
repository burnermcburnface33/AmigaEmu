import SwiftUI
import UIKit
import MetalKit
import Combine

/// SwiftUI wrapper for the Metal-rendered Amiga framebuffer.
struct EmulatorScreenView: UIViewRepresentable {
    func makeUIView(context: Context) -> EmulatorScreenUIView { EmulatorScreenUIView() }
    func updateUIView(_ uiView: EmulatorScreenUIView, context: Context) {}
}

final class EmulatorScreenUIView: UIView, UIGestureRecognizerDelegate {

    /// Classic Amiga monitor aspect (PAL displayed 4:3).
    private static let displayAspect: CGFloat = 4.0 / 3.0

    /// Deliberate, bounded aspect-ratio violations so spare space isn't
    /// wasted (both clamped to the available area):
    /// - H: the full-area overlay modes (direct mouse; landscape joystick,
    ///   whose controls float over the screen) may widen past true 4:3.
    /// - V: in PORTRAIT every mode except the side-keys panels may tallen —
    ///   portrait is width-limited so there's always vertical slack.
    private static let overlayModeHStretch: CGFloat = 1.3
    private static let portraitVStretch: CGFloat = 1.3

    private let metalView = MTKView(frame: .zero)
    private var renderer: MetalRenderer?
    private var pauseCancellable: AnyCancellable?
    private var modeCancellable: AnyCancellable?

    var zoomScale: CGFloat = 1.0 { didSet { setNeedsLayout() } }
    var panOffset: CGPoint = .zero { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true

        metalView.backgroundColor = .black
        metalView.isOpaque = true
        metalView.autoResizeDrawable = true
        addSubview(metalView)

        renderer = MetalRenderer(view: metalView)
        if let r = renderer { EmulatorController.shared.metalRenderer = r }

        // Park the 60Hz display link while the emulator is paused (battery) —
        // `enableSetNeedsDisplay` keeps the last frame on screen and lets
        // layout-driven one-off redraws through; resume restores continuous draw.
        pauseCancellable = EmulatorController.shared.$isEmulatorPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                guard let mv = self?.metalView else { return }
                mv.enableSetNeedsDisplay = paused
                mv.isPaused = paused
                if paused { mv.setNeedsDisplay() }   // leave a final frame up
            }
        // Re-run layout when the input mode changes — the direct-mouse
        // horizontal stretch applies/clears without recreating this view.
        modeCancellable = EmulatorController.shared.$inputMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setNeedsLayout() }
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var wasLandscape: Bool?

    override func layoutSubviews() {
        super.layoutSubviews()

        // On an orientation flip, drop any pinch-zoom/pan and let the crop
        // re-converge for the new aspect — otherwise the locked crop + stale
        // zoom make the picture look zoomed-in after rotating.
        let isLandscape = bounds.width > bounds.height
        if let prev = wasLandscape, prev != isLandscape {
            zoomScale = 1.0
            panOffset = .zero
            renderer?.resetAutoCrop()
        }
        wasLandscape = isLandscape

        let screenW = UIScreen.main.bounds.width
        let availW = min(bounds.width, screenW)
        let availH = bounds.height
        guard availW > 0, availH > 0 else { return }

        var w = availW
        var h = w / Self.displayAspect
        if h > availH { h = availH; w = h * Self.displayAspect }

        let mode = EmulatorController.shared.inputMode
        if mode == .directMouse || (mode == .joystick && isLandscape) || (mode == .customPanel && isLandscape) {
            w = min(w * Self.overlayModeHStretch, availW)
        }
        if !isLandscape && mode != .panelKeys && mode != .customPanel {
            h = min(h * Self.portraitVStretch, availH)
        }

        let z = max(1.0, min(zoomScale, 6.0))
        w *= z; h *= z

        let maxOffsetX = max(0, (w - availW) / 2.0 + 40)
        let maxOffsetY = max(0, (h - availH) / 2.0 + 40)
        let panX = min(max(panOffset.x, -maxOffsetX), maxOffsetX)
        let panY = min(max(panOffset.y, -maxOffsetY), maxOffsetY)

        let cx = (availW - w) / 2.0 + panX
        let cy = (availH - h) / 2.0 + panY

        let scale = max(UIScreen.main.scale, 1)
        let x = (cx * scale).rounded() / scale
        let y = (cy * scale).rounded() / scale
        metalView.frame = CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Gestures

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        pinch.delegate = self
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
        addGestureRecognizer(doubleTap)
    }

    private var pinchStartScale: CGFloat = 1.0
    private var panStartOffset: CGPoint = .zero

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStartScale = zoomScale
        case .changed, .ended:
            zoomScale = max(1.0, min(pinchStartScale * g.scale, 6.0))
            if zoomScale <= 1.001 { panOffset = .zero }
        default: break
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard zoomScale > 1.001 else { return }
        switch g.state {
        case .began: panStartOffset = panOffset
        case .changed, .ended:
            let t = g.translation(in: self)
            panOffset = CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y)
        default: break
        }
    }

    @objc private func handleDoubleTap() {
        UIView.animate(withDuration: 0.18) {
            self.zoomScale = 1.0
            self.panOffset = .zero
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
