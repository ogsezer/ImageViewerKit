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

    /// Display mode controlling SDR/HDR rendering. Default: `.auto`.
    /// Can be changed at runtime via the in-viewer toggle or `HDRRenderer.displayMode`.
    public var displayMode: DisplayMode = .auto

    /// Compare mode — render two views of the same image side by side.
    /// Useful for visually verifying the SDR/HDR difference. Default: `.off`.
    public var compareMode: CompareMode = .off

    /// Legacy boolean alias for `displayMode`.
    /// `true` ⇒ `.auto`; `false` ⇒ `.sdr`.
    @available(*, deprecated, renamed: "displayMode",
               message: "Use displayMode (.sdr / .hdr / .auto) instead.")
    public var allowsHDR: Bool {
        get { displayMode != .sdr }
        set { displayMode = newValue ? .auto : .sdr }
    }

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

    /// Show floating SDR/HDR/Auto display-mode toggle in the canvas corner. Default: true.
    public var showsDisplayModeToggle: Bool = true

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

    // MARK: - Init

    /// Explicitly public so callers outside the module can instantiate it.
    /// (Swift defaults struct inits to `internal` even when the type is `public`.)
    public init() {}

    // MARK: - Presets

    /// Default configuration — HDR on, all UI visible, sensible zoom limits.
    public static let `default` = ImageViewerConfiguration()

    /// Minimal configuration — no chrome, black background, HDR on.
    public static var minimal: ImageViewerConfiguration {
        var c = ImageViewerConfiguration()
        c.showsThumbnailStrip      = false
        c.showsMetadataPanel       = false
        c.showsToolbar             = false
        c.showsDisplayModeToggle   = false
        c.backgroundColor          = .black
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

    /// How the viewer should render image dynamic range.
    enum DisplayMode: String, CaseIterable, Sendable {
        /// Force standard dynamic range — tone-map any HDR content into [0…1].
        case sdr
        /// Force HDR with EDR (Extended Dynamic Range) on supported displays.
        /// On non-HDR displays the system clips at SDR white — same as .sdr visually.
        case hdr
        /// Use HDR if the current display supports it, otherwise SDR.
        case auto

        /// Short label suitable for badges and toolbar buttons.
        public var displayName: String {
            switch self {
            case .sdr:  return "SDR"
            case .hdr:  return "HDR"
            case .auto: return "Auto"
            }
        }

        /// SF Symbol name for use in toolbar/overlay buttons.
        public var symbolName: String {
            switch self {
            case .sdr:  return "sun.min"
            case .hdr:  return "sun.max.fill"
            case .auto: return "circle.righthalf.filled"
            }
        }

        /// Cycle to the next mode: auto → hdr → sdr → auto.
        public func cycled() -> DisplayMode {
            switch self {
            case .auto: return .hdr
            case .hdr:  return .sdr
            case .sdr:  return .auto
            }
        }
    }

    /// Side-by-side compare mode for visual SDR vs HDR comparison.
    enum CompareMode: String, CaseIterable, Sendable {
        /// No comparison — single rendering using the current displayMode.
        case off
        /// Vertical split: SDR (tone-mapped) on the left, HDR on the right,
        /// with a thin divider line. Overrides displayMode while active.
        case sideBySide

        public func cycled() -> CompareMode {
            switch self {
            case .off:        return .sideBySide
            case .sideBySide: return .off
            }
        }
    }

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
