// HDRRenderer.swift
// ImageViewerKit
//
// Metal-backed image canvas with Apple EDR (Extended Dynamic Range) support.
// Renders true HDR on Pro Display XDR, MacBook Pro 14/16, iPhone 15 Pro.
// Falls back gracefully to SDR Core Image rendering on other screens.
//
// Display mode is RUNTIME-MUTABLE: setting `displayMode` reconfigures the
// CAMetalLayer (EDR flag, colorspace) and CIContext (working/output space)
// in place, then triggers a re-render.
//
// Compare mode (v1.2.0):
//   Set `compareSplit` to a value in 0…1 to render the LEFT half tone-mapped
//   to SDR and the RIGHT half in HDR (with a thin white divider). Set to nil
//   to disable. The PixelDrop app drives this from cursor X position when the
//   user presses 'C'.

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

    private var currentCIImage: CIImage?

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
    /// Left half = SDR (tone-mapped), right half = HDR.
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
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else {
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    private func rebuildCIContext(useHDR: Bool) {
        guard let device = metalDevice else { return }
        let cs = useHDR
            ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            : CGColorSpace(name: CGColorSpace.sRGB)
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: cs as Any,
            .outputColorSpace:  cs as Any
        ]
        self.ciContext = CIContext(mtlDevice: device, options: opts)
    }

    // MARK: - Display

    /// Display a CIImage directly — preferred path. The CIImage retains its
    /// extended-range pixel data all the way to the Metal drawable, which
    /// is essential for HDR rendering (NSImage extraction clips to SDR).
    public func display(ciImage: CIImage,
                        headroom: Float = 1.0,
                        configuration: ImageViewerConfiguration) {
        currentCIImage         = ciImage
        currentImageHeadroom   = max(1.0, headroom)
        userZoom               = 1.0
        userPan                = .zero
        rotation               = 0
        hasUserAdjustedZoom    = false
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    /// Display an NSImage with optional HDR headroom info from the decoder.
    /// ⚠️ This path goes through `NSImage.cgImage(forProposedRect:...)` which
    /// clips extended-range values to SDR. Prefer `display(ciImage:headroom:)`
    /// for actual HDR display.
    public func display(image: NSImage,
                        headroom: Float = 1.0,
                        configuration: ImageViewerConfiguration) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        currentCIImage         = CIImage(cgImage: cgImage)
        currentImageHeadroom   = max(1.0, headroom)
        userZoom               = 1.0
        userPan                = .zero
        rotation               = 0
        hasUserAdjustedZoom    = false
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    // MARK: - Rendering

    private func render() {
        guard
            let ciImage    = currentCIImage,
            let metalLayer = metalLayer,
            metalLayer.drawableSize.width  > 0,
            metalLayer.drawableSize.height > 0,
            let drawable   = metalLayer.nextDrawable(),
            let cmdQueue   = commandQueue,
            let ciContext  = ciContext
        else { return }

        // 1. Compute transform (centred + scaled to fit + user zoom/pan)
        let drawableSize = CGSize(width:  drawable.texture.width,
                                  height: drawable.texture.height)
        let imageSize    = ciImage.extent.size

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

        var positioned = ciImage.transformed(by: rotXfm)
        positioned = positioned.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let extent = positioned.extent
        let tx = (drawableSize.width  - extent.width)  / 2 - extent.origin.x + userPan.x
        let ty = (drawableSize.height - extent.height) / 2 - extent.origin.y + userPan.y
        positioned = positioned.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        // 2. Build the SDR and HDR variants we may need
        let hdrVersion = positioned                                     // pixels keep headroom
        let sdrVersion = applyToneMapping(to: positioned,               // tone-mapped to [0..1]
                                          mode: configuration.toneMappingMode)

        // 3. Choose final composite based on mode + compare split
        let drawableRect = CGRect(origin: .zero, size: drawableSize)
        let bg = CIImage(color: CIColor.black).cropped(to: drawableRect)
        var composited: CIImage

        if let split = compareSplit, (0.0...1.0).contains(split) {
            // Compare mode — left = SDR, right = HDR, divider in the middle
            let splitX = drawableSize.width * split
            let leftRect  = CGRect(x: 0,      y: 0, width: splitX,                    height: drawableSize.height)
            let rightRect = CGRect(x: splitX, y: 0, width: drawableSize.width - splitX, height: drawableSize.height)

            let leftSDR    = sdrVersion.cropped(to: leftRect)
            let rightHDR   = effectiveHDR() ? hdrVersion.cropped(to: rightRect)
                                            : sdrVersion.cropped(to: rightRect)
            let dividerW: CGFloat = 2
            let divider = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: CGRect(x: splitX - dividerW/2, y: 0,
                                    width: dividerW, height: drawableSize.height))
            composited = divider
                .composited(over: leftSDR)
                .composited(over: rightHDR)
                .composited(over: bg)
        } else if effectiveHDR() {
            composited = hdrVersion.composited(over: bg)
        } else {
            composited = sdrVersion.composited(over: bg)
        }

        // 4. Blit to the Metal drawable
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

    // MARK: - Tone Mapping

    private func applyToneMapping(to image: CIImage,
                                  mode: ImageViewerConfiguration.ToneMappingMode) -> CIImage {
        switch mode {
        case .clamp:
            return image.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
        case .reinhard, .aces, .auto:
            return image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.00),
                "inputPoint1": CIVector(x: 0.25, y: 0.18),
                "inputPoint2": CIVector(x: 0.50, y: 0.50),
                "inputPoint3": CIVector(x: 0.75, y: 0.82),
                "inputPoint4": CIVector(x: 1.00, y: 1.00)
            ])
        }
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
        guard let ciImage = currentCIImage,
              let metalLayer = metalLayer else { return }
        let drawableSize = metalLayer.drawableSize
        let imageSize    = ciImage.extent.size
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
