import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Lock-screen / Control Center integration for a single AVPlayer.
/// Attach when the player screen appears, detach on dismiss.
/// Elapsed time is pushed only on rate changes and seeks — iOS extrapolates
/// the lock-screen progress bar from elapsed + rate in between.
@MainActor
final class NowPlayingManager {
    private enum RemoteAction: Sendable {
        case play
        case pause
        case togglePlayPause
        case seek(TimeInterval)
    }

    private weak var player: AVPlayer?
    private var rateObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var seekObserver: NSObjectProtocol?
    private var targets: [(MPRemoteCommand, Any)] = []

    /// nonisolated so `@State private var nowPlaying = NowPlayingManager()` can
    /// initialize it — SwiftUI property default values run in a nonisolated context.
    nonisolated init() {}

    func attach(player: AVPlayer, title: String) {
        self.player = player
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            Task { @MainActor in self?.pushDynamicInfo() }
        }
        // Duration becomes known once the item is ready to play.
        statusObservation = player.observe(\.currentItem?.status) { [weak self] _, _ in
            Task { @MainActor in self?.pushDynamicInfo() }
        }
        seekObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushDynamicInfo() }
        }
        registerCommands()
    }

    /// Best-effort: called only when the thumbnail download succeeds.
    func setArtwork(_ image: UIImage, for expectedPlayer: AVPlayer) {
        guard player === expectedPlayer,
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func detach() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        rateObservation = nil
        statusObservation = nil
        if let seekObserver { NotificationCenter.default.removeObserver(seekObserver) }
        seekObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player = nil
    }

    private func pushDynamicInfo() {
        guard let player, let item = player.currentItem else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let duration = item.duration.seconds
        if duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand, action: .play)
        add(center.pauseCommand, action: .pause)
        add(center.togglePlayPauseCommand, action: .togglePlayPause)
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = event.positionTime
            Task { @MainActor [weak self] in
                self?.handle(.seek(positionTime))
            }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, target))
    }

    private func add(_ command: MPRemoteCommand, action: RemoteAction) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handle(action)
            }
            return .success
        }
        targets.append((command, target))
    }

    private func handle(_ action: RemoteAction) {
        guard let player else { return }
        switch action {
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .togglePlayPause:
            player.rate == 0 ? player.play() : player.pause()
        case .seek(let positionTime):
            player.seek(to: CMTime(seconds: positionTime, preferredTimescale: 600))
        }
    }
}
