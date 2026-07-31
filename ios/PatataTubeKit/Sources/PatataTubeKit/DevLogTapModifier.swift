import SwiftUI

public extension View {
    /// Records a `tap` event when this view is touched, without changing its
    /// behaviour: `simultaneousGesture` runs alongside whatever `Button`,
    /// `onTapGesture`, or `NavigationLink` is already there rather than
    /// competing with it.
    ///
    /// Compiles away to `self` when `DEVLOG` is off, so no gesture recogniser is
    /// attached in a normal build.
    ///
    ///     Button("Play") { … }
    ///         .logTap("play", ["video_id": "\(video.id)"])
    @inlinable
    @ViewBuilder
    func logTap(
        _ name: String,
        _ meta: @autoclosure () -> [String: String] = [:],
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) -> some View {
        if DevLog.enabled {
            let capturedMeta = meta()
            simultaneousGesture(
                TapGesture().onEnded {
                    DevLog.event(.tap, name, capturedMeta,
                                 file: file, line: line, function: function)
                }
            )
        } else {
            self
        }
    }
}
