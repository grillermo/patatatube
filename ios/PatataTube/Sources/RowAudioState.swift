// ios/PatataTube/Sources/RowAudioState.swift
import Foundation

/// One list row's audio status, as the row needs to draw it.
///
/// Deliberately a row-shaped type, not a playback-shaped one: `VideoRow` takes
/// plain values and closures and never sees `AppModel` or `AudioQueuePlayer`.
enum RowAudioState: Equatable {
    /// Not the current audio item — the thumbnail draws bare.
    case idle
    /// Tapped, but the source isn't resolved yet (`/prepare`, conversion).
    case loading
    case playing
    case paused

    /// The glyph the overlay shows: the action the next tap performs, so a
    /// playing row offers pause. `nil` where there is no glyph — `.idle` draws
    /// nothing at all, `.loading` draws a spinner instead.
    var overlaySystemImage: String? {
        switch self {
        case .idle, .loading: return nil
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }
}
