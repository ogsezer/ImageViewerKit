// swift-tools-version: 5.9
// ImageViewerKit — A reusable macOS image viewer framework
// Supports: HEIC, HDR (EXR, HDR), RAW, AVIF, WebP, PNG, JPEG, TIFF + 100 more

import PackageDescription

let package = Package(
    name: "ImageViewerKit",
    platforms: [
        .macOS(.v13)   // Minimum: macOS Ventura (Metal EDR, SwiftUI, async/await)
    ],
    products: [
        // Any app adds this as a dependency and gets the full viewer
        .library(
            name: "ImageViewerKit",
            targets: ["ImageViewerKit"]
        ),
    ],
    dependencies: [
        // ── External decoders (add when ready to integrate) ──────────────────
        // LibRaw — RAW camera format decoder (CR3, NEF, ARW, DNG…)
        // .package(url: "https://github.com/Marketplacer/libraw-swift", from: "1.0.0"),

        // libheif — Deep HEIC/HEIF/AVIF + HDR10/Dolby Vision metadata
        // .package(url: "https://github.com/strukturag/libheif", from: "1.17.0"),

        // OpenEXR — Float HDR EXR format (VFX industry standard)
        // .package(url: "https://github.com/AcademySoftwareFoundation/openexr", from: "3.2.0"),

        // OpenImageIO — 100+ format fallback catch-all
        // .package(url: "https://github.com/AcademySoftwareFoundation/OpenImageIO", from: "2.5.0"),
    ],
    targets: [
        .target(
            name: "ImageViewerKit",
            dependencies: [],
            path: "Sources/ImageViewerKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ImageViewerKitTests",
            dependencies: ["ImageViewerKit"],
            path: "Tests/ImageViewerKitTests"
        ),
    ]
)
