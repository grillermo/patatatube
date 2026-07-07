// ios/PatataTube/Sources/AuthedImage.swift
import SwiftUI
import PatataTubeKit

/// Image loaded through APIClient so token-gated server previews work.
/// Absolute URLs (YouTube thumbs) load without auth; local file URLs load directly.
struct AuthedImage: View {
    let path: String?
    var localFileURL: URL? = nil
    @EnvironmentObject var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: path) { await loadImage() }
    }

    private func loadImage() async {
        if let localFileURL, let data = try? Data(contentsOf: localFileURL) {
            image = UIImage(data: data)
            return
        }
        guard let path else { return }
        if let data = try? await model.api.imageData(path: path) {
            image = UIImage(data: data)
        }
    }
}
