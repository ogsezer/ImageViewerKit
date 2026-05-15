// ImageViewer.swift
// ImageViewerKit
//
// PUBLIC FACADE — The single entry point any app needs.
// Usage:
//   import ImageViewerKit
//   ImageViewer.open(url: someURL)
//   ImageViewer.open(urls: [url1, url2], startingAt: 0)

import AppKit
import Foundation

/// The main entry point for ImageViewerKit.
/// Any macOS app can call these static methods to present the image viewer.
@MainActor
public final class ImageViewer {

    // MARK: - Singleton window management

    private static var activeWindow: ImageViewerWindow?

    // MARK: - Public API

    /// Open a single image in the viewer window.
    /// - Parameters:
    ///   - url: File URL of the image to display.
    ///   - configuration: Optional display configuration. Uses defaults if omitted.
    ///   - delegate: Optional delegate for callbacks (image loaded, closed, errors).
    public static func open(
        url: URL,
        configuration: ImageViewerConfiguration = .default,
        delegate: (any ImageViewerDelegate)? = nil
    ) {
        open(urls: [url], startingAt: 0, configuration: configuration, delegate: delegate)
    }

    /// Open a gallery of images, starting at a given index.
    /// - Parameters:
    ///   - urls: Ordered list of image file URLs.
    ///   - startingAt: Index of the first image to display. Defaults to 0.
    ///   - configuration: Optional display configuration.
    ///   - delegate: Optional delegate for callbacks.
    public static func open(
        urls: [URL],
        startingAt index: Int = 0,
        configuration: ImageViewerConfiguration = .default,
        delegate: (any ImageViewerDelegate)? = nil
    ) {
        guard !urls.isEmpty else { return }

        // Reuse existing window if already open
        if let existing = activeWindow {
            existing.load(urls: urls, startingAt: index)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = ImageViewerWindow(
            urls: urls,
            startingAt: index,
            configuration: configuration,
            delegate: delegate
        )
        window.show()
        activeWindow = window

        // Clear reference when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window.window,
            queue: .main
        ) { _ in
            ImageViewer.activeWindow = nil
        }
    }

    /// Open a raw NSImage directly (e.g. from clipboard or in-memory processing).
    /// - Parameters:
    ///   - image: The NSImage to display.
    ///   - title: Optional title shown in the window title bar.
    ///   - configuration: Optional display configuration.
    public static func open(
        image: NSImage,
        title: String = "Image Viewer",
        configuration: ImageViewerConfiguration = .default
    ) {
        let window = ImageViewerWindow(
            image: image,
            title: title,
            configuration: configuration,
            delegate: nil
        )
        window.show()
        activeWindow = window
    }

    /// Programmatically close the active viewer window, if open.
    public static func close() {
        activeWindow?.window?.close()
        activeWindow = nil
    }

    /// Whether the viewer window is currently visible.
    public static var isVisible: Bool {
        activeWindow?.window?.isVisible ?? false
    }
}
