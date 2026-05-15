// ImageViewerConfiguration.swift
// ImageViewerKit
//
// All tunable options for the viewer — passed in at open() time.

import AppKit
import Foundation

/// Configuration object controlling the look, feel, and capabilities
/// of the image viewer. Use `.default` for sensible out-of-the-box behaviour.
public struct ImageViewerConfiguration {

    // MARK: - HDR & Color

    /// Enable Metal EDR (Extended Dynamic Range) rendering on supported displays.
    /// Falls back gracefully to SDR on non-HDR screens. Default: true.
    public var allowsHDR: Bool = true

    /// Color space used for SDR fallback rendering. Default: sRGB.
    public var sdrColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Tone-mapping curve applied when displaying HDR content on SDR screens.
    public var toneMappingMode: ToneMappingMode = .auto

    // MARK: - UI Layout

    /// Show the filmstrip / thumbnail strip at the bottom in gallery mode. Default: true.
    public var showsThumbnailStrip: Bool = true

    /// Show image metadata panel (EXIF, file size, dimensions). Default: true.
    public var showsMetadataPanel: Bool = true

    /// Show toolbar with zoom, rotate, fullscreen controls. Default: true.
    public var showsToolbar: Bool = true

    /// Background colour behind the image canvas. Default: near-black.
    public var backgroundColor: NSColor = NSColor(white: 0.08, alpha: 1.0)

    // MARK: - Zoom & Navigation

    /// Minimum zoom scale. Default: 0.05 (5%).
    public var minimumZoomScale: CGFloat = 0.05

    /// Maximum zoom scale. Default: 32.0 (3200%).
    public var maximumZoomScale: CGFloat = 32.0

    /// Double-click zooms to fit or 100%, toggling between the two. Default: true.
    public var doubleClickToZoom: Bool = true

    /// Allow trackpad pinch-to-zoom gesture. Default: true.
    public var allowsPinchZoom: Bool = true

    // MARK: - Window Behaviour

    /// Initial window size. nil means the viewer picks a sensible default.
    public var initialWindowSize: NSSize? = nil

    /// Remember window size and position between launches. Default: true.
    public var persistsWindowFrame: Bool = true

    /// Enter fullscreen automatically when opening. Default: false.
    public var opensInFullscreen: Bool = false

    // MARK: - Slideshow

    /// Auto-advance interval in seconds. nil disables slideshow. Default: nil.
    public var slideshowInterval: TimeInterval? = nil

    // MARK: - Supported Format Hints

    /// Decoder priority order. Decoders are tried left-to-right until one succeeds.
    public var decoderPriority: [DecoderType] = [
        .imageIO,       // Apple native — fastest, handles HEIC/AVIF/WebP/PNG/JPEG
        .libRaw,        // RAW camera formats (CR3, NEF, ARW, DNG…)
        .openEXR,       // Float HDR .exr files
        .libHeif,       // Deep HEIC + HDR10/Dolby Vision metadata
        .openImageIO    // Catch-all: 100+ formats
    ]

    // MARK: - Presets

    /// Default configuration — HDR on, all UI visible, sensible zoom limits.
    public static let `default` = ImageViewerConfiguration()

    /// Minimal configuration — no chrome, black background, HDR on.
    public static var minimal: ImageViewerConfiguration {
        var c = ImageViewerConfiguration()
        c.showsThumbnailStrip = false
        c.showsMetadataPanel  = false
        c.showsToolbar        = false
        c.backgroundColor     = .black
        return c
    }

    /// Full-featured configuration with slideshow enabled (5 s interval).
    public static var slideshow: ImageViewerConfiguration {
        var c = ImageViewerConfiguration()
        c.slideshowInterval = 5.0
        return c
    }
}

// MARK: - Supporting Enums

public extension ImageViewerConfiguration {

    /// How HDR content is tone-mapped when shown on an SDR display.
    enum ToneMappingMode {
        /// Let the system choose the best mapping for the current display.
        case auto
        /// Reinhard global operator — smooth, cinematic.
        case reinhard
        /// ACES filmic curve — perceptually accurate, used in games/film.
        case aces
        /// Clamp values above SDR white — preserves colours below white point.
        case clamp
    }

    /// Identifies each decoder in the pipeline.
    enum DecoderType: String, CaseIterable {
        case imageIO     = "ImageIO"
        case libRaw      = "LibRaw"
        case openEXR     = "OpenEXR"
        case libHeif     = "libheif"
        case openImageIO = "OpenImageIO"
    }
}
