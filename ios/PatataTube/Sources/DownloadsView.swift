import PatataTubeKit
import SwiftUI

struct DownloadsView: View {
    let active: () -> [DownloadActivity]
    let recent: () -> [DownloadCompletion]
    let video: (Int, Int?) -> Video?
    let onCancel: (DownloadActivity) -> Void
    let onPlay: (Video) -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let activeItems = active()
            let completed = recent().compactMap { completion in
                video(completion.videoID, completion.versionID).map { (completion, $0) }
            }
            List {
                if !activeItems.isEmpty {
                    Section("In Progress") {
                        ForEach(activeItems) { item in
                            activeRow(item)
                        }
                    }
                }
                if !completed.isEmpty {
                    Section("Recently Completed") {
                        ForEach(completed, id: \.0.id) { _, item in
                            Button { onPlay(item) } label: {
                                Label(item.title ?? "Video \(item.id)", systemImage: "play.fill")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
        }
    }

    private func activeRow(_ item: DownloadActivity) -> some View {
        let itemVideo = video(item.videoID, item.versionID)
        return HStack {
            thumbnail(itemVideo)
            VStack(alignment: .leading) {
                Text(itemVideo?.title ?? "Video \(item.videoID)")
                ProgressView(value: item.progress)
            }
            Spacer()
            Button("Cancel") { onCancel(item) }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .combine)
    }

    /// Small poster to the left of the title. Thumb-sized decode (the grid's
    /// 1024px cap would be wasteful here) and reuses the disk-cached preview.
    @ViewBuilder
    private func thumbnail(_ video: Video?) -> some View {
        ZStack {
            Rectangle().fill(.black)
            if let video, video.previewUrl != nil || cachedPreview(video) != nil {
                Rectangle().fill(.clear)
                    .overlay {
                        AuthedImage(path: video.previewUrl,
                                    localFileURL: cachedPreview(video),
                                    onNetworkLoad: { data in
                                        guard let path = video.previewUrl,
                                              model.cache.cachedPreviewURL(for: video.id, path: path) == nil else { return }
                                        model.cache.storePreview(data, for: video.id, path: path)
                                    },
                                    maxPixelSize: 240)
                    }
                    .clipped()
            } else {
                Image(systemName: "film").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 40)
        .clipped()
        .cornerRadius(4)
        .accessibilityHidden(true)
    }

    private func cachedPreview(_ video: Video) -> URL? {
        model.cache.cachedPreviewURL(for: video.id, path: video.previewUrl)
    }
}
