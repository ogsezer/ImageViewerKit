// ThumbnailCache.swift
// ImageViewerKit
//
// LRU thumbnail cache backed by NSCache (memory) + disk (FileManager).
// Generates thumbnails asynchronously and never blocks the main thread.

import AppKit
import ImageIO
import Foundation
import CryptoKit   // Insecure.MD5 for cache key hashing

// MARK: - Cache Entry

private final class CacheEntry {
    let thumbnail: NSImage
    let fileModDate: Date?
    init(thumbnail: NSImage, fileModDate: Date?) {
        self.thumbnail  = thumbnail
        self.fileModDate = fileModDate
    }
}

// MARK: - ThumbnailCache

/// Shared, thread-safe LRU thumbnail cache.
/// Memory cache: NSCache (auto-evicts under memory pressure).
/// Disk cache:   ~/Library/Caches/ImageViewerKit/thumbnails/
public final class ThumbnailCache {

    // MARK: - Singleton

    public static let shared = ThumbnailCache()
    private init() { setupDiskCache() }

    // MARK: - Configuration

    /// Pixel size of generated thumbnails (square).
    public var thumbnailSize: CGFloat = 160

    // MARK: - Storage

    private let memoryCache = NSCache<NSString, CacheEntry>()
    private var diskCacheURL: URL!
    private let ioQueue = DispatchQueue(
        label: "com.imageviewerkit.thumbnailcache",
        qos: .utility
    )

    // MARK: - Setup

    private func setupDiskCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("ImageViewerKit/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL,
                                                  withIntermediateDirectories: true)
        memoryCache.countLimit = 500          // max 500 thumbnails in RAM
        memoryCache.totalCostLimit = 100_000_000  // ~100 MB
    }

    // MARK: - Public API

    /// Retrieve or generate the thumbnail for `url`.
    /// - Returns: Cached NSImage, or nil if not yet generated (starts async generation).
    public func thumbnail(for url: URL, completion: @escaping @Sendable (NSImage?) -> Void) {
        let key = cacheKey(for: url)

        // 1. Memory hit — instant
        if let entry = memoryCache.object(forKey: key as NSString) {
            completion(entry.thumbnail)
            return
        }

        // 2. Disk hit — fast
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let image = self.loadFromDisk(key: key) {
                let entry = CacheEntry(thumbnail: image, fileModDate: nil)
                self.memoryCache.setObject(entry, forKey: key as NSString,
                                           cost: self.cost(of: image))
                DispatchQueue.main.async { completion(image) }
                return
            }

            // 3. Generate — async
            self.generate(url: url, key: key) { image in
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    /// Async/await version.
    public func thumbnail(for url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            thumbnail(for: url) { image in
                continuation.resume(returning: image)
            }
        }
    }

    /// Remove a specific URL's thumbnail from memory and disk.
    public func evict(url: URL) {
        let key = cacheKey(for: url)
        memoryCache.removeObject(forKey: key as NSString)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let file = self.diskCacheURL.appendingPathComponent(key)
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Wipe the entire disk cache. Memory cache is cleared automatically by NSCache.
    public func clearDiskCache() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.diskCacheURL)
            try? FileManager.default.createDirectory(
                at: self.diskCacheURL, withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Generation

    private func generate(url: URL, key: String, completion: @escaping (NSImage?) -> Void) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            completion(nil)
            return
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            completion(nil)
            return
        }

        let size  = CGSize(width: cgThumb.width, height: cgThumb.height)
        let image = NSImage(cgImage: cgThumb, size: size)

        // Store in memory
        let entry = CacheEntry(thumbnail: image, fileModDate: fileModDate(url: url))
        memoryCache.setObject(entry, forKey: key as NSString, cost: cost(of: image))

        // Persist to disk
        saveToDisk(image: image, key: key)

        completion(image)
    }

    // MARK: - Disk I/O

    private func loadFromDisk(key: String) -> NSImage? {
        let file = diskCacheURL.appendingPathComponent(key + ".png")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(contentsOf: file)
    }

    private func saveToDisk(image: NSImage, key: String) {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let dest    = CGImageDestinationCreateWithURL(
                diskCacheURL.appendingPathComponent(key + ".png") as CFURL,
                "public.png" as CFString,
                1, nil
            )
        else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Helpers

    /// Build a stable, filesystem-safe cache key from a URL path.
    ///
    /// Earlier versions base64-encoded the full path, which produced filenames
    /// up to ~400 chars for deeply nested files — well over macOS's 255-byte
    /// filename limit (errno 63 ENAMETOOLONG). We now hash the path to a fixed
    /// 32-char MD5 hex string. MD5 is fine here: collision-resistance isn't
    /// security-critical for a thumbnail cache.
    private func cacheKey(for url: URL) -> String {
        let pathBytes = Data(url.path.utf8)
        let digest = Insecure.MD5.hash(data: pathBytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileModDate(url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func cost(of image: NSImage) -> Int {
        // Approximate bytes: w * h * 4 (RGBA)
        Int(image.size.width * image.size.height * 4)
    }
}
