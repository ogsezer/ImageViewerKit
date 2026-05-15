// ImageDecoderPipeline.swift
// ImageViewerKit
//
// Chain-of-responsibility decoder pipeline.
// Each decoder tries to handle the URL — first success wins.
// Decoders are tried in the priority order set in ImageViewerConfiguration.

import AppKit
import ImageIO
import Foundation

// MARK: - Decode Result

/// Decoded image plus extracted metadata.
public struct DecodedImage {
    /// AppKit-friendly representation, used for thumbnails and UI display.
    public let image: NSImage

    /// HDR-preserving CIImage. Populated when the decoder loaded the file
    /// via `CIImage(contentsOf:options:[.expandToHDR: true])` (macOS 14+),
    /// which applies any embedded ISO 21496-1 / Apple gain map natively.
    /// Renderers should prefer this over the NSImage round-trip — NSImage
    /// extraction via `cgImage(forProposedRect:...)` clips to SDR.
    public let ciImage: CIImage?

    public let metadata: ImageMetadata

    public init(image: NSImage, ciImage: CIImage? = nil, metadata: ImageMetadata) {
        self.image    = image
        self.ciImage  = ciImage
        self.metadata = metadata
    }
}

/// Rich metadata extracted alongside the image data.
public struct ImageMetadata {
    public var width: Int         = 0
    public var height: Int        = 0
    public var colorDepth: Int    = 8       // bits per channel
    public var colorSpace: String = "sRGB"
    public var isHDR: Bool        = false
    public var hasAlpha: Bool     = false
    public var format: String     = "Unknown"
    public var fileSize: Int64    = 0
    public var exif: [String: Any] = [:]

    /// HDR headroom of the decoded image:
    ///   • 1.0  →  no HDR boost (plain SDR)
    ///   • >1.0 →  pixels carry HDR data; e.g. 2.4 means highlights up to 2.4× SDR white
    /// Set by the decoder via `CIImage.contentHeadroom` (macOS 14+) when available.
    public var headroom: Float = 1.0

    /// True if the file has an embedded ISO 21496-1 (modern) or Apple HDR gain map.
    /// Detected via `CGImageSourceCopyAuxiliaryDataInfoAtIndex` — works on all
    /// supported macOS versions, regardless of decode API availability.
    public var hasGainMap: Bool = false

    public var dimensionString: String { "\(width) × \(height) px" }

    /// Whether this image has actual HDR pixel data (not just an HDR-capable container).
    public var hasHDRContent: Bool { headroom > 1.001 || hasGainMap }
}

// MARK: - Decoder Protocol

/// Any image decoder must implement this.
protocol ImageDecoder {
    /// File extensions this decoder can handle.
    var supportedExtensions: Set<String> { get }

    /// Decode the image at `url`, returning a DecodedImage or throwing.
    func decode(url: URL) async throws -> DecodedImage
}

// MARK: - Pipeline

/// Tries decoders in priority order and returns the first successful result.
final class ImageDecoderPipeline {

    private let decoders: [any ImageDecoder]

    init(priority: [ImageViewerConfiguration.DecoderType]) {
        // Build the ordered decoder list from priority
        self.decoders = priority.compactMap { type in
            switch type {
            case .imageIO:     return ImageIODecoder()
            case .libRaw:      return LibRawDecoder()
            case .openEXR:     return OpenEXRDecoder()
            case .libHeif:     return LibHeifDecoder()
            case .openImageIO: return OpenImageIODecoder()
            }
        }
    }

    /// Decode `url` using the first decoder that claims the extension.
    func decode(url: URL) async throws -> DecodedImage {
        let ext = url.pathExtension.lowercased()

        // Try decoders in priority order
        for decoder in decoders {
            if decoder.supportedExtensions.contains(ext) || decoder.supportedExtensions.contains("*") {
                do {
                    return try await decoder.decode(url: url)
                } catch {
                    // This decoder failed — try next one
                    continue
                }
            }
        }
        throw ImageViewerError.unsupportedFormat(ext)
    }
}

// MARK: - ① ImageIO Decoder (Apple native)

