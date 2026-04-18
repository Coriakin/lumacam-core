import Foundation
import Observation
import OSLog

public enum DiagnosticsLevel: String, Codable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public struct DiagnosticsEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: DiagnosticsLevel
    public let category: String
    public let cameraID: UUID?
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: DiagnosticsLevel,
        category: String,
        cameraID: UUID? = nil,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.cameraID = cameraID
        self.message = message
    }

    public var formattedLine: String {
        let time = timestamp.formatted(date: .omitted, time: .standard)
        return "\(time) [\(level.rawValue)] [\(category)] \(message)"
    }
}

@MainActor
@Observable
public final class DiagnosticsStore {
    public static let shared = DiagnosticsStore()

    public private(set) var entries: [DiagnosticsEntry] = []
    public var maximumEntryCount = 400

    public init() {}

    public func append(_ entry: DiagnosticsEntry) {
        entries.append(entry)
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
    }

    public func recentEntries(cameraID: UUID? = nil, limit: Int = 80) -> [DiagnosticsEntry] {
        let filtered = entries.filter { entry in
            guard let cameraID else { return true }
            return entry.cameraID == cameraID
        }

        return Array(filtered.suffix(limit))
    }

    public func formattedText(cameraID: UUID? = nil, limit: Int = 80) -> String {
        recentEntries(cameraID: cameraID, limit: limit)
            .map(\.formattedLine)
            .joined(separator: "\n")
    }

    public func clear(cameraID: UUID? = nil) {
        guard let cameraID else {
            entries.removeAll()
            return
        }

        entries.removeAll { $0.cameraID == cameraID }
    }
}

public enum LumaCamDiagnostics {
    private static let subsystem = "se.andreasbjorn.LumaCam"

    public static func log(
        _ message: @autoclosure () -> String,
        level: DiagnosticsLevel = .info,
        category: String,
        cameraID: UUID? = nil
    ) {
        emit(
            DiagnosticsEntry(
                level: level,
                category: category,
                cameraID: cameraID,
                message: message()
            )
        )
    }

    public static func log(
        error: Error,
        category: String,
        cameraID: UUID? = nil,
        prefix: String? = nil
    ) {
        let message = if let prefix {
            "\(prefix): \(error.localizedDescription)"
        } else {
            error.localizedDescription
        }

        emit(
            DiagnosticsEntry(
                level: .error,
                category: category,
                cameraID: cameraID,
                message: message
            )
        )
    }

    private static func emit(_ entry: DiagnosticsEntry) {
        let logger = Logger(subsystem: subsystem, category: entry.category)
        let line = entry.formattedLine

        switch entry.level {
        case .debug:
            logger.debug("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        }

        Task { @MainActor in
            DiagnosticsStore.shared.append(entry)
        }
    }
}

public extension CameraEndpoint {
    var redactedRTSPURLString: String {
        guard let url = resolvedRTSPURL(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            let portDescription = port.map(String.init) ?? "554"
            let normalizedPath = CameraEndpoint.normalizePath(path)
            if let username {
                return "rtsp://\(username)@\(host):\(portDescription)\(normalizedPath)"
            }
            return "rtsp://\(host):\(portDescription)\(normalizedPath)"
        }
        if components.password != nil {
            components.password = nil
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    var diagnosticsSummary: String {
        let authDescription = username == nil ? "anonymous" : "username=\(username ?? "")"
        let passwordDescription = resolvedPassword == nil ? "password=missing" : "password=present"
        return "\(redactedRTSPURLString) transport=\(preferredTransport.displayName) \(authDescription) \(passwordDescription)"
    }
}

public extension CameraProfile {
    var diagnosticsSummary: String {
        "camera=\(displayName) id=\(id.uuidString.lowercased()) endpoint=\(endpoint.diagnosticsSummary) ptz=\(ptz.backend.rawValue)"
    }
}

public extension StreamPlaybackState {
    var diagnosticsSummary: String {
        switch self {
        case .idle:
            "idle"
        case .preparing:
            "preparing"
        case .connecting:
            "connecting"
        case .playing:
            "playing"
        case let .reconnecting(attempt, delay):
            "reconnecting attempt=\(attempt) delay=\(Int(delay.components.seconds))s"
        case .stopped:
            "stopped"
        case let .failed(error):
            "failed error=\(error.diagnosticsSummary)"
        }
    }
}

public extension PlaybackStatistics {
    var diagnosticsSummary: String {
        let codec = codecDescription ?? "unknown"
        let resolution = resolutionDescription ?? "unknown"
        let latency = latencyEstimateMilliseconds.map { "\($0)ms" } ?? "n/a"
        let dropped = droppedFrameCount.map(String.init) ?? "n/a"
        return "codec=\(codec) resolution=\(resolution) latency=\(latency) dropped=\(dropped)"
    }
}

public extension PlaybackError {
    var diagnosticsSummary: String {
        switch self {
        case .invalidEndpoint:
            "invalid-endpoint"
        case let .missingDependency(name):
            "missing-dependency \(name)"
        case .authenticationFailed:
            "authentication-failed"
        case .networkUnavailable:
            "network-unavailable"
        case let .transportFailure(message):
            "transport-failure \(message)"
        case let .unknown(message):
            "unknown \(message)"
        }
    }
}
