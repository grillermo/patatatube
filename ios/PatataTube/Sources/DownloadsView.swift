import PatataTubeKit
import SwiftUI

struct DownloadsView: View {
    let active: () -> [DownloadActivity]
    let recent: () -> [DownloadCompletion]
    let video: (Int, Int?) -> Video?
    let onCancel: (DownloadActivity) -> Void
    let onPlay: (Video) -> Void
    /// Monotonic cumulative downloaded bytes. Defaults to a constant so tests
    /// and previews that don't care about the speed readout stay untouched.
    var byteCount: () -> Int64 = { 0 }
    // Optional lifecycle seam for hosted inspection of SwiftUI-resolved environment values.
    var didAppear: ((Self) -> Void)? = nil
    @EnvironmentObject var model: AppModel
    @Environment(JobsStore.self) private var jobsStore: JobsStore?
    @State private var meter = DownloadSpeedMeter()
    // Deliberately not driven from inside the TimelineView body below:
    // mutating @State during body evaluation is a render-phase write.
    @State private var speedTicks = Timer
        .publish(every: 0.25, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let activeItems = active()
            let completed = recent().compactMap { completion in
                video(completion.videoID, completion.versionID).map { (completion, $0) }
            }
            let snapshot = jobsStore?.snapshot ?? .empty
            let converting = snapshot.running + snapshot.queued
            List {
                if !converting.isEmpty {
                    Section("Converting") {
                        ForEach(converting) { job in
                            convertingRow(job)
                        }
                        // The server sends at most 20 queued rows; the rest is a count.
                        if snapshot.queuedTotal > snapshot.queued.count {
                            Text("+\(snapshot.queuedTotal - snapshot.queued.count) more")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !activeItems.isEmpty {
                    Section {
                        ForEach(activeItems) { item in
                            activeRow(item)
                        }
                    } header: {
                        HStack {
                            Text("In Progress")
                            Spacer()
                            if let rate = meter.formattedRate {
                                Text(rate).monospacedDigit()
                            }
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
            .onReceive(speedTicks) { date in
                let bytes = byteCount()
                meter.record(byteCount: bytes, at: date)
                let d = meter.diagnostics
                DevLog.event(.download, "speed tick", [
                    "bytes": "\(bytes)",
                    "samples": "\(d.samples)",
                    "span": String(format: "%.2f", d.span),
                    "window_delta": "\(d.newest - d.oldest)",
                    "rate": meter.bytesPerSecond.map { String(format: "%.0f", $0) } ?? "-",
                    "shown": meter.formattedRate ?? "-",
                    "active": "\(activeItems.count)",
                ])
            }
        }
        .onAppear {
            jobsStore?.subscribe()
            // Confirms the real counter is wired here and not the `{ 0 }`
            // default this view falls back to for tests and previews.
            DevLog.event(.download, "downloads view appeared", [
                "bytes": "\(byteCount())",
                "active": "\(active().count)",
            ])
            didAppear?(self)
        }
        .onDisappear { jobsStore?.unsubscribe() }
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

    private func convertingRow(_ job: ConversionJob) -> some View {
        let rowVideo = video(job.videoID, job.versionID)
        return HStack {
            thumbnail(rowVideo)
            Text(rowVideo?.title ?? job.title ?? "Video \(job.videoID)")
            Spacer()
            if let progress = job.progress, progress > 0 {
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.circular)
                    .frame(width: 22, height: 22)
            } else {
                ProgressView().frame(width: 22, height: 22)
            }
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
