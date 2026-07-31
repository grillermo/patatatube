// ios/PatataTube/Sources/PlaybackProbe.swift
import AVFoundation
import Foundation
import PatataTubeKit

/// Watches one `AVPlayerItem` and its `AVPlayer` and records the playback state
/// machine into `DevLog`.
///
/// Exists for the intermittent playback failures: by the time a video is stuck
/// the interesting part — which status transition happened, what AVFoundation
/// put in the item's error log, whether the buffer emptied first — has already
/// scrolled past. This captures it as it happens.
///
/// Everything here is inert without the `DEVLOG` condition: `attach` returns
/// immediately, so no observers are registered in a normal build.
final class PlaybackProbe {
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var meta: [String: String] = [:]
    /// `loadedTimeRanges` fires many times a second. Logging every tick would
    /// bury the events that matter and add real work to the playback path.
    private var lastBufferLogged = Date.distantPast
    private static let bufferLogInterval: TimeInterval = 1.0

    deinit { detach() }

    func attach(item: AVPlayerItem, player: AVPlayer, video: Video, source: String) {
        guard DevLog.enabled else { return }
        detach()

        meta = [
            "video_id": "\(video.id)",
            "version_id": video.chosenVersionId.map(String.init) ?? "-",
            "source": source,
        ]

        observeStatus(item)
        observeBuffering(item)
        observeTimeControl(player)
        observeNotifications(item)
    }

    func detach() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
    }

    // MARK: - Observers

    private func observeStatus(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                DevLog.event(.play, "item status -> readyToPlay", self.meta)
            case .failed:
                // The single most valuable record in the whole log.
                var failure = self.meta
                if let error = item.error as NSError? {
                    failure["err_domain"] = error.domain
                    failure["err_code"] = "\(error.code)"
                    failure["err"] = error.localizedDescription
                    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                        failure["underlying"] = "\(underlying.domain)/\(underlying.code)"
                    }
                }
                failure.merge(Self.errorLogFields(item)) { current, _ in current }
                failure.merge(Self.accessLogFields(item)) { current, _ in current }
                DevLog.event(.play, "item status -> failed", failure)
            case .unknown:
                DevLog.event(.play, "item status -> unknown", self.meta)
            @unknown default:
                DevLog.event(.play, "item status -> unrecognised(\(item.status.rawValue))", self.meta)
            }
        })
    }

    private func observeBuffering(_ item: AVPlayerItem) {
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self, item.isPlaybackBufferEmpty else { return }
            DevLog.event(.play, "buffer empty", self.meta)
        })
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DevLog.event(.play, "likelyToKeepUp -> \(item.isPlaybackLikelyToKeepUp)", self.meta)
        })
        observations.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastBufferLogged) >= Self.bufferLogInterval else { return }
            self.lastBufferLogged = now

            let current = item.currentTime().seconds
            let bufferedAhead = item.loadedTimeRanges
                .map { $0.timeRangeValue }
                .filter { CMTimeGetSeconds($0.end) > current }
                .map { CMTimeGetSeconds($0.end) - max(current, CMTimeGetSeconds($0.start)) }
                .reduce(0, +)

            var buffer = self.meta
            buffer["t"] = String(format: "%.1f", current.isFinite ? current : -1)
            buffer["ahead"] = String(format: "%.1f", bufferedAhead)
            DevLog.event(.play, "buffer", buffer)
        })
    }

    private func observeTimeControl(_ player: AVPlayer) {
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let name: String
            switch player.timeControlStatus {
            case .paused: name = "paused"
            case .waitingToPlayAtSpecifiedRate: name = "waiting"
            case .playing: name = "playing"
            @unknown default: name = "unknown"
            }
            var status = self.meta
            if let reason = player.reasonForWaitingToPlay {
                status["waiting_reason"] = reason.rawValue
            }
            DevLog.event(.play, "timeControlStatus -> \(name)", status)
        })
    }

    private func observeNotifications(_ item: AVPlayerItem) {
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            DevLog.event(.play, "playback stalled", self.meta)
        })

        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            var failure = self.meta
            if let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError {
                failure["err_domain"] = error.domain
                failure["err_code"] = "\(error.code)"
                failure["err"] = error.localizedDescription
            }
            DevLog.event(.play, "failed to play to end", failure)
        })

        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: nil
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem else { return }
            var entry = self.meta
            entry.merge(Self.errorLogFields(item)) { current, _ in current }
            DevLog.event(.play, "new error log entry", entry)
        })
    }

    // MARK: - AVFoundation log extraction

    /// AVFoundation's own account of what went wrong on the wire — status codes
    /// and the URI it was fetching, which is what distinguishes a proxy fault
    /// from a backend fault from a partially-cached file.
    private static func errorLogFields(_ item: AVPlayerItem) -> [String: String] {
        guard let event = item.errorLog()?.events.last else { return [:] }
        var fields: [String: String] = [
            "avf_err_status": "\(event.errorStatusCode)",
            "avf_err_domain": event.errorDomain,
        ]
        if let comment = event.errorComment { fields["avf_err_comment"] = comment }
        if let uri = event.uri { fields["avf_uri"] = uri }
        if let address = event.serverAddress { fields["avf_server"] = address }
        return fields
    }

    private static func accessLogFields(_ item: AVPlayerItem) -> [String: String] {
        guard let event = item.accessLog()?.events.last else { return [:] }
        return [
            "avf_stalls": "\(event.numberOfStalls)",
            "avf_observed_bitrate": String(format: "%.0f", event.observedBitrate),
            "avf_indicated_bitrate": String(format: "%.0f", event.indicatedBitrate),
            "avf_bytes": "\(event.numberOfBytesTransferred)",
            "avf_server_changes": "\(event.numberOfServerAddressChanges)",
        ]
    }
}
