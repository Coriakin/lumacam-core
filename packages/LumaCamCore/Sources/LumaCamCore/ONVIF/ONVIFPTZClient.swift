import Foundation
import os

/// Minimal ONVIF PTZ client (SOAP + WS-UsernameToken). Resolves media/PTZ URLs and profile token via GetCapabilities + GetProfiles, then uses ContinuousMove / Stop.
public final class ONVIFPTZClient: @unchecked Sendable {
    public struct Binding: Sendable, Equatable {
        public var mediaServiceURL: URL
        public var ptzServiceURL: URL
        public var profileToken: String
    }

    private let urlSession: URLSession
    private let cache = OSAllocatedUnfairLock<[UUID: Binding]>(initialState: [:])

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func invalidateCache(cameraID: UUID) {
        _ = cache.withLock { $0.removeValue(forKey: cameraID) }
    }

    public func continuousMove(profile: CameraProfile, pan: Float, tilt: Float, zoom: Float) async throws {
        let (user, pass) = try credentials(from: profile)
        let binding = try await binding(for: profile, username: user, password: pass)
        let body = Self.continuousMoveBody(profileToken: binding.profileToken, pan: pan, tilt: tilt, zoom: zoom)
        let data = try await soapPOST(
            url: binding.ptzServiceURL,
            soapAction: "http://www.onvif.org/ver20/ptz/wsdl/ContinuousMove",
            envelopeBody: body,
            username: user,
            password: pass
        )
        try Self.throwIfSOAPFault(String(data: data, encoding: .utf8) ?? "")
    }

    public func stop(profile: CameraProfile) async throws {
        let (user, pass) = try credentials(from: profile)
        let binding = try await binding(for: profile, username: user, password: pass)
        let body = Self.stopBody(profileToken: binding.profileToken)
        let data = try await soapPOST(
            url: binding.ptzServiceURL,
            soapAction: "http://www.onvif.org/ver20/ptz/wsdl/Stop",
            envelopeBody: body,
            username: user,
            password: pass
        )
        try Self.throwIfSOAPFault(String(data: data, encoding: .utf8) ?? "")
    }

    /// Reads stored PTZ presets from the camera (same slots vendor apps use when they support ONVIF presets).
    public func fetchPresets(profile: CameraProfile) async throws -> [ONVIFPTZPreset] {
        let (user, pass) = try credentials(from: profile)
        let binding = try await binding(for: profile, username: user, password: pass)
        let body = Self.getPresetsBody(profileToken: binding.profileToken)
        let data = try await soapPOST(
            url: binding.ptzServiceURL,
            soapAction: "http://www.onvif.org/ver20/ptz/wsdl/GetPresets",
            envelopeBody: body,
            username: user,
            password: pass
        )
        let xml = String(data: data, encoding: .utf8) ?? ""
        try Self.throwIfSOAPFault(xml)
        return ONVIFPTZPresetParsing.presets(from: xml)
    }

