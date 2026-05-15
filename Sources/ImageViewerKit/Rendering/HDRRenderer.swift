// HDRRenderer.swift
// ImageViewerKit
//
// Metal-backed image canvas with Apple EDR (Extended Dynamic Range) support.
// Renders true HDR on Pro Display XDR, MacBook Pro 14/16, iPhone 15 Pro.
// Falls back gracefully to SDR Core Image rendering on other screens.
//
// Display mode is RUNTIME-MUTABLE: setting `displayMode` reconfigures the
// CAMetalLayer (EDR flag, colorspace) and CIContext (working/output space)
// in place, then triggers a re-render. The same image will appear in SDR
// or HDR depending on the current mode.
//
// Layout model:
//   • `userZoom`  is a MULTIPLIER on the fit-to-view scale (1.0 = exactly fit).
//   • `userPan`   is an additional offset in drawable pixels (0,0 = centred).
//   • The actual display transform is recomputed every render(), so the image
//     re-centers correctly whenever the view resizes.

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
    private var userZoom: CGFloat   = 1.0      // 1.0 = fit to view
    private var rotation: CGFloat   = 0.0      // degrees
    private var userPan: CGPoint    = .zero    // drawable-pixel offset
    private var hasUserAdjustedZoom = false

    // MARK: - Configuration

    private let configuration: ImageViewerConfiguration

    /// Current display mode. Setting this reconfigures Metal/CI on the fly.
    public var displayMode: ImageViewerConfiguration.DisplayMode {
        didSet {
            guard oldValue != displayMode else { return }
            reconfigureForDisplayMode()
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

    /// Compute whether HDR should actually be on, given the current mode + display.
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

    /// Display an NSImage. Resets zoom/pan so the new image fits-to-view.
    public func display(image: NSImage, configuration: ImageViewerConfiguration) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        currentCIImage      = CIImage(cgImage: cgImage)
        userZoom            = 1.0
        userPan             = .zero
        rotation            = 0
        hasUserAdjustedZoom = false
        // Wait until the next layout pass — bounds may still be zero here.
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

        // 1. Compute the proper transform
        let drawableSize = CGSize(width:  drawable.texture.width,
                                  height: drawable.texture.height)
        let imageSize    = ciImage.extent.size

        let rotated     = abs(rotation.truncatingRemainder(dividingBy: 180)) > 0.001
        let imageBoundW = rotated ? imageSize.height : imageSize.width
        let imageBoundH = rotated ? imageSize.width  : imageSize.height
        let fitScale    = min(drawableSize.width  / imageBoundW,
                              drawableSize.height / imageBoundH)
        let scale       = fitScale * userZoom

        // 2. Build the chained transform — rotate around centre, scale, translate
        let rotation = CGAffineTransform.identity
            .translatedBy(x:  imageSize.width  / 2,
                          y:  imageSize.height / 2)
            .rotated(by: self.rotation * .pi / 180)
            .translatedBy(x: -imageSize.width  / 2,
                          y: -imageSize.height / 2)

        var transformed = ciImage.transformed(by: rotation)
        transformed = transformed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let scaledExtent = transformed.extent
        let tx = (drawableSize.width  - scaledExtent.width)  / 2 - scaledExtent.origin.x + userPan.x
        let ty = (drawableSize.height - scaledExtent.height) / 2 - scaledExtent.origin.y + userPan.y
        transformed = transformed.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        // 3. Tone-map only when forcing SDR (or auto on a non-HDR display)
        if !effectiveHDR() {
            transformed = applyToneMapping(to: transformed, mode: configuration.toneMappingMode)
        }

        // 4. Composite over black so areas outside the image are filled
        let bg = CIImage(color: CIColor.black)
            .cropped(to: CGRect(origin: .zero, size: drawableSize))
        let composited = transformed.composited(over: bg)

        // 5. Blit to the Metal drawable
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
                                    from: CGRect(origin: .zero, size: drawableSize),
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

    /// Public helper: does the current display support HDR?
    /// Useful for showing badge text like "(unavailable on this screen)".
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
        if abs(userZoom - actualZoom) < 0.01 {
            zoomToFit()
        } else {
            zoomTo(actualZoom)
        }
    }

    public func rotate(by degrees: CGFloat) {
        rotation = (rotation + degrees).truncatingRemainder(dividingBy: 360)
        render()
    }

    /// Cycle SDR → HDR → Auto → SDR. Returns the new mode.
    @discardableResult
    public func cycleDisplayMode() -> ImageViewerConfiguration.DisplayMode {
        displayMode = displayMode.cycled()
        return displayMode
    }

    // MARK: - Gesture Handling

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
        // .auto might resolve differently now that we know which display we're on
        if displayMode == .auto { reconfigureForDisplayMode() }
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
