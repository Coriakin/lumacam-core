import Foundation

struct RTSPMethod: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    var description: String {
        rawValue
    }

    static let options: RTSPMethod = "OPTIONS"
    static let describe: RTSPMethod = "DESCRIBE"
    static let setup: RTSPMethod = "SETUP"
    static let play: RTSPMethod = "PLAY"
    static let pause: RTSPMethod = "PAUSE"
    static let teardown: RTSPMethod = "TEARDOWN"
    static let announce: RTSPMethod = "ANNOUNCE"
    static let record: RTSPMethod = "RECORD"
    static let getParameter: RTSPMethod = "GET_PARAMETER"
    static let setParameter: RTSPMethod = "SET_PARAMETER"
    static let redirect: RTSPMethod = "REDIRECT"
}

struct RTSPHeader: Equatable, Hashable, Sendable {
    var name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

struct RTSPRequest: Equatable, Sendable {
    var method: RTSPMethod
    var url: URL
    var headers: [RTSPHeader]
    var body: Data?

    init(
        method: RTSPMethod,
        url: URL,
        headers: [RTSPHeader] = [],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    func headerValue(named name: String) -> String? {
        headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var requestURI: String {
        url.absoluteString
    }

    func serializedData() -> Data {
        var headerLines = headers.map { "\($0.name): \($0.value)" }
        if let body {
            headerLines.append("Content-Length: \(body.count)")
        }

        var message = "\(method.rawValue) \(url.absoluteString) RTSP/1.0\r\n"
        if !headerLines.isEmpty {
            message += headerLines.joined(separator: "\r\n")
            message += "\r\n"
        }
        message += "\r\n"

        var data = Data(message.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    func serialized(authorizationHeader: String?) -> Data {
        guard let authorizationHeader else {
            return serializedData()
        }

        var updatedHeaders = headers
        updatedHeaders.append(RTSPHeader("Authorization", authorizationHeader))
        return RTSPRequest(method: method, url: url, headers: updatedHeaders, body: body).serializedData()
    }

    func serializedString() -> String? {
        String(data: serializedData(), encoding: .utf8)
    }
}

struct RTSPResponse: Equatable, Sendable {
    var version: String
    var statusCode: Int
    var reasonPhrase: String
    var headers: [RTSPHeader]
    var body: Data?

    init(
        version: String = "RTSP/1.0",
        statusCode: Int,
        reasonPhrase: String,
        headers: [RTSPHeader] = [],
        body: Data? = nil
    ) {
        self.version = version
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    var statusLine: String {
        "\(version) \(statusCode) \(reasonPhrase)"
    }

    func headerValue(named name: String) -> String? {
        headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func headerValues(named name: String) -> [String] {
        headers
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map(\.value)
    }

    var contentLength: Int? {
        headerValue(named: "Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var sessionIdentifier: String? {
        guard let header = headerValue(named: "Session") else {
            return nil
        }

        let token = header
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return token?.isEmpty == false ? token : nil
    }

    func stringBody(encoding: String.Encoding = .utf8) -> String? {
        guard let body else { return nil }
        return String(data: body, encoding: encoding)
    }
}