/// Handles HEIC, AVIF, WebP, PNG, JPEG, GIF, TIFF, BMP, ICO, PDF via Apple ImageIO.
/// Fastest on Apple Silicon — hardware-accelerated.
///
/// HDR support:
///   • macOS 14+: requests HDR decoding via `kCGImageSourceDecodeRequest`.
///     ImageIO automatically reads any embedded ISO 21496-1 gain map (used by
///     iPhone HEIC photos and modern HDR JPEGs), composites it onto the SDR
///     base, and returns a CGImage with HDR pixel values + content headroom.
///   • macOS 13:   falls back to standard SDR decode.
final class ImageIODecoder: ImageDecoder {

    let supportedExtensions: Set<String> = [
        "jpeg", "jpg", "png", "gif", "tiff", "tif",
        "heic", "heif", "avif", "webp", "bmp", "ico",
        "pdf", "psd", "svg"
    ]

    func decode(url: URL) async throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageViewerError.fileNotFound(url)
        }

        // ── Step 1: Detect gain map directly via auxiliary data ────────────
        // Works on every macOS — independent of decode API availability.
        let isoGainMapType   = "kCGImageAuxiliaryDataTypeISOGainMap"   as CFString
        let appleGainMapType = "kCGImageAuxiliaryDataTypeHDRGainMap"   as CFString

        let hasISOGainMap   = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, isoGainMapType)   != nil
        let hasAppleGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, appleGainMapType) != nil
        let hasGainMap      = hasISOGainMap || hasAppleGainMap

        // ── Step 2: HDR-preserving CIImage via Core Image ──────────────────
        // CIImage(contentsOf:options:[.expandToHDR: true]) is the Apple-blessed
        // path that:
        //   1. Decodes the SDR base
        //   2. Decodes the embedded gain map auxiliary
        //   3. Applies the gain-map formula  hdr = sdr × gain
        //   4. Returns a CIImage in extendedLinearSRGB with values >1.0
        //
        // This bypasses the NSImage→CGImage round-trip that AppKit performs
        // through Quartz, which clips extended values to SDR.
        var hdrCIImage: CIImage?
        if #available(macOS 14.0, *) {
            // Use raw value to be SDK-version-tolerant.
            let expandKey = CIImageOption(rawValue: "kCIImageExpandToHDR")
            let opts: [CIImageOption: Any] = [expandKey: true]
            hdrCIImage = CIImage(contentsOf: url, options: opts)
        }

        // ── Step 3: Get a CGImage for metadata + NSImage for UI ────────────
        // (Standard SDR decode is fine here — NSImage is only used for the
        // thumbnail strip / UI views; the renderer uses hdrCIImage.)
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let cgImage else {
            throw ImageViewerError.decodeFailed(url, underlying: nil)
        }

        // ── Step 4: Read precise headroom on macOS 15+ ─────────────────────
        var headroom: Float = 1.0
        if let ci = hdrCIImage, #available(macOS 15.0, *) {
            let h = Float(ci.contentHeadroom)
            if h > 0, h.isFinite { headroom = h }
        }

        // ── Step 5: Headroom heuristic when API didn't provide a value ─────
        if headroom <= 1.001 && hasGainMap {
            // iPhone HDR photos typically have ~2.0–3.0× headroom.
            headroom = 2.0
        }
        if headroom <= 1.001 {
            let isExtendedRange: Bool = cgImage.colorSpace
                .map { CGColorSpaceUsesExtendedRange($0) } ?? false
            if cgImage.bitsPerComponent > 8 || isExtendedRange {
                headroom = 1.6
            }
        }

        // ── Step 6: Build NSImage + metadata ───────────────────────────────
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: cgImage.width, height: cgImage.height))

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif  = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)

        var meta = ImageMetadata()
        meta.width      = cgImage.width
        meta.height     = cgImage.height
        meta.colorDepth = cgImage.bitsPerComponent
        meta.hasAlpha   = cgImage.alphaInfo != .none
        meta.format     = url.pathExtension.uppercased()
        meta.fileSize   = (attrs?[.size] as? Int64) ?? 0
        meta.exif       = exif
        meta.headroom   = headroom
        meta.hasGainMap = hasGainMap
        meta.isHDR      = headroom > 1.001 || hasGainMap || cgImage.bitsPerComponent > 8
        meta.colorSpace = cgImage.colorSpace?.name as String? ?? "Unknown"

        // ── Step 7: Diagnostic log ─────────────────────────────────────────
        #if DEBUG
        print("""
        [ImageViewerKit] \(url.lastPathComponent)
          format          = \(meta.format)  (\(meta.width)×\(meta.height), \(meta.colorDepth)-bit)
          colorSpace      = \(meta.colorSpace)
          hasISOGainMap   = \(hasISOGainMap)
          hasAppleGainMap = \(hasAppleGainMap)
          gainMap applied = \(hdrCIImage != nil)  (via CIImage.expandToHDR)
          headroom        = \(String(format: "%.2f×", meta.headroom))
          isHDR           = \(meta.isHDR)
        """)
        #endif

        return DecodedImage(image: nsImage, ciImage: hdrCIImage, metadata: meta)
    }
}

