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
    func setArtwork(_ image: UIImage) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
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
        add(center.playCommand) { player, _ in
            player.play()
            return .success
        }
        add(center.pauseCommand) { player, _ in
            player.pause()
            return .success
        }
        add(center.togglePlayPauseCommand) { player, _ in
            player.rate == 0 ? player.play() : player.pause()
            return .success
        }
        add(center.changePlaybackPositionCommand) { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }
    }

    /// Remote-command handlers arrive on the main thread but the closure type is
    /// nonisolated under Swift 6; assumeIsolated bridges without a hop.
    private func add(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor (AVPlayer, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let player = self?.player else { return .commandFailed }
                return handler(player, event)
            }
        }
        targets.append((command, target))
    }
}
