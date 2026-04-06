import Foundation

public enum PlaybackError: Error, Equatable, Sendable {
    case invalidEndpoint
    case missingDependency(String)
    case authenticationFailed
    case networkUnavailable
    case transportFailure(String)
    case unknown(String)

    public var message: String {
        switch self {
        case .invalidEndpoint:
            "The RTSP endpoint is invalid."
        case let .missingDependency(name):
            "\(name) is not installed in the app target."
        case .authenticationFailed:
            "The camera rejected the supplied credentials."
        case .networkUnavailable:
            "The camera is unreachable on the current network."
        case let .transportFailure(message):
            message
        case let .unknown(message):
            message
        }
    }
}