// MARK: - ② LibRaw Decoder (RAW camera files)

/// Handles CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, etc.
/// Requires libraw to be linked. Stub shown here — replace body with C bridge calls.
final class LibRawDecoder: ImageDecoder {

    let supportedExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "dng", "raf", "orf", "rw2", "pef", "x3f", "3fr",
        "mef", "mrw", "erf", "kdc", "dcr", "rwl"
    ]

    func decode(url: URL) async throws -> DecodedImage {
        // TODO: Bridge to LibRaw C API via a Swift wrapper:
        //   1. libraw_init(0)
        //   2. libraw_open_file(handle, path)
        //   3. libraw_unpack(handle)
        //   4. libraw_dcraw_process(handle)
        //   5. libraw_dcraw_make_mem_image(handle)
        //   6. Convert to CGImage → NSImage

        // Fallback: try ImageIO (handles DNG natively)
        return try await ImageIODecoder().decode(url: url)
    }
}

// MARK: - ③ OpenEXR Decoder (HDR float images)

/// Handles .exr — the VFX industry standard for HDR images.
/// Requires OpenEXR to be linked. Stub shown — replace with C++ bridge.
final class OpenEXRDecoder: ImageDecoder {

    let supportedExtensions: Set<String> = ["exr"]

    func decode(url: URL) async throws -> DecodedImage {
        // TODO: Bridge to OpenEXR C++ API:
        //   1. Imf::RgbaInputFile file(path)
        //   2. Read scanlines into Array<Imf::Rgba>
        //   3. Convert float16 pixels → CGImage (kCGBitmapFloatComponents | kCGImageAlphaPremultipliedLast)
        //   4. Wrap in NSImage with extended linear sRGB colorspace

        // Minimal stub: render a placeholder until bridge is wired
        let placeholder = NSImage(size: NSSize(width: 512, height: 512))
        var meta = ImageMetadata()
        meta.format  = "EXR"
        meta.isHDR   = true
        meta.colorDepth = 16
        return DecodedImage(image: placeholder, metadata: meta)
    }
}

// MARK: - ④ libheif Decoder (deep HEIC + HDR10/Dolby Vision)

/// Deeper HEIC/HEIF support with access to HDR10 and Dolby Vision metadata.
/// Requires libheif to be linked.
final class LibHeifDecoder: ImageDecoder {

    let supportedExtensions: Set<String> = ["heic", "heif", "hif", "avci"]

    func decode(url: URL) async throws -> DecodedImage {
        // TODO: Bridge to libheif C API:
        //   1. heif_context_alloc()
        //   2. heif_context_read_from_file(ctx, path)
        //   3. heif_context_get_primary_image_handle(ctx)
        //   4. heif_decode_image(handle, HEIF_COLORSPACE_RGB, HEIF_CHROMA_INTERLEAVED_RGBA)
        //   5. Extract HDR metadata (nclx, clli, mdcv colour info)
        //   6. Build CGImage with appropriate colorspace

        // Fallback: Apple ImageIO handles most HEIC fine
        return try await ImageIODecoder().decode(url: url)
    }
}

// MARK: - ⑤ OpenImageIO Decoder (catch-all)

/// Handles 100+ formats as a last resort.
/// Requires OpenImageIO to be linked.
final class OpenImageIODecoder: ImageDecoder {

    // Accepts anything — acts as the final fallback
    let supportedExtensions: Set<String> = ["*"]

    func decode(url: URL) async throws -> DecodedImage {
        // TODO: Bridge to OIIO C API:
        //   1. OIIO::ImageInput::open(path)
        //   2. Read spec (width, height, nchannels, format)
        //   3. input->read_image(OIIO::TypeDesc::FLOAT, buffer)
        //   4. Convert buffer → CGImage

        throw ImageViewerError.unsupportedFormat(url.pathExtension)
    }
}
