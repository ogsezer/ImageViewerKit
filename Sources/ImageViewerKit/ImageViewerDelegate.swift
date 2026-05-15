// ImageViewerDelegate.swift
// ImageViewerKit
//
// Callback protocol for the host app to react to viewer events.

import AppKit
import Foundation

/// Implement this protocol in your app to receive events from the image viewer.
///
/// All methods are optional. Adopt only what you need.
///
/// Example:
/// ```swift
/// class MyController: ImageViewerDelegate {
///     func imageViewer(didLoad url: URL, size: CGSize) {
///         print("Loaded \(url.lastPathComponent) at \(size)")
///     }
/// }
/// ImageViewer.open(url: myURL, delegate: self)
/// ```
@MainActor
public protocol ImageViewerDelegate: AnyObject {

    /// Called after an image has been fully decoded and rendered.
    func imageViewer(didLoad url: URL, imageSize: CGSize)

    /// Called when the user navigates to a different image in gallery mode.
    func imageViewer(didNavigateTo url: URL, index: Int, total: Int)

    /// Called when the viewer window is closed by the user.
    func imageViewerDidClose()

    /// Called when a format is not supported or a decode error occurs.
    func imageViewer(didFailWith error: ImageViewerError, for url: URL)

    /// Called when the user triggers "Share" from the toolbar.
    func imageViewer(didRequestShare url: URL, from rect: NSRect, in view: NSView)
}

/// Default (no-op) implementations — make every method optional.
public extension ImageViewerDelegate {
    func imageViewer(didLoad url: URL, imageSize: CGSize) {}
    func imageViewer(didNavigateTo url: URL, index: Int, total: Int) {}
    func imageViewerDidClose() {}
    func imageViewer(didFailWith error: ImageViewerError, for url: URL) {}
    func imageViewer(didRequestShare url: URL, from rect: NSRect, in view: NSView) {}
}

// MARK: - Error Types

/// Errors that ImageViewerKit can surface to the delegate.
public enum ImageViewerError: Error, LocalizedError {
    case unsupportedFormat(String)
    case decodeFailed(URL, underlying: Error?)
    case fileNotFound(URL)
    case hdrUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported image format: .\(ext)"
        case .decodeFailed(let url, let err):
            return "Failed to decode \(url.lastPathComponent): \(err?.localizedDescription ?? "unknown error")"
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .hdrUnavailable:
            return "HDR rendering is not available on this display."
        }
    }
}
