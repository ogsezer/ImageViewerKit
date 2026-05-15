// ImageViewerViewController.swift
// ImageViewerKit
//
// The main view controller. Hosts:
//   • HDRRenderer (Metal canvas) — the image display surface
//   • Toolbar (zoom, rotate, fullscreen, share)
//   • Thumbnail strip (gallery mode)
//   • Metadata panel (EXIF, size, format)
//
// Decoding is fully async via ImageDecoderPipeline — the UI never blocks.

import AppKit
import Foundation

@MainActor
public final class ImageViewerViewController: NSViewController {

    // MARK: - Dependencies

    private let configuration: ImageViewerConfiguration
    private weak var delegate: (any ImageViewerDelegate)?
    private let decoderPipeline: ImageDecoderPipeline
    private let thumbnailCache: ThumbnailCache

    // MARK: - State

    private var urls: [URL] = []
    private var currentIndex: Int = 0
    private var currentImage: NSImage?
    private var slideshowTimer: Timer?

    // MARK: - Subviews

    private var hdrRenderer: HDRRenderer!
    private var thumbnailStripView: ThumbnailStripView?
    private var toolbarView: ViewerToolbarView?
    private var metadataView: MetadataView?
    private var loadingIndicator: NSProgressIndicator!

    // MARK: - Init: URLs

    init(
        urls: [URL],
        startingAt index: Int,
        configuration: ImageViewerConfiguration,
        delegate: (any ImageViewerDelegate)?
    ) {
        self.urls = urls
        self.currentIndex = index
        self.configuration = configuration
        self.delegate = delegate
        self.decoderPipeline = ImageDecoderPipeline(priority: configuration.decoderPriority)
        self.thumbnailCache = ThumbnailCache.shared
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: - Init: Raw NSImage

    init(
        image: NSImage,
        configuration: ImageViewerConfiguration,
        delegate: (any ImageViewerDelegate)?
    ) {
        self.configuration = configuration
        self.delegate = delegate
        self.decoderPipeline = ImageDecoderPipeline(priority: configuration.decoderPriority)
        self.thumbnailCache = ThumbnailCache.shared
        self.currentImage = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use ImageViewer.open(...)") }

    // MARK: - View Lifecycle

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 720))
        view.wantsLayer = true
        view.layer?.backgroundColor = configuration.backgroundColor.cgColor
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupHDRRenderer()
        setupLoadingIndicator()
        if configuration.showsToolbar        { setupToolbar() }
        if configuration.showsThumbnailStrip { setupThumbnailStrip() }
        if configuration.showsMetadataPanel  { setupMetadataPanel() }
        setupKeyboardShortcuts()
        setupGestures()

        // Load first image or the pre-supplied NSImage
        if let img = currentImage {
            hdrRenderer.display(image: img, configuration: configuration)
        } else if !urls.isEmpty {
            loadImage(at: currentIndex)
        }
    }

    // MARK: - Layout

    private func setupHDRRenderer() {
        hdrRenderer = HDRRenderer(configuration: configuration)
        hdrRenderer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hdrRenderer)
        NSLayoutConstraint.activate([
            hdrRenderer.topAnchor.constraint(equalTo: view.topAnchor),
            hdrRenderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hdrRenderer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hdrRenderer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupLoadingIndicator() {
        loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .large
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isHidden = true
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupToolbar() {
        let toolbar = ViewerToolbarView(delegate: self)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
        ])
        self.toolbarView = toolbar
    }

    private func setupThumbnailStrip() {
        let strip = ThumbnailStripView(urls: urls, selectedIndex: currentIndex, delegate: self)
        strip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 88),
        ])
        self.thumbnailStripView = strip
    }

    private func setupMetadataPanel() {
        let meta = MetadataView()
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.isHidden = true   // shown on toggle
        view.addSubview(meta)
        NSLayoutConstraint.activate([
            meta.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            meta.topAnchor.constraint(equalTo: view.topAnchor, constant: 48),
            meta.widthAnchor.constraint(equalToConstant: 240),
            meta.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -88),
        ])
        self.metadataView = meta
    }

    // MARK: - Image Loading

    func load(urls: [URL], startingAt index: Int) {
        self.urls = urls
        thumbnailStripView?.update(urls: urls, selectedIndex: index)
        loadImage(at: index)
    }

    private func loadImage(at index: Int) {
        guard index >= 0, index < urls.count else { return }
        currentIndex = index

        let url = urls[index]
        showLoading(true)

        Task {
            do {
                let result = try await decoderPipeline.decode(url: url)
                await MainActor.run {
                    self.showLoading(false)
                    self.hdrRenderer.display(image: result.image, configuration: self.configuration)
                    self.metadataView?.update(with: result.metadata)
                    self.thumbnailStripView?.select(index: index)
                    self.view.window?.title = url.lastPathComponent
                    self.delegate?.imageViewer(
                        didLoad: url,
                        imageSize: CGSize(
                            width: result.image.size.width,
                            height: result.image.size.height
                        )
                    )
                    self.delegate?.imageViewer(
                        didNavigateTo: url,
                        index: index,
                        total: self.urls.count
                    )
                }
            } catch {
                await MainActor.run {
                    self.showLoading(false)
                    let viewerError: ImageViewerError = (error as? ImageViewerError)
                        ?? .decodeFailed(url, underlying: error)
                    self.delegate?.imageViewer(didFailWith: viewerError, for: url)
                }
            }
        }
    }

    // MARK: - Navigation

    func navigate(by delta: Int) {
        guard !urls.isEmpty else { return }
        let next = (currentIndex + delta + urls.count) % urls.count
        loadImage(at: next)
    }

    // MARK: - Slideshow

    private func startSlideshow(interval: TimeInterval) {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.navigate(by: +1) }
        }
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    // MARK: - Keyboard Shortcuts

    private func setupKeyboardShortcuts() {
        // Left/right arrow keys handled in keyDown
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: navigate(by: -1)           // ← left arrow
        case 124: navigate(by: +1)           // → right arrow
        case 53:  view.window?.close()       // Esc
        case 3:   hdrRenderer.zoomToFit()   // F — fit
        case 29:  hdrRenderer.zoomTo(1.0)   // 0 — 100%
        default:  super.keyDown(with: event)
        }
    }

    // MARK: - Gesture Recognisers

    private func setupGestures() {
        let doubleTap = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap() {
        guard configuration.doubleClickToZoom else { return }
        hdrRenderer.toggleZoomFitOrActual()
    }

    // MARK: - Helpers

    private func showLoading(_ visible: Bool) {
        loadingIndicator.isHidden = !visible
        visible ? loadingIndicator.startAnimation(nil)
                : loadingIndicator.stopAnimation(nil)
    }
}

