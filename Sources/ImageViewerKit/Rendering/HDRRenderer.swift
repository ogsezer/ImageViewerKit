// HDRRenderer.swift
// ImageViewerKit
//
// Metal-backed image canvas with Apple EDR support.
//
// Display strategy (v1.2.4):
//   The renderer holds TWO CIImages from the decoder:
//     • sdrCIImage — SDR base, no gain map applied (values in [0…1])
//     • hdrCIImage — gain map applied via CIImage.expandToHDR (values may be >1.0)
//
//   Each render() picks the right one based on `effectiveHDR()`. No tone-curve
//   hack, no re-decode on toggle. The Metal layer + CIContext are reconfigured
//   in place when the display mode changes.
//
// Compare mode:
//   `compareSplit ∈ 0…1` renders SDR on the left, HDR on the right with a
//   thin white divider — perfect for visualising the gain map's effect.

import AppKit
import Metal
import MetalKit
import CoreImage
import QuartzCore

// MARK: - HDRRenderer

public final class HDRRenderer: NSView {

    // MARK: - Metal

    private var metalDevice: MTLDevice?
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?

    // MARK: - Image State

    /// SDR base image — preferred for SDR display. Values ∈ [0…1].
    private var sdrCIImage: CIImage?
    /// HDR rendition — gain map applied. Values may be >1.0.
    private var hdrCIImage: CIImage?

    /// HDR headroom of the currently-displayed image (1.0 = SDR, >1.0 = HDR).
    public private(set) var currentImageHeadroom: Float = 1.0

    private var userZoom: CGFloat   = 1.0
    private var rotation: CGFloat   = 0.0
    private var userPan: CGPoint    = .zero
    private var hasUserAdjustedZoom = false

    // MARK: - Configuration

    private let configuration: ImageViewerConfiguration

    /// Current display mode. Setting reconfigures Metal/CI on the fly.
    public var displayMode: ImageViewerConfiguration.DisplayMode {
        didSet {
            guard oldValue != displayMode else { return }
            reconfigureForDisplayMode()
            render()
        }
    }

    /// Side-by-side compare. nil = disabled. 0…1 = horizontal split position.
    /// Left half = SDR base, right half = HDR.
    public var compareSplit: CGFloat? {
        didSet {
            guard oldValue != compareSplit else { return }
            render()
        }
    }

    // MARK: - Init

    public init(configuration: ImageViewerConfiguration) {
        self.configuration = configuration
        self.displayMode   = configuration.displayMode
        super.init(frame: .zero)
        wantsLayer = true
        setupMetal()
    }

    required init?(coder: NSCoder) { fatalError("Use init(configuration:)") }

    // MARK: - Metal Setup

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.metalDevice  = device
        self.commandQueue = device.makeCommandQueue()

        let layer = CAMetalLayer()
        layer.device          = device
        layer.pixelFormat     = .rgba16Float
        layer.framebufferOnly = false
        layer.contentsScale   = window?.backingScaleFactor ?? 2.0
        layer.backgroundColor = configuration.backgroundColor.cgColor
        layer.isOpaque        = true

        self.layer      = layer
        self.metalLayer = layer

