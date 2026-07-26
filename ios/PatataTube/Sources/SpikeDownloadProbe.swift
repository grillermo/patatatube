import AVFoundation
import Foundation

/// Throwaway spike. Prints answers to the four unknowns above. Delete before
/// merging anything — this never ships.
final class SpikeDownloadProbe: NSObject, AVAssetDownloadDelegate {
    private var session: AVAssetDownloadURLSession!
    private var task: AVAggregateAssetDownloadTask?
    private var localURL: URL?
    private var fractionAtCancel: Double = 0

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "spike.hls.probe")
        session = AVAssetDownloadURLSession(
            configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }

    /// `master` is an authed https master.m3u8 URL; `token` the bearer token.
    func start(master: URL, token: String) async {
        let asset = AVURLAsset(url: master, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
        let selections = asset.allMediaSelections
        print("SPIKE q4: allMediaSelections count = \(selections.count)")
        task = session.aggregateAssetDownloadTask(
            with: asset, mediaSelections: selections, assetTitle: "spike",
            assetArtworkData: nil, options: nil)
        task?.resume()

        // Cancel at roughly 20%, then restart and observe whether the first
        // progress report resumes near 20% (resume) or near 0% (restart).
        try? await Task.sleep(for: .seconds(20))
        print("SPIKE q1a: cancelling at fraction \(fractionAtCancel)")
        task?.cancel()
        try? await Task.sleep(for: .seconds(3))
        let restartAsset = AVURLAsset(url: master, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]
        ])
        task = session.aggregateAssetDownloadTask(
            with: restartAsset, mediaSelections: restartAsset.allMediaSelections,
            assetTitle: "spike", assetArtworkData: nil, options: nil)
        task?.resume()
    }

    /// q1b: restart from the *local* partial URL instead of the remote master —
    /// this is what the shipped HLSDownloadEngine actually does. Run this
    /// variant if q1a shows a restart-from-0, to confirm the local-URL path
    /// (already shipped) does or doesn't fare better.
    func restartFromLocal() {
        guard let localURL else { print("SPIKE q1b: no local URL captured"); return }
        let asset = AVURLAsset(url: localURL)
        task = session.aggregateAssetDownloadTask(
            with: asset, mediaSelections: asset.allMediaSelections,
            assetTitle: "spike", assetArtworkData: nil, options: nil)
        task?.resume()
    }

    /// q2: play the running task's asset and print whether playback starts.
    func playRunningTaskAsset() {
        guard let asset = task?.urlAsset else { print("SPIKE q2: no task"); return }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            print("SPIKE q2: status=\(item.status.rawValue) time=\(player.currentTime().seconds)")
        }
    }

    /// q3: after cancelling, play the partial from its local URL (run in Airplane Mode).
    func playPartialOffline() {
        guard let localURL else { print("SPIKE q3: no local URL"); return }
        let item = AVPlayerItem(asset: AVURLAsset(url: localURL))
        let player = AVPlayer(playerItem: item)
        player.play()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            print("SPIKE q3: status=\(item.status.rawValue) error=\(String(describing: item.error)) time=\(player.currentTime().seconds)")
            let groups = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            print("SPIKE q4 offline: legible options = \(groups?.options.count ?? -1)")
        }
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        localURL = location
        print("SPIKE willDownloadTo: \(location.path)")
    }

    func urlSession(
        _ session: URLSession, aggregateAssetDownloadTask: AVAggregateAssetDownloadTask,
        didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange, for mediaSelection: AVMediaSelection
    ) {
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let fraction = expected > 0 ? loaded / expected : 0
        fractionAtCancel = fraction
        print("SPIKE progress: \(fraction) bytesReceived=\(aggregateAssetDownloadTask.countOfBytesReceived)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("SPIKE didComplete error=\(String(describing: error))")
    }
}

enum SpikeProbeHolder {
    @MainActor static var shared: SpikeDownloadProbe?
}

