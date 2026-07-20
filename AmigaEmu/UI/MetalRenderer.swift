import Foundation
import Metal
import MetalKit

/// Displays the vAmiga framebuffer. Each `draw(in:)` locks the core's stable
/// texture, uploads the 912×313 RGBA8 frame (only when the frame number
/// changed), and draws a quad that bilinear-samples the visible crop window.
final class MetalRenderer: NSObject, MTKViewDelegate {

    private struct DisplayParams { var crop: SIMD4<Float> }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let bridge = EmulatorBridge.shared()

    private var sourceTexture: MTLTexture?
    private var lastFrameNr: Int64 = -1

    /// Visible window inside the 912×313 texture (x0,y0,x1,y1 in UV). The
    /// borders/blanking fill the rest. Seeded with a sane estimate, then
    /// continuously eased toward the core's `findInnerArea` result (below).
    var cropRect = SIMD4<Float>(0.16, 0.06, 0.95, 0.93)

    /// When true, the crop auto-tunes toward the active picture, then LOCKS once
    /// it settles — so the image doesn't keep "resizing" as on-screen content /
    /// video mode changes. A reboot re-detects (`resetAutoCrop`).
    var autoCrop = true
    private var sinceCropSample = 0
    private var cropLocked = false
    private var cropStableCount = 0

    /// The last LOCKED crop, shared across renderer instances. If SwiftUI ever
    /// recreates the screen view (and with it this renderer), the fresh
    /// instance starts at the already-converged window instead of visibly
    /// re-converging from the seed — the "zoom-settle on interface change"
    /// artifact.
    private static var lastLockedCrop: SIMD4<Float>?

    /// Re-enable auto-crop detection (call on reboot / cold boot).
    func resetAutoCrop() {
        cropLocked = false
        cropStableCount = 0
        MetalRenderer.lastLockedCrop = nil
    }

    private static let texturePixelFormat: MTLPixelFormat = .rgba8Unorm
    private static let framebufferPixelFormat: MTLPixelFormat = .bgra8Unorm

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(),
              let cmdQueue = dev.makeCommandQueue(),
              let library = try? dev.makeDefaultLibrary(bundle: .main),
              let vfn = library.makeFunction(name: "amiga_vertex"),
              let ffn = library.makeFunction(name: "amiga_fragment_display")
        else { return nil }

        self.device = dev
        self.queue = cmdQueue

        view.device = dev
        view.colorPixelFormat = MetalRenderer.framebufferPixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.label = "amiga.pipeline.display"
        guard let pipe = try? dev.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pipe

        super.init()
        // A previous renderer already converged on this content — start there.
        if let locked = MetalRenderer.lastLockedCrop {
            cropRect = locked
            cropLocked = true
        }
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        ensureTexture()
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let source = sourceTexture else { return }

        // Lock the core texture, upload only on a new frame, unlock.
        var nr: Int64 = 0
        var uploadedNewFrame = false
        if let ptr = bridge.lockFrame(&nr) {
            if nr != lastFrameNr {
                let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                       size: MTLSize(width: source.width,
                                                     height: source.height, depth: 1))
                source.replace(region: region, mipmapLevel: 0,
                               withBytes: ptr,
                               bytesPerRow: Int(AmigaFrameBytesPerRow))
                lastFrameNr = nr
                uploadedNewFrame = true
            }
            bridge.unlockFrame()
        }
        // Sample auto-crop AFTER unlocking — the query suspends the emulator,
        // which must not happen while we hold the texture lock.
        if uploadedNewFrame { refreshAutoCrop() }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor) else {
            cmd.commit(); return
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        var params = DisplayParams(crop: cropRect)
        enc.setFragmentBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Every ~20 frames, ease `cropRect` toward the core's border-trimmed
    /// visible area. Easing (not snapping) keeps the picture from jumping when
    /// on-screen content briefly changes the detected box; the degenerate /
    /// too-small guard keeps a transient near-blank frame from collapsing it.
    private func refreshAutoCrop() {
        guard autoCrop, !cropLocked else { return }
        sinceCropSample += 1
        guard sinceCropSample >= 20 else { return }
        sinceCropSample = 0

        var l = 0.0, t = 0.0, r = 0.0, b = 0.0
        guard bridge.visibleCropLeft(&l, top: &t, right: &r, bottom: &b) else { return }
        guard r - l >= 0.45, b - t >= 0.45 else { return }   // reject implausible boxes

        let target = SIMD4<Float>(Float(l), Float(t), Float(r), Float(b))
        let diff = max(abs(target.x - cropRect.x), abs(target.y - cropRect.y),
                       abs(target.z - cropRect.z), abs(target.w - cropRect.w))
        cropRect += (target - cropRect) * 0.5    // converge quickly

        // Once the detected window holds steady for a few samples, LOCK it so the
        // picture stops re-fitting every time on-screen content changes.
        if diff < 0.012 {
            cropStableCount += 1
            if cropStableCount >= 3 {
                cropLocked = true
                MetalRenderer.lastLockedCrop = cropRect
            }
        } else {
            cropStableCount = 0
        }
    }

    private func ensureTexture() {
        let w = Int(AmigaFrameWidth), h = Int(AmigaFrameHeight)
        if let s = sourceTexture, s.width == w, s.height == h { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.texturePixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        sourceTexture = device.makeTexture(descriptor: desc)
        sourceTexture?.label = "amiga.frame.\(w)x\(h)"
    }
}
