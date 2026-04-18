import Crypto
import Foundation

enum ONVIFWSSecurity {
    /// WS-Security UsernameToken Profile 1.0 password digest (ONVIF).
    static func securityHeader(username: String, password: String) -> String {
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let nonceB64 = nonce.base64EncodedString()
        let created = Self.utcTimestamp()
        var concat = Data()
        concat.append(nonce)
        concat.append(Data(created.utf8))
        concat.append(Data(password.utf8))
        let digest = Insecure.SHA1.hash(data: concat)
        let digestB64 = Data(digest).base64EncodedString()

        return """
        <wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
          <wsse:UsernameToken>
            <wsse:Username>\(escapeXML(username))</wsse:Username>
            <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digestB64)</wsse:Password>
            <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceB64)</wsse:Nonce>
            <wsu:Created>\(created)</wsu:Created>
          </wsse:UsernameToken>
        </wsse:Security>
        """
    }

    private static func utcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func escapeXML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
