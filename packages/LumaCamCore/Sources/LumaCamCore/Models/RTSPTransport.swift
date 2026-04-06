import Foundation

public enum RTSPTransport: String, Codable, CaseIterable, Sendable {
    case automatic
    case tcp
    case udp

    /// Cases shown in the v1 app UI. UDP is reserved; the native engine uses RTSP interleaved over TCP only.
    public static let v1SelectableCases: [RTSPTransport] = [.automatic, .tcp]

    /// Maps persisted values from older builds to a supported v1 transport.
    public var normalizedForV1: RTSPTransport {
        switch self {
        case .udp: .tcp
        case .automatic, .tcp: self
        }
    }

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .tcp:
            "TCP"
        case .udp:
            "UDP"
        }
    }
}
