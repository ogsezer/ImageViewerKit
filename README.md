# ImageViewerKit

A reusable, drop-in macOS image viewer framework.  
Any app can display HDR images, HEIC, RAW, EXR, WebP, AVIF and 100+ formats with a single line of code.

---

## Requirements
- macOS 13+ (Ventura)
- Swift 5.9+
- Xcode 15+

---

## Installation — Swift Package Manager

```swift
// In your Package.swift
.package(url: "https://github.com/your-org/ImageViewerKit", from: "1.0.0")
```

Or in Xcode: **File → Add Package Dependencies** → paste the repo URL.

---

## Usage

```swift
import ImageViewerKit

// Open a single image
ImageViewer.open(url: URL(fileURLWithPath: "/path/to/photo.heic"))

// Open a gallery, starting at index 2
ImageViewer.open(urls: imageURLs, startingAt: 2)

// Open a raw NSImage (e.g. from clipboard)
ImageViewer.open(image: myNSImage, title: "Clipboard Image")

// Custom configuration
var config = ImageViewerConfiguration()
config.allowsHDR            = true
config.showsThumbnailStrip  = true
config.toneMappingMode      = .aces
config.slideshowInterval    = 5.0

ImageViewer.open(url: myURL, configuration: config, delegate: self)

// Programmatic close
ImageViewer.close()
```

---

## Delegate (optional)

```swift
class MyViewController: ImageViewerDelegate {

    func imageViewer(didLoad url: URL, imageSize: CGSize) {
        print("Loaded \(url.lastPathComponent) — \(imageSize)")
    }

    func imageViewer(didNavigateTo url: URL, index: Int, total: Int) {
        print("Image \(index + 1) of \(total)")
    }

    func imageViewer(didFailWith error: ImageViewerError, for url: URL) {
        print("Error: \(error.localizedDescription)")
    }

    func imageViewerDidClose() {
        print("Viewer closed")
    }
}
```

---

## Supported Formats

| Decoder        | Formats |
|----------------|---------|
| **ImageIO**    | HEIC, AVIF, WebP, JPEG, PNG, GIF, TIFF, BMP, PDF |
| **LibRaw**     | CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, X3F + 1000 cameras |
| **OpenEXR**    | .exr (HDR float, deep, multi-layer) |
| **libheif**    | HEIC/HEIF with HDR10 + Dolby Vision metadata |
| **OpenImageIO**| 100+ fallback formats (DPX, Cineon, SGI, PSD…) |

---

## Architecture

```
ImageViewer (Facade)
    └── ImageViewerWindow (NSWindowController)
            └── ImageViewerViewController
                    ├── HDRRenderer          ← Metal + EDR display
                    ├── ImageDecoderPipeline ← chain of responsibility
                    ├── ThumbnailCache       ← NSCache + disk
                    ├── ThumbnailStripView   ← gallery filmstrip
                    ├── ViewerToolbarView    ← zoom, rotate, share
                    └── MetadataView         ← EXIF panel
```

---

## HDR Display

ImageViewerKit uses Apple's **EDR (Extended Dynamic Range)** pipeline via `CAMetalLayer`:

```swift
metalLayer.wantsExtendedDynamicRangeContent = true
metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
```

On non-HDR displays, HDR content is tone-mapped using configurable modes:
`auto` · `reinhard` · `aces` · `clamp`

---

## Configuration Presets

```swift
ImageViewerConfiguration.default    // HDR on, all UI, sensible defaults
ImageViewerConfiguration.minimal    // No chrome, black background
ImageViewerConfiguration.slideshow  // Auto-advance every 5 seconds
```

---

## License
MIT
