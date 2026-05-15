// HDRRenderer.swift
// ImageViewerKit
//
// Metal-backed image canvas with Apple EDR (Extended Dynamic Range) support.
// Renders true HDR on Pro Display XDR, MacBook Pro 14/16, iPhone 15 Pro.
// Falls back gracefully to SDR Core Image rendering on other screens.

import AppKit
import Metal
import MetalKit
import CoreImage
import QuartzCore

// MARK: - HDRRenderer

/// The main image display view.
/// Drop this into any NSView hierarchy — it handles zoom, pan, HDR, and SDR.
public final class HDRRenderer: NSView {

    // MARK: - Metal

    private var metalDevice: MTLDevice?
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?

    // MARK: - Image State

    private var currentCIImage: CIImage?
    private var currentTransform: CGAffineTransform = .identity
    private var zoomScale: CGFloat = 1.0
    private var rotation: CGFloat  = 0.0   // degrees
    private var panOffset: CGPoint = .zero

    // MARK: - Config

    private let configuration: ImageViewerConfiguration

    // MARK: - Init

    public init(configuration: ImageViewerConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupMetal()
    }

    required init?(coder: NSCoder) { fatalError("Use init(configuration:)") }

    // MARK: - Metal Setup

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal — fall back to pure Core Image rendering
            return
        }

        self.metalDevice  = device
        self.commandQueue = device.makeCommandQueue()

        // Build a CAMetalLayer with EDR enabled
        let layer = CAMetalLayer()
        layer.device             = device
        layer.pixelFormat        = .rgba16Float     // 16-bit float per channel for HDR
        layer.framebufferOnly    = false
        layer.contentsScale      = window?.backingScaleFactor ?? 2.0

        if configuration.allowsHDR {
            // 🌟 This is the key line that enables HDR on supported displays
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        self.layer    = layer
        self.metalLayer = layer
        self.wantsLayer = true

        // Build a CIContext on the Metal device for GPU-accelerated compositing
        let options: [CIContextOption: Any] = [
            .workingColorSpace: configuration.allowsHDR
                ? (CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any)
                : (CGColorSpace(name: CGColorSpace.sRGB) as Any),
            .outputColorSpace: configuration.allowsHDR
                ? (CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any)
                : (CGColorSpace(name: CGColorSpace.sRGB) as Any)
        ]
        self.ciContext = CIContext(mtlDevice: device, options: options)
    }

    // MARK: - Display

    /// Display an NSImage — converts to CIImage and renders with current zoom/pan.
    public func display(image: NSImage, configuration: ImageViewerConfiguration) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        currentCIImage = CIImage(cgImage: cgImage)
        resetTransform(imageSize: image.size)
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard
            let ciImage   = currentCIImage,
            let metalLayer = metalLayer,
            let drawable   = metalLayer.nextDrawable(),
            let cmdQueue   = commandQueue,
            let ciContext  = ciContext
        else { return }

        // Apply zoom, pan, rotation to the CIImage
        var transformed = ciImage
            .transformed(by: CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .transformed(by: CGAffineTransform(scaleX: zoomScale, y: zoomScale))
            .transformed(by: CGAffineTransform(translationX: panOffset.x, y: panOffset.y))

        // Tone-map HDR → SDR if the display doesn't support EDR
        if configuration.allowsHDR && !displaySupportsHDR() {
            transformed = applyToneMapping(to: transformed, mode: configuration.toneMappingMode)
        }

        // Render CIImage into the Metal drawable texture
        guard
            let cmdBuffer = cmdQueue.makeCommandBuffer()
        else { return }

        let destination = CIRenderDestination(
            width:       Int(drawable.texture.width),
            height:      Int(drawable.texture.height),
            pixelFormat: drawable.texture.pixelFormat,
            commandBuffer: cmdBuffer
        ) { () -> MTLTexture in drawable.texture }

        do {
            try ciContext.startTask(toRender: transformed, from: transformed.extent,
                                    to: destination, at: .zero)
        } catch {
            print("[ImageViewerKit] Render error: \(error)")
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - Tone Mapping

    private func applyToneMapping(
        to image: CIImage,
        mode: ImageViewerConfiguration.ToneMappingMode
    ) -> CIImage {
        switch mode {
        case .clamp:
            return image.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
        case .reinhard, .aces, .auto:
            // Use Apple's built-in tone curve filter as a sensible default
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
        // maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 means HDR capable
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    // MARK: - Zoom & Pan

    public func zoom(by factor: CGFloat) {
        let newScale = (zoomScale * factor)
            .clamped(to: configuration.minimumZoomScale...configuration.maximumZoomScale)
        zoomScale = newScale
        render()
    }

    public func zoomTo(_ scale: CGFloat) {
        zoomScale = scale.clamped(
            to: configuration.minimumZoomScale...configuration.maximumZoomScale
        )
        render()
    }

    public func zoomToFit() {
        guard let ciImage = currentCIImage else { return }
        let imageSize = ciImage.extent.size
        let viewSize  = bounds.size
        let scaleX = viewSize.width  / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        zoomScale  = min(scaleX, scaleY)
        panOffset  = .zero
        render()
    }

    public func toggleZoomFitOrActual() {
        if abs(zoomScale - 1.0) < 0.01 { zoomToFit() } else { zoomTo(1.0) }
    }

    public func rotate(by degrees: CGFloat) {
        rotation = (rotation + degrees).truncatingRemainder(dividingBy: 360)
        render()
    }

    // MARK: - Gesture Handling

    public override func magnify(with event: NSEvent) {
        guard configuration.allowsPinchZoom else { return }
        zoom(by: 1.0 + event.magnification)
    }

    public override func scrollWheel(with event: NSEvent) {
        panOffset.x += event.scrollingDeltaX
        panOffset.y -= event.scrollingDeltaY
        render()
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        metalLayer?.frame = bounds
        metalLayer?.drawableSize = CGSize(
            width:  bounds.width  * (window?.backingScaleFactor ?? 2),
            height: bounds.height * (window?.backingScaleFactor ?? 2)
        )
        render()
    }

    // MARK: - Helpers

    private func resetTransform(imageSize: NSSize) {
        rotation  = 0
        panOffset = .zero
        // Auto-fit on first display
        let scaleX = bounds.width  / imageSize.width
        let scaleY = bounds.height / imageSize.height
        zoomScale  = min(scaleX, scaleY, 1.0)   // never upscale beyond 100% on load
    }
}

// MARK: - Comparable clamp helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
