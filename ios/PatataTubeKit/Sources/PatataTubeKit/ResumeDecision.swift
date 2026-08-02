import Foundation

/// Whether a play tap should offer "resume" or just start.
///
/// Only long-form rows (`tv`, `movies`) ever prompt, and only past a floor —
/// a 20-second accidental open must not put a modal in front of the next tap.
/// There is deliberately no upper bound here: reaching the end of a video
/// resets the stored position to 0 (see `PlaybackPositionReporter`), so a
/// finished video already reads as `.playFromStart`.
public enum ResumeDecision: Equatable, Sendable {
    case playFromStart
    case ask(secs: Double)

    public static let defaultMinimumSecs: Double = 60

    /// Classifications that get the prompt. Mirrors the server's tv/movies rows.
    public static let promptingClassifications: Set<String> = ["tv", "movies"]

    public static func decide(
        resumeSecs: Double,
        classification: String?,
        minimumSecs: Double = ResumeDecision.defaultMinimumSecs
    ) -> ResumeDecision {
        guard let classification, promptingClassifications.contains(classification) else {
            return .playFromStart
        }
        guard resumeSecs >= minimumSecs else { return .playFromStart }
        return .ask(secs: resumeSecs)
    }

    /// "24:13" under an hour, "1:24:13" over it. Seconds floor, never round up
    /// past the position actually stored.
    public static func timestamp(_ secs: Double) -> String {
        let total = Int(max(0, secs))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