    public func gotoPreset(profile: CameraProfile, presetToken: String) async throws {
        let trimmed = presetToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ONVIFPTZError.parseError("Empty preset token.")
        }
        let (user, pass) = try credentials(from: profile)
        let binding = try await binding(for: profile, username: user, password: pass)
        let body = Self.gotoPresetBody(profileToken: binding.profileToken, presetToken: trimmed)
        let data = try await soapPOST(
            url: binding.ptzServiceURL,
            soapAction: "http://www.onvif.org/ver20/ptz/wsdl/GotoPreset",
            envelopeBody: body,
            username: user,
            password: pass
        )
        try Self.throwIfSOAPFault(String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Binding

    private func binding(for profile: CameraProfile, username: String, password: String) async throws -> Binding {
        if let existing = cache.withLock({ $0[profile.id] }) {
            return existing
        }

        let deviceURL = try Self.deviceServiceURL(for: profile)
        let capsXML = try await soapPOST(
            url: deviceURL,
            soapAction: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
            envelopeBody: Self.getCapabilitiesBody,
            username: username,
            password: password
        )
        let capsString = String(data: capsXML, encoding: .utf8) ?? ""
        try Self.throwIfSOAPFault(capsString)

        guard let mediaRaw = Self.extractXAddr(in: capsString, section: "Media") else {
            throw ONVIFPTZError.noMediaEndpoint
        }
        guard let ptzRaw = Self.extractXAddr(in: capsString, section: "PTZ") else {
            throw ONVIFPTZError.noPTZEndpoint
        }
        guard let mediaURL = URL(string: mediaRaw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let ptzURL = URL(string: ptzRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ONVIFPTZError.parseError("Invalid media or PTZ XAddr URL.")
        }

        let profilesData = try await soapPOST(
            url: mediaURL,
            soapAction: "http://www.onvif.org/ver10/media/wsdl/GetProfiles",
            envelopeBody: Self.getProfilesBody,
            username: username,
            password: password
        )
        let profilesString = String(data: profilesData, encoding: .utf8) ?? ""
        try Self.throwIfSOAPFault(profilesString)

        let token = try Self.pickProfileToken(from: profilesString)
        let binding = Binding(mediaServiceURL: mediaURL, ptzServiceURL: ptzURL, profileToken: token)

        cache.withLock { $0[profile.id] = binding }
        return binding
    }

    private func credentials(from profile: CameraProfile) throws -> (String, String) {
        guard let user = profile.endpoint.username?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else {
            throw ONVIFPTZError.missingCredentials
        }
        let pass = profile.endpoint.resolvedPassword ?? ""
        return (user, pass)
    }

    public static func deviceServiceURL(for profile: CameraProfile) throws -> URL {
        let onvif = profile.ptz.onvif
        let override = onvif.hostOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = override.isEmpty ? profile.endpoint.host : override
        let scheme = onvif.useTLS ? "https" : "http"
        let port = onvif.resolvedPort()
        var path = onvif.deviceServicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = "/onvif/device_service"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }

        var comp = URLComponents()
        comp.scheme = scheme
        comp.host = host
        let defaultPort = onvif.useTLS ? 443 : 80
        if port != defaultPort {
            comp.port = port
        }
        comp.path = path
        guard let url = comp.url else {
            throw ONVIFPTZError.invalidDeviceURL
        }
        return url
    }

    // MARK: - SOAP

    private func soapPOST(
        url: URL,
        soapAction: String,
        envelopeBody: String,
        username: String,
        password: String
    ) async throws -> Data {
        let security = ONVIFWSSecurity.securityHeader(username: username, password: password)
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
        <s:Header>
        \(security)
        </s:Header>
        <s:Body>
        \(envelopeBody)
        </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = envelope.data(using: .utf8)
        let actionHeader = "\"\(soapAction)\""
        request.setValue("application/soap+xml; charset=utf-8; action=\(actionHeader)", forHTTPHeaderField: "Content-Type")
        request.setValue(soapAction, forHTTPHeaderField: "SOAPAction")

        let (data, response) = try await urlSession.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        guard (200...299).contains(code) else {
            throw ONVIFPTZError.badHTTPStatus(code)
        }
        return data
    }

    private static let getCapabilitiesBody = """
    <tds:GetCapabilities xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
      <tds:Category>All</tds:Category>
    </tds:GetCapabilities>
    """

    private static let getProfilesBody = """
    <trt:GetProfiles xmlns:trt="http://www.onvif.org/ver10/media/wsdl"/>
    """

    private static func continuousMoveBody(profileToken: String, pan: Float, tilt: Float, zoom: Float) -> String {
        let px = String(format: "%.4f", pan)
        let py = String(format: "%.4f", tilt)
        let pz = String(format: "%.4f", zoom)
        return """
        <tptz:ContinuousMove xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
          <tptz:ProfileToken>\(escapeXML(profileToken))</tptz:ProfileToken>
          <tptz:Velocity>
            <tt:PanTilt x="\(px)" y="\(py)" xmlns:tt="http://www.onvif.org/ver10/schema" space="http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace"/>
            <tt:Zoom x="\(pz)" xmlns:tt="http://www.onvif.org/ver10/schema" space="http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace"/>
          </tptz:Velocity>
        </tptz:ContinuousMove>
        """
    }

    private static func stopBody(profileToken: String) -> String {
        """
        <tptz:Stop xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
          <tptz:ProfileToken>\(escapeXML(profileToken))</tptz:ProfileToken>
          <tptz:PanTilt>true</tptz:PanTilt>
          <tptz:Zoom>true</tptz:Zoom>
        </tptz:Stop>
        """
    }

    private static func getPresetsBody(profileToken: String) -> String {
        """
        <tptz:GetPresets xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
          <tptz:ProfileToken>\(escapeXML(profileToken))</tptz:ProfileToken>
        </tptz:GetPresets>
        """
    }

    private static func gotoPresetBody(profileToken: String, presetToken: String) -> String {
        """
        <tptz:GotoPreset xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl">
          <tptz:ProfileToken>\(escapeXML(profileToken))</tptz:ProfileToken>
          <tptz:PresetToken>\(escapeXML(presetToken))</tptz:PresetToken>
        </tptz:GotoPreset>
        """
    }

    private static func escapeXML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Parse

    /// First `*:XAddr` inside the first `*:(Media|PTZ)` element.
    private static func extractXAddr(in xml: String, section: String) -> String? {
        let pattern = "(?s)<([^:>]+:)?\(section)[^>]*>.*?<([^:>]+:)?XAddr>([^<]+)</([^:>]+:)?XAddr>"
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = xml as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex?.firstMatch(in: xml, options: [], range: full), match.numberOfRanges >= 4 else {
            return nil
        }
        let r = match.range(at: 3)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pickProfileToken(from xml: String) throws -> String {
        let ns = xml as NSString
        let full = NSRange(location: 0, length: ns.length)
        let pattern = #"<([^:>]+:)?Profiles[^>]*\btoken="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw ONVIFPTZError.parseError("Profiles regex")
        }
        var candidates: [String] = []
        regex.enumerateMatches(in: xml, options: [], range: full) { result, _, _ in
            guard let result, result.numberOfRanges >= 3 else { return }
            let r = result.range(at: 2)
            guard r.location != NSNotFound else { return }
            candidates.append(ns.substring(with: r))
        }
        guard !candidates.isEmpty else {
            throw ONVIFPTZError.noProfileToken
        }
        for token in candidates {
            if profileBlock(forToken: token, in: xml)?.localizedCaseInsensitiveContains("PTZConfiguration") == true {
                return token
            }
        }
        return candidates[0]
    }

    private static func profileBlock(forToken token: String, in xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?s)<(?:[^:>]+:)?Profiles[^>]*\\btoken=\"\(escaped)\"[^>]*>(.*?)</(?:[^:>]+:)?Profiles>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = xml as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: xml, options: [], range: full), m.numberOfRanges >= 3 else { return nil }
        let r = m.range(at: 2)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    private static func throwIfSOAPFault(_ xml: String) throws {
        if let reason = extractFaultReason(xml) {
            throw ONVIFPTZError.soapFault(reason)
        }
    }

    private static func extractFaultReason(_ xml: String) -> String? {
        let patterns = [
            #"<(?:\w+:)?Reason[^>]*>([^<]+)</"#,
            #"<(?:\w+:)?Text[^>]*>([^<]+)</"#,
        ]
        let lower = xml.lowercased()
        guard lower.contains(":fault") else { return nil }
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = xml as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = regex.firstMatch(in: xml, options: [], range: full), m.numberOfRanges >= 2 {
                let r = m.range(at: 1)
                if r.location != NSNotFound {
                    return ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return "Unknown SOAP fault"
    }
}
