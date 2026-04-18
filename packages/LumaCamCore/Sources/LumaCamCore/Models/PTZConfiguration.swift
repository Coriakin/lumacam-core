import Foundation

/// How pan/tilt/zoom is driven for a saved camera (separate from RTSP playback).
public enum PTZBackendKind: String, Codable, Sendable, Equatable, CaseIterable {
    case disabled
    case httpCGI
    case onvif
}

/// HTTP GET paths (or path+query) relative to the camera’s web base URL.
public struct PTZHTTPConfiguration: Codable, Equatable, Sendable {
    /// When nil or empty after trimming, the RTSP endpoint host is used.
    public var hostOverride: String?
    /// When nil, port defaults to 443 when `useTLS` else 80.
    public var port: Int?
    public var useTLS: Bool
    public var panLeftPath: String
    public var panRightPath: String
    public var tiltUpPath: String
    public var tiltDownPath: String
    public var zoomInPath: String
    public var zoomOutPath: String
    /// Required for continuous-move APIs so the client can stop on gesture release.
    public var stopPath: String

    public init(
        hostOverride: String? = nil,
        port: Int? = nil,
        useTLS: Bool = false,
        panLeftPath: String = "",
        panRightPath: String = "",
        tiltUpPath: String = "",
        tiltDownPath: String = "",
        zoomInPath: String = "",
        zoomOutPath: String = "",
        stopPath: String = ""
    ) {
        self.hostOverride = hostOverride
        self.port = port
        self.useTLS = useTLS
        self.panLeftPath = panLeftPath
        self.panRightPath = panRightPath
        self.tiltUpPath = tiltUpPath
        self.tiltDownPath = tiltDownPath
        self.zoomInPath = zoomInPath
        self.zoomOutPath = zoomOutPath
        self.stopPath = stopPath
    }

    public func resolvedPort() -> Int {
        if let port {
            return port
        }
        return useTLS ? 443 : 80
    }

    public var hasAnyMovePath: Bool {
        let paths = [
            panLeftPath, panRightPath, tiltUpPath, tiltDownPath,
            zoomInPath, zoomOutPath,
        ]
        return paths.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Paths and stop are non-empty where required for continuous move + stop.
    public var isUsableForContinuousMove: Bool {
        !stopPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasAnyMovePath
    }
}

/// ONVIF device service + transport. URLs for media/PTZ are discovered via GetCapabilities.
public struct PTZONVIFConfiguration: Codable, Equatable, Sendable {
    /// When nil or empty after trimming, the RTSP endpoint host is used.
    public var hostOverride: String?
    /// When nil, defaults to **2020** (Tapo and many ONVIF cameras).
    public var port: Int?
    public var useTLS: Bool
    /// Path on the ONVIF port (Tapo default).
    public var deviceServicePath: String

    public init(
        hostOverride: String? = nil,
        port: Int? = nil,
        useTLS: Bool = false,
        deviceServicePath: String = "/onvif/device_service"
    ) {
        self.hostOverride = hostOverride
        self.port = port
        self.useTLS = useTLS
        let trimmed = deviceServicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceServicePath = trimmed.isEmpty ? "/onvif/device_service" : trimmed
    }

    public func resolvedPort() -> Int {
        port ?? 2020
    }
}

public struct PTZConfiguration: Codable, Equatable, Sendable {
    public var backend: PTZBackendKind
    public var http: PTZHTTPConfiguration
    public var onvif: PTZONVIFConfiguration

    enum CodingKeys: String, CodingKey {
        case backend
        case http
        case onvif
    }

    public init(
        backend: PTZBackendKind = .disabled,
        http: PTZHTTPConfiguration = PTZHTTPConfiguration(),
        onvif: PTZONVIFConfiguration = PTZONVIFConfiguration()
    ) {
        self.backend = backend
        self.http = http
        self.onvif = onvif
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(PTZBackendKind.self, forKey: .backend)
        http = try c.decodeIfPresent(PTZHTTPConfiguration.self, forKey: .http) ?? PTZHTTPConfiguration()
        onvif = try c.decodeIfPresent(PTZONVIFConfiguration.self, forKey: .onvif) ?? PTZONVIFConfiguration()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend)
        try c.encode(http, forKey: .http)
        try c.encode(onvif, forKey: .onvif)
    }

    public static let disabled = PTZConfiguration()
}
