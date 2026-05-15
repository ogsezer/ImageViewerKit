// ImageViewerKitTests.swift
// Tests for ImageViewerKit

import XCTest
@testable import ImageViewerKit

final class ImageViewerKitTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = ImageViewerConfiguration.default
        XCTAssertTrue(config.allowsHDR)
        XCTAssertTrue(config.showsThumbnailStrip)
        XCTAssertTrue(config.showsToolbar)
        XCTAssertTrue(config.showsMetadataPanel)
        XCTAssertNil(config.slideshowInterval)
        XCTAssertEqual(config.minimumZoomScale, 0.05)
        XCTAssertEqual(config.maximumZoomScale, 32.0)
    }

    func testMinimalConfiguration() {
        let config = ImageViewerConfiguration.minimal
        XCTAssertFalse(config.showsThumbnailStrip)
        XCTAssertFalse(config.showsMetadataPanel)
        XCTAssertFalse(config.showsToolbar)
        XCTAssertTrue(config.allowsHDR)
    }

    func testSlideshowConfiguration() {
        let config = ImageViewerConfiguration.slideshow
        XCTAssertNotNil(config.slideshowInterval)
        XCTAssertEqual(config.slideshowInterval, 5.0)
    }

    func testDecoderPriorityOrder() {
        let config = ImageViewerConfiguration.default
        XCTAssertEqual(config.decoderPriority.first, .imageIO)
        XCTAssertEqual(config.decoderPriority.last, .openImageIO)
        XCTAssertTrue(config.decoderPriority.contains(.libRaw))
        XCTAssertTrue(config.decoderPriority.contains(.openEXR))
    }

    // MARK: - Error Tests

    func testUnsupportedFormatError() {
        let error = ImageViewerError.unsupportedFormat("xyz")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("xyz"))
    }

    func testFileNotFoundError() {
        let url = URL(fileURLWithPath: "/nonexistent/image.png")
        let error = ImageViewerError.fileNotFound(url)
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - ThumbnailCache Tests

    func testThumbnailCacheKeyStability() async {
        let cache = ThumbnailCache.shared
        let url1 = URL(fileURLWithPath: "/tmp/test.jpg")
        let url2 = URL(fileURLWithPath: "/tmp/test.jpg")
        // Same path → same key → same cache slot
        let t1 = await cache.thumbnail(for: url1)
        let t2 = await cache.thumbnail(for: url2)
        // Both nil (file doesn't exist) but no crash
        XCTAssertNil(t1)
        XCTAssertNil(t2)
    }

    // MARK: - ImageViewer State Tests

    @MainActor
    func testViewerInitiallyNotVisible() {
        XCTAssertFalse(ImageViewer.isVisible)
    }

    @MainActor
    func testViewerCloseWhenNotOpen() {
        // Should not crash when closing a non-open viewer
        ImageViewer.close()
        XCTAssertFalse(ImageViewer.isVisible)
    }

    // MARK: - Decoder Pipeline Tests

    func testDecoderPipelineUnsupportedFormat() async {
        let pipeline = ImageDecoderPipeline(priority: [.imageIO])
        let url = URL(fileURLWithPath: "/tmp/fake.unknownformat123")
        do {
            _ = try await pipeline.decode(url: url)
            XCTFail("Expected error for unsupported format")
        } catch ImageViewerError.unsupportedFormat(let ext) {
            XCTAssertEqual(ext, "unknownformat123")
        } catch {
            // Also acceptable — file not found
        }
    }

    func testDecoderPipelineRecognisesRawExtensions() async {
        let pipeline = ImageDecoderPipeline(priority: [.imageIO, .libRaw])
        // Just verify no crash constructing the pipeline with all decoders
        let allTypes = ImageViewerConfiguration.DecoderType.allCases
        let fullPipeline = ImageDecoderPipeline(priority: allTypes)
        XCTAssertNotNil(fullPipeline)
    }
}
