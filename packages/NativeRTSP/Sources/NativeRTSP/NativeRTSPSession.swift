import Foundation
import LumaCamCore

enum NativeRTSPSessionState: Equatable {
    case idle
    case configured(endpoint: URL, transport: RTSPTransport)
    case starting
    case failed(PlaybackError)
    case stopped
}

@MainActor
final class NativeRTSPSession {
    private(set) var state: NativeRTSPSessionState = .idle
    private(set) var endpointURL: URL?
    private(set) var transport: RTSPTransport = .automatic
    private(set) var isVisible = false
    private(set) var surfaceDescription: String?
    private(set) var remoteSessionIdentifier: String?
    private(set) var selectedVideoTrack: NativeRTSPSelectedVideoTrack?
    private(set) var negotiatedTransport: RTSPTransportAlternative?
    private(set) var playURL: URL?

    func configure(endpointURL: URL, transport: RTSPTransport) {
        self.endpointURL = endpointURL
        self.transport = .tcp
        remoteSessionIdentifier = nil
        selectedVideoTrack = nil
        negotiatedTransport = nil
        playURL = nil
        state = .configured(endpoint: endpointURL, transport: self.transport)
    }

    func markStarting() {
        state = .starting
    }

    func markFailed(_ error: PlaybackError) {
        state = .failed(error)
    }

    func stop() {
        state = .stopped
    }

    func reset() {
        endpointURL = nil
        transport = .automatic
        isVisible = false
        surfaceDescription = nil
        remoteSessionIdentifier = nil
        selectedVideoTrack = nil
        negotiatedTransport = nil
        playURL = nil
        state = .idle
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    func attachSurfaceDescription(_ description: String) {
        surfaceDescription = description
    }

    func detachSurface() {
        surfaceDescription = nil
    }

    func controlPlaneContext() -> NativeRTSPControlPlaneContext? {
        guard let endpointURL else { return nil }
        // RTSP request lines and Digest `uri` must match what servers validate: almost all cameras
        // expect the URI *without* embedded userinfo (VLC/Live555-style). Credentials go only in Authorization.
        // EvoStream / UniFi digest validation typically matches Live555: omit default rtsp port 554 in the URI string.
        let strippedURL = endpointURL.removingRTSPUserInfoForRequests().canonicalRTSPURLForDigestInterop()
        return NativeRTSPControlPlaneContext(
            endpointURL: strippedURL,
            username: endpointURL.user,
            password: endpointURL.password,
            requestedTransport: transport,
            resolvedTransport: .tcp,
            userAgent: "LumaCam/1.0"
        )
    }

    func recordRemoteSessionIdentifier(_ identifier: String?) {
        remoteSessionIdentifier = identifier
    }

    func recordSelectedVideoTrack(_ track: NativeRTSPSelectedVideoTrack?) {
        selectedVideoTrack = track
    }

    func recordNegotiatedTransport(_ transport: RTSPTransportAlternative?) {
        negotiatedTransport = transport
    }

    func recordPlayURL(_ url: URL?) {
        playURL = url
    }
}

private extension URL {
    /// Removes `user:password@` so DESCRIBE/SETUP/PLAY lines and Digest HA2 use the same URI most RTSP servers expect.
    func removingRTSPUserInfoForRequests() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        guard components.user != nil || components.password != nil else {
            return self
        }
        components.user = nil
        components.password = nil
        return components.url ?? self
    }

    /// Drops explicit `:554` so request lines and Digest `uri` match stacks that omit the default RTSP port (common for EvoStream/UniFi).
    func canonicalRTSPURLForDigestInterop() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        guard components.scheme?.lowercased() == "rtsp", components.port == 554 else {
            return self
        }
        components.port = nil
        return components.url ?? self
    }
}
