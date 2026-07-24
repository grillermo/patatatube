// ios/PatataTube/Sources/AuthedImage.swift
import SwiftUI
import ImageIO
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
    /// Longest-edge pixel cap for the decoded bitmap. Grid cells are ≤420pt, so
    /// 1024px stays crisp at 2–3x while bounding each poster's decoded footprint
    /// to ~a few MB instead of the full source resolution (Sentry PATATATUBE-6
    /// OOM: full-res movie posters pushed the app past 1.5 GB).
    var maxPixelSize: CGFloat = 1024
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

    private func loadImage() async {
        // .task(id:) re-fires every time a lazy container brings the cell back
        // on screen; without these guards each scroll re-hits the server.
        if image != nil { return }
        let maxPixel = maxPixelSize

        // Memory-cached raw bytes: still downsample (off the main actor) rather
        // than full-res `UIImage(data:)`.
        if let path, let cached = ImageMemoryCache.shared.data(for: path) {
            image = await Self.decode(cached, maxPixel: maxPixel)
            return
        }

        // Cached poster on disk. Reading the whole file AND decoding it happened
        // on the main actor before (Sentry PATATATUBE-3: NSFileHandle.read at the
        // bottom of the app-hang stack). Do both on a detached task so the main
        // thread keeps rendering; hop back only to publish the small bitmap.
        if let localFileURL {
            let decoded = await Task.detached(priority: .userInitiated) { () -> (UIImage, Data)? in
                guard let data = try? Data(contentsOf: localFileURL),
                      let img = Self.downsample(data, maxPixel: maxPixel) else { return nil }
                return (img, data)
            }.value
            if let decoded {
                image = decoded.0
                if let path { ImageMemoryCache.shared.store(decoded.1, for: path) }
                return
            }
        }

        guard let path else { return }
        if let data = try? await model.api.imageData(path: path) {
            image = await Self.decode(data, maxPixel: maxPixel)
            ImageMemoryCache.shared.store(data, for: path)
            onNetworkLoad?(data)
        }
    }

    /// Downsamples `data` off the main actor and returns the resulting bitmap.
    private nonisolated static func decode(_ data: Data, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            downsample(data, maxPixel: maxPixel)
        }.value
    }

    /// Decodes `data` directly to a thumbnail no larger than `maxPixel` on its
    /// longest edge via ImageIO, so the in-memory bitmap is bounded regardless of
    /// the source poster's resolution. `kCGImageSourceShouldCacheImmediately`
    /// forces the decode here (off the main thread) instead of lazily during the
    /// first render. This is the fix for both the OOM (PATATATUBE-6, full-res
    /// bitmaps) and the main-thread decode hang (PATATATUBE-3, -2).
    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        let image = UIImage(cgImage: cgImage)
        let bytes = cgImage.width * cgImage.height * 4
        Self.log.log("downsample \(cgImage.width, privacy: .public)x\(cgImage.height, privacy: .public) bitmap=\(Double(bytes) / (1024 * 1024), privacy: .public)MB from=\(data.count, privacy: .public)B")
        return image
    }
}
