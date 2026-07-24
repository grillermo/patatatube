// ios/PatataTube/Sources/AuthedImage.swift
import SwiftUI
import PatataTubeKit
import Sentry
import os

/// Image loaded through APIClient so token-gated server previews work.
/// Absolute URLs (YouTube thumbs) load without auth; local file URLs load directly.
struct AuthedImage: View {
    let path: String?
    var localFileURL: URL? = nil
    /// true → scaledToFill (crop to cover); false → scaledToFit (letterbox).
    var fill: Bool = true
    /// Called with the raw bytes when the image was fetched from the network
    /// (never for local-file loads). Lets callers persist it to a cache.
    var onNetworkLoad: ((Data) -> Void)? = nil
    @EnvironmentObject var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                let img = Image(uiImage: image).resizable()
                if fill { img.scaledToFill() } else { img.scaledToFit() }
            } else {
                ProgressView()
            }
        }
        .task(id: path) { await loadImage() }
    }

    private static let log = os.Logger(subsystem: "com.patatatube.app", category: "AuthedImage")

    /// Runs a synchronous, main-thread block and reports how long it took. App
    /// hangs (Sentry PATATATUBE-3) point at blocking file reads / image decodes
    /// happening on the main actor here; this pins which step and how big.
    @discardableResult
    private func timedMainThreadWork<T>(_ step: String, bytes: Int? = nil, _ body: () -> T) -> T {
        let start = DispatchTime.now()
        let result = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let kb = bytes.map { Double($0) / 1024 }
        Self.log.log("main-thread \(step, privacy: .public) took \(ms, privacy: .public)ms bytes=\(bytes ?? -1, privacy: .public) path=\(self.path ?? "-", privacy: .public)")
        let crumb = Breadcrumb(level: ms >= 500 ? .warning : .info, category: "AuthedImage")
        crumb.message = "\(step) \(String(format: "%.0f", ms))ms"
        crumb.data = ["step": step, "ms": ms, "bytes": bytes ?? -1, "path": path ?? "-", "kb": kb ?? -1]
        SentrySDK.addBreadcrumb(crumb)
        // Blocking the main thread past ~500ms is what accumulates into an app
        // hang; surface those as their own Sentry event so we can catch the file.
        if ms >= 500 {
            SentrySDK.capture(message: "AuthedImage main-thread \(step) slow: \(String(format: "%.0f", ms))ms") { scope in
                scope.setContext(value: [
                    "step": step,
                    "ms": ms,
                    "bytes": bytes ?? -1,
                    "path": self.path ?? "-",
                    "localFileURL": self.localFileURL?.lastPathComponent ?? "-"
                ], key: "authed_image")
            }
        }
        return result
    }

    private func loadImage() async {
        // .task(id:) re-fires every time a lazy container brings the cell back
        // on screen; without these guards each scroll re-hits the server.
        if image != nil { return }
        if let path, let cached = ImageMemoryCache.shared.data(for: path) {
            image = timedMainThreadWork("decode-memcache", bytes: cached.count) { UIImage(data: cached) }
            reportDecodedImage("decode-memcache", compressedBytes: cached.count)
            return
        }
        if let localFileURL {
            let data = timedMainThreadWork("read-localfile") { try? Data(contentsOf: localFileURL) }
            if let data {
                image = timedMainThreadWork("decode-localfile", bytes: data.count) { UIImage(data: data) }
                reportDecodedImage("decode-localfile", compressedBytes: data.count)
                if let path { ImageMemoryCache.shared.store(data, for: path) }
                return
            }
        }
        guard let path else { return }
        if let data = try? await model.api.imageData(path: path) {
            image = timedMainThreadWork("decode-network", bytes: data.count) { UIImage(data: data) }
            reportDecodedImage("decode-network", compressedBytes: data.count)
            ImageMemoryCache.shared.store(data, for: path)
            onNetworkLoad?(data)
        }
    }

    /// Records the decoded image's pixel dimensions and the resulting bitmap
    /// footprint. `UIImage(data:)` here does NOT downsample, so a large source
    /// poster is held at full resolution (~width*height*scale²*4 bytes) even in a
    /// small grid cell — the leading suspect for the OOM watchdog kills
    /// (PATATATUBE-6). This makes the per-image cost, and the running total
    /// footprint, visible in Sentry.
    private func reportDecodedImage(_ step: String, compressedBytes: Int) {
        guard let image else { return }
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let bitmapBytes = Int(pixelW * pixelH * 4)
        MemoryProbe.snapshot("authedimage-\(step)", extra: [
            "pixel_w": Int(pixelW),
            "pixel_h": Int(pixelH),
            "bitmap_bytes": bitmapBytes,
            "bitmap_mb": Double(bitmapBytes) / (1024 * 1024),
            "compressed_bytes": compressedBytes,
            "path": path ?? "-",
        ])
    }
}
