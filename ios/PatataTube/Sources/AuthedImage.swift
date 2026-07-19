// ios/PatataTube/Sources/AuthedImage.swift
import SwiftUI
import PatataTubeKit

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

    private func loadImage() async {
        // .task(id:) re-fires every time a lazy container brings the cell back
        // on screen; without these guards each scroll re-hits the server.
        if image != nil { return }
        if let path, let cached = ImageMemoryCache.shared.data(for: path) {
            image = UIImage(data: cached)
            return
        }
        if let localFileURL, let data = try? Data(contentsOf: localFileURL) {
            image = UIImage(data: data)
            if let path { ImageMemoryCache.shared.store(data, for: path) }
            return
        }
        guard let path else { return }
        if let data = try? await model.api.imageData(path: path) {
            image = UIImage(data: data)
            ImageMemoryCache.shared.store(data, for: path)
            onNetworkLoad?(data)
        }
    }
}