// MARK: - Toolbar Delegate

extension ImageViewerViewController: ViewerToolbarDelegate {
    func toolbarDidTapZoomIn()      { hdrRenderer.zoom(by: 1.25) }
    func toolbarDidTapZoomOut()     { hdrRenderer.zoom(by: 0.8) }
    func toolbarDidTapZoomToFit()   { hdrRenderer.zoomToFit() }
    func toolbarDidTapRotateCW()    { hdrRenderer.rotate(by: 90) }
    func toolbarDidTapRotateCCW()   { hdrRenderer.rotate(by: -90) }
    func toolbarDidTapFullscreen()  { view.window?.toggleFullScreen(nil) }
    func toolbarDidTapMetadata()    { metadataView?.isHidden.toggle() }
    func toolbarDidTapShare(from rect: NSRect) {
        guard currentIndex < urls.count else { return }
        delegate?.imageViewer(didRequestShare: urls[currentIndex], from: rect, in: view)
    }
}

// MARK: - Thumbnail Strip Delegate

extension ImageViewerViewController: ThumbnailStripDelegate {
    func thumbnailStrip(didSelect index: Int) {
        loadImage(at: index)
    }
}

// MARK: - Stub UI Types
// These are minimal stubs. Replace with full SwiftUI or AppKit implementations.

final class ViewerToolbarView: NSView {
    @MainActor protocol Delegate: AnyObject {
        func toolbarDidTapZoomIn(); func toolbarDidTapZoomOut()
        func toolbarDidTapZoomToFit(); func toolbarDidTapRotateCW()
        func toolbarDidTapRotateCCW(); func toolbarDidTapFullscreen()
        func toolbarDidTapMetadata(); func toolbarDidTapShare(from: NSRect)
    }
    init(delegate: any Delegate) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor protocol ViewerToolbarDelegate: AnyObject {
    func toolbarDidTapZoomIn(); func toolbarDidTapZoomOut()
    func toolbarDidTapZoomToFit(); func toolbarDidTapRotateCW()
    func toolbarDidTapRotateCCW(); func toolbarDidTapFullscreen()
    func toolbarDidTapMetadata(); func toolbarDidTapShare(from: NSRect)
}

final class ThumbnailStripView: NSView {
    @MainActor protocol Delegate: AnyObject { func thumbnailStrip(didSelect: Int) }
    init(urls: [URL], selectedIndex: Int, delegate: any Delegate) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func update(urls: [URL], selectedIndex: Int) {}
    func select(index: Int) {}
}

@MainActor protocol ThumbnailStripDelegate: AnyObject {
    func thumbnailStrip(didSelect index: Int)
}

final class MetadataView: NSView {
    required init?(coder: NSCoder) { fatalError() }
    override init(frame: NSRect) { super.init(frame: frame) }
    func update(with metadata: ImageMetadata) {}
}