        applyMetalLayerColorSettings(useHDR: effectiveHDR())
        rebuildCIContext(useHDR: effectiveHDR())
    }

    // MARK: - Display Mode Reconfiguration

    private func effectiveHDR() -> Bool {
        switch displayMode {
        case .sdr:  return false
        case .hdr:  return true
        case .auto: return displaySupportsHDR()
        }
    }

    private func reconfigureForDisplayMode() {
        let useHDR = effectiveHDR()
        applyMetalLayerColorSettings(useHDR: useHDR)
        rebuildCIContext(useHDR: useHDR)
    }

    private func applyMetalLayerColorSettings(useHDR: Bool) {
        guard let layer = metalLayer else { return }
        if useHDR {
            // HDR: extended-range linear sRGB primaries — supports values >1.0
            // and is the standard EDR pipeline space on Apple platforms.
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else {
            // SDR: Display P3 — WIDE-GAMUT SDR. Using plain sRGB here would
            // clip the iPhone HEIC source's saturated P3 reds/greens, which
            // reads visually as a tone-mapped (washed-out) image.
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
    }

    private func rebuildCIContext(useHDR: Bool) {
        guard let device = metalDevice else { return }

        // Working colorspace is ALWAYS extended-linear sRGB.
        // Linear → CI does compositing math in linear light (correct).
        // Extended → out-of-sRGB-gamut P3 colors are representable as
        //            negative values without clipping.
        // This eliminates the gamma-space math + gamut-clip artefacts
        // that previously made SDR look "tone-mapped".
        let workingCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

        // Output colorspace matches the destination layer.
        let outputCS = useHDR
            ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)   // HDR: keep extended linear
            : CGColorSpace(name: CGColorSpace.displayP3)            // SDR: gamma-encoded wide-gamut

        let opts: [CIContextOption: Any] = [
            .workingColorSpace: workingCS as Any,
            .outputColorSpace:  outputCS as Any
        ]
        self.ciContext = CIContext(mtlDevice: device, options: opts)
    }

    // MARK: - Display API

    /// Primary display method — provide both variants. Renderer picks the
    /// right one per frame based on display mode (SDR/HDR/Auto).
    /// At least one of `sdr` or `hdr` must be non-nil.
    public func display(sdr: CIImage?,
                        hdr: CIImage?,
                        headroom: Float = 1.0,
                        configuration: ImageViewerConfiguration) {
        sdrCIImage           = sdr
        hdrCIImage           = hdr
        currentImageHeadroom = max(1.0, headroom)
        userZoom             = 1.0
        userPan              = .zero
        rotation             = 0
        hasUserAdjustedZoom  = false
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    /// Convenience: display a single CIImage as both SDR and HDR
    /// (used when caller has only one variant — e.g. EXR, plain JPEG).
    public func display(ciImage: CIImage,
                        headroom: Float = 1.0,
                        configuration: ImageViewerConfiguration) {
        display(sdr: ciImage, hdr: ciImage, headroom: headroom, configuration: configuration)
    }

    /// ⚠️ Legacy NSImage path — clips extended values to SDR via AppKit's
    /// `cgImage(forProposedRect:...)`. Prefer `display(sdr:hdr:)`.
    public func display(image: NSImage,
                        headroom: Float = 1.0,
                        configuration: ImageViewerConfiguration) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let ci = CIImage(cgImage: cg)
        display(sdr: ci, hdr: ci, headroom: headroom, configuration: configuration)
    }

    // MARK: - Image Selection

    /// Pick the appropriate CIImage for the current rendering pass.
    private func currentImage(useHDR: Bool) -> CIImage? {
        if useHDR {
            return hdrCIImage ?? sdrCIImage
        } else {
            return sdrCIImage ?? hdrCIImage
        }
    }

    /// The image used for compare-mode probing of size etc.
    private func anyImage() -> CIImage? { hdrCIImage ?? sdrCIImage }

    // MARK: - Rendering

    private func render() {
        guard
            let metalLayer = metalLayer,
            metalLayer.drawableSize.width  > 0,
            metalLayer.drawableSize.height > 0,
            let drawable   = metalLayer.nextDrawable(),
            let cmdQueue   = commandQueue,
            let ciContext  = ciContext,
            let baseImage  = anyImage()
        else { return }

        let useHDR = effectiveHDR()

        // 1. Compute the shared transform (centred + scaled to fit + user zoom/pan)
        let drawableSize = CGSize(width:  drawable.texture.width,
                                  height: drawable.texture.height)
        let imageSize    = baseImage.extent.size

        let rotated     = abs(rotation.truncatingRemainder(dividingBy: 180)) > 0.001
        let imageBoundW = rotated ? imageSize.height : imageSize.width
        let imageBoundH = rotated ? imageSize.width  : imageSize.height
        let fitScale    = min(drawableSize.width  / imageBoundW,
                              drawableSize.height / imageBoundH)
        let scale       = fitScale * userZoom

        let rotXfm = CGAffineTransform.identity
            .translatedBy(x: imageSize.width / 2, y: imageSize.height / 2)
            .rotated(by: self.rotation * .pi / 180)
            .translatedBy(x: -imageSize.width / 2, y: -imageSize.height / 2)

        // Helper that applies the full transform pipeline to any CIImage
        // (so we can position SDR and HDR variants identically for compare mode).
        func position(_ image: CIImage) -> CIImage {
            var p = image.transformed(by: rotXfm)
            p = p.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ext = p.extent
            let tx = (drawableSize.width  - ext.width)  / 2 - ext.origin.x + userPan.x
            let ty = (drawableSize.height - ext.height) / 2 - ext.origin.y + userPan.y
            return p.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        }

        // 2. Choose composite based on compare/single mode
        let drawableRect = CGRect(origin: .zero, size: drawableSize)
        let bg = CIImage(color: CIColor.black).cropped(to: drawableRect)
        var composited: CIImage

        if let split = compareSplit, (0.0...1.0).contains(split),
           let sdr = sdrCIImage, let hdr = hdrCIImage {
            // Compare mode — left = SDR, right = HDR (regardless of display mode).
            // The Metal layer needs EDR to show the HDR side, so force EDR on.
            if !useHDR {
                applyMetalLayerColorSettings(useHDR: true)
                rebuildCIContext(useHDR: true)
            }
            let splitX     = drawableSize.width * split
            let leftRect   = CGRect(x: 0,      y: 0, width: splitX,                      height: drawableSize.height)
            let rightRect  = CGRect(x: splitX, y: 0, width: drawableSize.width - splitX, height: drawableSize.height)
            let leftSDR    = position(sdr).cropped(to: leftRect)
            let rightHDR   = position(hdr).cropped(to: rightRect)

            let dividerW: CGFloat = 2
            let divider = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: CGRect(x: splitX - dividerW/2, y: 0,
                                    width: dividerW, height: drawableSize.height))
            composited = divider
                .composited(over: leftSDR)
                .composited(over: rightHDR)
                .composited(over: bg)
        } else {
            // Single-image mode — render the picked variant verbatim.
            // No tone-mapping needed: SDR base is already in [0…1], HDR
            // variant has the gain map baked in. CIContext + CAMetalLayer
            // colorspace pairing handles the rest:
            //   • SDR mode → sRGB destination → HDR-only files clip naturally.
            //   • HDR mode → extendedLinearSRGB destination → values >1.0 retained.
            guard let img = currentImage(useHDR: useHDR) else { return }
            composited = position(img).composited(over: bg)
        }

        // 3. Blit to the Metal drawable
        guard let cmdBuffer = cmdQueue.makeCommandBuffer() else { return }
        let dest = CIRenderDestination(
            width:         Int(drawableSize.width),
            height:        Int(drawableSize.height),
            pixelFormat:   drawable.texture.pixelFormat,
            commandBuffer: cmdBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        do {
            try ciContext.startTask(toRender: composited,
                                    from: drawableRect,
                                    to: dest, at: .zero)
        } catch {
            print("[ImageViewerKit] Render error: \(error)")
        }
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - HDR Display Detection

    private func displaySupportsHDR() -> Bool {
        guard let screen = window?.screen else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    public var currentDisplaySupportsHDR: Bool { displaySupportsHDR() }

    // MARK: - Zoom & Pan API

    public func zoom(by factor: CGFloat) {
        hasUserAdjustedZoom = true
        userZoom = (userZoom * factor)
            .clamped(to: configuration.minimumZoomScale...configuration.maximumZoomScale)
        render()
    }

    public func zoomTo(_ scale: CGFloat) {
        hasUserAdjustedZoom = true
        userZoom = scale.clamped(to: configuration.minimumZoomScale...configuration.maximumZoomScale)
        render()
    }

    public func zoomToFit() {
        hasUserAdjustedZoom = false
        userZoom = 1.0
        userPan  = .zero
        render()
    }

    public func toggleZoomFitOrActual() {
        guard let img = anyImage(), let metalLayer = metalLayer else { return }
        let drawableSize = metalLayer.drawableSize
        let imageSize    = img.extent.size
        let fitScale     = min(drawableSize.width / imageSize.width,
                               drawableSize.height / imageSize.height)
        let actualZoom = 1.0 / fitScale
        if abs(userZoom - actualZoom) < 0.01 { zoomToFit() } else { zoomTo(actualZoom) }
    }

    public func rotate(by degrees: CGFloat) {
        rotation = (rotation + degrees).truncatingRemainder(dividingBy: 360)
        render()
    }

    @discardableResult
    public func cycleDisplayMode() -> ImageViewerConfiguration.DisplayMode {
        displayMode = displayMode.cycled()
        return displayMode
    }

    /// Toggle compare mode. When enabling, defaults the split to 50%.
    public func toggleCompareMode() {
        compareSplit = (compareSplit == nil) ? 0.5 : nil
    }

    // MARK: - Gestures

    public override func magnify(with event: NSEvent) {
        guard configuration.allowsPinchZoom else { return }
        zoom(by: 1.0 + event.magnification)
    }

    public override func scrollWheel(with event: NSEvent) {
        userPan.x += event.scrollingDeltaX
        userPan.y -= event.scrollingDeltaY
        render()
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer?.frame         = bounds
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize  = CGSize(width:  bounds.width  * scale,
                                           height: bounds.height * scale)
        render()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            metalLayer?.contentsScale = scale
        }
        if displayMode == .auto { reconfigureForDisplayMode() }
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
