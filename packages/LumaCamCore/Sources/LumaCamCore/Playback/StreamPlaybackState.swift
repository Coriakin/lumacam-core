import Foundation

public enum StreamPlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case connecting
    case playing
    case reconnecting(attempt: Int, delay: Duration)
    case stopped
    case failed(PlaybackError)

    public var isTerminalFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    public var isActivePlayback: Bool {
        switch self {
        case .preparing, .connecting, .playing, .reconnecting:
            true
        case .idle, .stopped, .failed:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .preparing:
            "Preparing"
        case .connecting:
            "Connecting"
        case .playing:
            "Playing"
        case let .reconnecting(attempt, _):
            "Reconnecting (\(attempt))"
        case .stopped:
            "Stopped"
        case .failed:
            "Failed"
        }
    }
}
