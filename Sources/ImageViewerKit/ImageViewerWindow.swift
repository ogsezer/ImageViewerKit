// ImageViewerWindow.swift
// ImageViewerKit
//
// NSWindowController that owns the viewer window and manages its lifecycle.
// Hosts the ImageViewerViewController as its contentViewController.

import AppKit
import Foundation

/// Manages the floating image viewer window.
/// Created by `ImageViewer.open(...)` — not intended for direct instantiation.
@MainActor
public final class ImageViewerWindow: NSWindowController {

    // MARK: - State

    private let configuration: ImageViewerConfiguration
    private weak var delegate: (any ImageViewerDelegate)?

    private(set) var urls: [URL] = []
    private(set) var currentIndex: Int = 0

    private var viewerViewController: ImageViewerViewController?

    // MARK: - Init: URL(s)

    init(
        urls: [URL],
        startingAt index: Int,
        configuration: ImageViewerConfiguration,
        delegate: (any ImageViewerDelegate)?
    ) {
        self.configuration = configuration
        self.delegate = delegate
        self.urls = urls
        self.currentIndex = max(0, min(index, urls.count - 1))

        let window = Self.makeWindow(configuration: configuration)
        super.init(window: window)

        let vc = ImageViewerViewController(
            urls: urls,
            startingAt: currentIndex,
            configuration: configuration,
            delegate: delegate
        )
        self.viewerViewController = vc
        window.contentViewController = vc
        window.title = urls[currentIndex].lastPathComponent
    }

    // MARK: - Init: Raw NSImage

    init(
        image: NSImage,
        title: String,
        configuration: ImageViewerConfiguration,
        delegate: (any ImageViewerDelegate)?
    ) {
        self.configuration = configuration
        self.delegate = delegate

        let window = Self.makeWindow(configuration: configuration)
        super.init(window: window)

        let vc = ImageViewerViewController(
            image: image,
            configuration: configuration,
            delegate: delegate
        )
        self.viewerViewController = vc
        window.contentViewController = vc
        window.title = title
    }

    required init?(coder: NSCoder) { fatalError("Use ImageViewer.open(...)") }

    // MARK: - Window Factory

    private static func makeWindow(configuration: ImageViewerConfiguration) -> NSWindow {
        let size = configuration.initialWindowSize ?? NSSize(width: 1024, height: 720)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = configuration.backgroundColor
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 400, height: 300)
        window.center()

        // Restore frame if persistence is on
        if configuration.persistsWindowFrame {
            window.setFrameAutosaveName("ImageViewerKit.MainWindow")
        }

        return window
    }

    // MARK: - Public Controls

    /// Present and bring the window to front.
    func show() {
        showWindow(nil)
        if configuration.opensInFullscreen {
            window?.toggleFullScreen(nil)
        }
    }

    /// Load a new set of URLs into the existing window without recreating it.
    func load(urls: [URL], startingAt index: Int) {
        self.urls = urls
        self.currentIndex = index
        viewerViewController?.load(urls: urls, startingAt: index)
        window?.title = urls[safe: index]?.lastPathComponent ?? "Image Viewer"
    }

    /// Advance to next image.
    func next() { viewerViewController?.navigate(by: +1) }

    /// Go to previous image.
    func previous() { viewerViewController?.navigate(by: -1) }
}

// MARK: - Safe Collection Subscript

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
