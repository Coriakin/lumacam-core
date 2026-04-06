import CryptoKit
import Foundation

/// Shared HTTP Basic/Digest challenge parsing and `Authorization` header construction (RTSP and HTTP snapshot loads).
public enum RTSPAuthenticator {
    public enum Scheme: Equatable, Sendable {
        case basic
        case digest

        public init?(headerToken: String) {
            switch headerToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "basic":
                self = .basic
            case "digest":
                self = .digest
            default:
                return nil
            }
        }

        var headerValue: String {
            switch self {
            case .basic:
                "Basic"
            case .digest:
                "Digest"
            }
        }
    }

    public struct Challenge: Equatable, Sendable {
        public let scheme: Scheme
        public let parameters: [String: String]

        public init(scheme: Scheme, parameters: [String: String]) {
            self.scheme = scheme
            self.parameters = parameters
        }

        public var realm: String? { parameters["realm"] }
        public var nonce: String? { parameters["nonce"] }
        public var opaque: String? { parameters["opaque"] }
        public var algorithm: String? { parameters["algorithm"] }
        public var qop: String? { parameters["qop"] }
    }

    public static func parseChallenges(from headerValue: String) -> [Challenge] {
        parseChallenges(from: [headerValue])
    }

    public static func parseChallenges(from headerValues: [String]) -> [Challenge] {
        headerValues.flatMap(parseChallenges(inHeaderValue:))
    }

    public static func preferredChallenge(from headerValues: [String]) -> Challenge? {
        let challenges = parseChallenges(from: headerValues)
        return challenges.first(where: { $0.scheme == .digest }) ?? challenges.first(where: { $0.scheme == .basic })
    }

    public static func authorizationHeaderValue(
        username: String,
        password: String,
        method: String,
        uri: String,
        challenge: Challenge,
        nonceCount: UInt32 = 1,
        cnonce: String? = nil
    ) -> String? {
        switch challenge.scheme {
        case .basic:
            return basicAuthorizationHeaderValue(username: username, password: password)
        case .digest:
            return digestAuthorizationHeaderValue(
                username: username,
                password: password,
                method: method,
                uri: uri,
                challenge: challenge,
                nonceCount: nonceCount,
                cnonce: cnonce
            )
        }
    }

    public static func authorizationHeaderValue(
        username: String,
        password: String,
        method: String,
        uri: String,
        headerValues: [String],
        nonceCount: UInt32 = 1,
        cnonce: String? = nil
    ) -> String? {
        guard let challenge = preferredChallenge(from: headerValues) else {
            return nil
        }

        return authorizationHeaderValue(
            username: username,
            password: password,
            method: method,
            uri: uri,
            challenge: challenge,
            nonceCount: nonceCount,
            cnonce: cnonce
        )
    }

    public static func basicAuthorizationHeaderValue(username: String, password: String) -> String {
        let token = "\(username):\(password)"
        let data = Data(token.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    public static func digestAuthorizationHeaderValue(
        username: String,
        password: String,
        method: String,
        uri: String,
        challenge: Challenge,
        nonceCount: UInt32 = 1,
        cnonce: String? = nil
    ) -> String? {
        guard let realm = challenge.realm,
              let nonce = challenge.nonce
        else {
            return nil
        }

        let normalizedAlgorithm = normalizeToken(challenge.algorithm)
        let useSess = normalizedAlgorithm == "md5-sess"
        let qopValue = selectedQOP(from: challenge.qop)
        if challenge.qop != nil, qopValue == nil {
            return nil
        }
        let cnonceValue = cnonce ?? makeCNonce()
        let ncValue = String(format: "%08x", nonceCount)

        let ha1Base = md5Hex("\(username):\(realm):\(password)")
        let ha1 = useSess
            ? md5Hex("\(ha1Base):\(nonce):\(cnonceValue)")
            : ha1Base

        // RFC 2617: qop "auth" uses HA2 = MD5(method:uri). "auth-int" uses HA2 = MD5(method:uri:H(entity-body)).
        // RTSP control requests have no body; H("") = d41d8cd98f00b204e9800998ecf8427e (32 hex chars).
        let ha2: String
        switch qopValue {
        case "auth-int":
            let entityHex = md5Hex("")
            ha2 = md5Hex("\(method.uppercased()):\(uri):\(entityHex)")
        case "auth", nil:
            ha2 = md5Hex("\(method.uppercased()):\(uri)")
        default:
            ha2 = md5Hex("\(method.uppercased()):\(uri)")
        }

        let response: String
        if let qopValue {
            response = md5Hex("\(ha1):\(nonce):\(ncValue):\(cnonceValue):\(qopValue):\(ha2)")
        } else {
            response = md5Hex("\(ha1):\(nonce):\(ha2)")
        }

        var components: [String] = []
        components.append(#"username="\#(escapeQuotedValue(username))""#)
        components.append(#"realm="\#(escapeQuotedValue(realm))""#)
        components.append(#"nonce="\#(escapeQuotedValue(nonce))""#)
        components.append(#"uri="\#(escapeQuotedValue(uri))""#)
        components.append(#"response="\#(response)""#)

        if let algorithm = challenge.algorithm, !algorithm.isEmpty {
            // Many RTSP servers echo `algorithm="MD5"`; matching quoted form improves interoperability (e.g. EvoStream).
            components.append(#"algorithm="\#(escapeQuotedValue(algorithm))""#)
        } else if useSess {
            components.append(#"algorithm="MD5-sess""#)
        }

        if let opaque = challenge.opaque {
            components.append(#"opaque="\#(escapeQuotedValue(opaque))""#)
        }

        if let qopValue {
            components.append("qop=\(qopValue)")
            components.append("nc=\(ncValue)")
            components.append(#"cnonce="\#(escapeQuotedValue(cnonceValue))""#)
        }

        return "Digest " + components.joined(separator: ", ")
    }

    /// Explains why `digestAuthorizationHeaderValue` would return `nil` (for debug logging).
    public static func digestBuildFailureReason(for challenge: Challenge) -> String? {
        switch challenge.scheme {
        case .basic:
            return nil
        case .digest:
            if challenge.realm == nil {
                return "Digest challenge missing realm"
            }
            if challenge.nonce == nil {
                return "Digest challenge missing nonce"
            }
            if challenge.qop != nil, selectedQOP(from: challenge.qop) == nil {
                return "Digest qop not supported: \(challenge.qop ?? "") (client supports auth, auth-int)"
            }
            let alg = normalizeToken(challenge.algorithm)
            if let alg, alg != "md5", alg != "md5-sess" {
                return "Digest algorithm may be unsupported: \(challenge.algorithm ?? "") (client implements MD5 / MD5-sess only)"
            }
            return nil
        }
    }
}

private extension RTSPAuthenticator {
    static func parseChallenges(inHeaderValue headerValue: String) -> [Challenge] {
        let segments = splitTopLevel(headerValue, separator: ",")
        var challenges: [Challenge] = []
        var currentScheme: Scheme?
        var currentParameters: [String: String] = [:]

        func flushCurrent() {
            guard let currentScheme else { return }
            challenges.append(Challenge(scheme: currentScheme, parameters: currentParameters))
        }

        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }

            if let (scheme, parameterText) = parseChallengeStart(segment) {
                flushCurrent()
                currentScheme = scheme
                currentParameters = parseParameters(parameterText)
            } else if currentScheme != nil {
                currentParameters.merge(parseParameters(segment), uniquingKeysWith: { _, new in new })
            }
        }

        flushCurrent()
        return challenges
    }

    static func parseChallengeStart(_ segment: String) -> (Scheme, String)? {
        let scanner = Scanner(string: segment)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        guard let token = scanner.scanUpToCharacters(from: .whitespacesAndNewlines) else {
            return nil
        }

        guard let scheme = Scheme(headerToken: token) else {
            return nil
        }

        let remainder = segment.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (scheme, String(remainder))
    }

    static func parseParameters(_ text: String) -> [String: String] {
        var parameters: [String: String] = [:]
        for fragment in splitTopLevel(text, separator: ",") {
            let token = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard let equalsIndex = token.firstIndex(of: "=") else { continue }

            let key = token[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = token[token.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parameters[key] = unquote(rawValue)
        }
        return parameters
    }

    static func selectedQOP(from qopValue: String?) -> String? {
        guard let qopValue else { return nil }
        let options = splitTopLevel(qopValue, separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased() }
            .filter { !$0.isEmpty }

        if options.contains("auth") {
            return "auth"
        }

        if options.contains("auth-int") {
            return "auth-int"
        }

        return nil
    }

    static func normalizeToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    static func makeCNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func escapeQuotedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func unquote(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        var result = ""
        var escaping = false
        for character in trimmed {
            if escaping {
                result.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                escaping = true
                continue
            }

            result.append(character)
        }

        return result
    }

    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var isInQuotes = false
        var isEscaping = false

        for character in text {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                current.append(character)
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInQuotes.toggle()
                current.append(character)
                continue
            }

            if character == separator, !isInQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        parts.append(current)
        return parts
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
