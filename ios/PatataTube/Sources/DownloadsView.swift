import PatataTubeKit
import SwiftUI

enum DownloadRateFormatter {
    static func text(bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "Calculating…" }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
                .replacingOccurrences(of: ".0 MB/s", with: " MB/s")
        }
        return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
            .replacingOccurrences(of: ".0 KB/s", with: " KB/s")
    }
}

struct DownloadsView: View {
    let active: () -> [DownloadActivity]
    let recent: () -> [DownloadCompletion]
    let video: (Int, Int?) -> Video?
    let onCancel: (DownloadActivity) -> Void
    let onPlay: (Video) -> Void

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
        let rate = DownloadRateFormatter.text(bytesPerSecond: item.bytesPerSecond)
        return HStack {
            VStack(alignment: .leading) {
                Text(video(item.videoID, item.versionID)?.title ?? "Video \(item.videoID)")
                ProgressView(value: item.progress)
            }
            Spacer()
            Text(rate)
                .monospacedDigit()
            Button("Cancel") { onCancel(item) }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(rate)
    }
}
