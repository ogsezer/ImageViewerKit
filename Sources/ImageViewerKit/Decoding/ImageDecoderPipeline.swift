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
    public let image: NSImage
    public let metadata: ImageMetadata
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

    public var dimensionString: String { "\(width) × \(height) px" }
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
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageViewerError.decodeFailed(url, underlying: nil)
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width, height: cgImage.height)
        )

        // Extract metadata from ImageIO properties
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif   = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let attrs  = try? FileManager.default.attributesOfItem(atPath: url.path)

        var meta = ImageMetadata()
        meta.width      = cgImage.width
        meta.height     = cgImage.height
        meta.colorDepth = cgImage.bitsPerComponent
        meta.hasAlpha   = cgImage.alphaInfo != .none
        meta.format     = url.pathExtension.uppercased()
        meta.fileSize   = (attrs?[.size] as? Int64) ?? 0
        meta.exif       = exif
        meta.isHDR      = cgImage.bitsPerComponent > 8
        meta.colorSpace = cgImage.colorSpace?.name as String? ?? "Unknown"

        return DecodedImage(image: image, metadata: meta)
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
