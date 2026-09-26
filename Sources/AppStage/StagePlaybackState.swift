/// The current state of scenario playback.
public enum StagePlaybackState: Equatable, Sendable {
    case stopped
    case playing
    case paused
}
