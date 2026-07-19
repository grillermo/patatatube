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
        case next
        case previous
    }

    private weak var player: AVPlayer?
    /// Set by the owning view before `attach`; drive queue navigation.
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
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
            object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let item, item === self.player?.currentItem else { return }
                self.pushDynamicInfo()
            }
        }
        registerCommands()
    }

    /// Best-effort: called only when the thumbnail download succeeds.
    func setArtwork(_ data: Data, for expectedPlayer: AVPlayer) {
        guard player === expectedPlayer,
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              let artwork = Self.makeArtwork(from: data) else { return }
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Push the new track's title on a queue change and drop the previous
    /// track's artwork so the lock screen never shows a stale thumbnail.
    func updateTitle(_ title: String) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtwork] = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        pushDynamicInfo()
    }

    func setNextEnabled(_ enabled: Bool) {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = enabled
    }

    /// MediaPlayer calls its artwork provider on a private queue. Build the
    /// closure outside MainActor isolation and capture only immutable image data.
    nonisolated private static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let validatedImage = UIImage(data: data) else { return nil }
        let boundsSize = validatedImage.size
        let requestHandler: @Sendable (CGSize) -> UIImage = { _ in
            UIImage(data: data) ?? UIImage()
        }
        return MPMediaItemArtwork(boundsSize: boundsSize, requestHandler: requestHandler)
    }

    func detach() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        rateObservation = nil
        statusObservation = nil
        if let seekObserver { NotificationCenter.default.removeObserver(seekObserver) }
        seekObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onNext = nil
        onPrevious = nil
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
        add(center.nextTrackCommand, action: .next)
        add(center.previousTrackCommand, action: .previous)
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
        switch action {
        case .next:
            onNext?()
            return
        case .previous:
            onPrevious?()
            return
        default:
            break
        }
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
        case .next, .previous:
            break
        }
    }
}
