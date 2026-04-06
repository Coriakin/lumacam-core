import Foundation

enum RTSPParserError: Error, Equatable, Sendable {
    case emptyMessage
    case missingHeaderTerminator
    case invalidStatusLine(String)
    case unsupportedVersion(String)
    case invalidStatusCode(String)
    case invalidHeaderLine(String)
    case invalidHeaderName(String)
    case invalidContentLength(String)
    case bodyTooShort(expected: Int, actual: Int)
    case undecodableHeaders
}

enum RTSPParser {
    static func parseResponse(_ text: String) throws -> RTSPResponse {
        try parseResponse(Data(text.utf8))
    }

    static func parseResponse(_ data: Data) throws -> RTSPResponse {
        guard !data.isEmpty else {
            throw RTSPParserError.emptyMessage
        }

        let separator = try headerSeparatorRange(in: data)
        let headerData = data[..<separator.lowerBound]
        let bodyStart = separator.upperBound
        let bodyData = data[bodyStart...]

        guard let headerText = decodeHeaderText(from: Data(headerData)) else {
            throw RTSPParserError.undecodableHeaders
        }

        let lines = headerText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let statusLine = lines.first else {
            throw RTSPParserError.invalidStatusLine(headerText)
        }

        let response = try parseStatusLine(statusLine)
        let headers = try parseHeaders(Array(lines.dropFirst()))
        let contentLength = headers.last { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let body: Data?
        if let contentLength {
            guard contentLength >= 0 else {
                throw RTSPParserError.invalidContentLength(String(contentLength))
            }
            guard bodyData.count >= contentLength else {
                throw RTSPParserError.bodyTooShort(expected: contentLength, actual: bodyData.count)
            }
            body = contentLength == 0 ? nil : Data(bodyData.prefix(contentLength))
        } else {
            body = bodyData.isEmpty ? nil : Data(bodyData)
        }

        return RTSPResponse(
            version: response.version,
            statusCode: response.statusCode,
            reasonPhrase: response.reasonPhrase,
            headers: headers,
            body: body
        )
    }

    static func parseResponse(from data: Data) throws -> (response: RTSPResponse, consumedBytes: Int)? {
        guard !data.isEmpty else {
            return nil
        }

        let separator: Range<Data.Index>
        do {
            separator = try headerSeparatorRange(in: data)
        } catch RTSPParserError.missingHeaderTerminator {
            return nil
        }

        let headerData = data[..<separator.lowerBound]
        let bodyStart = separator.upperBound

        guard let headerText = decodeHeaderText(from: Data(headerData)) else {
            throw RTSPParserError.undecodableHeaders
        }

        let lines = headerText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let statusLine = lines.first else {
            throw RTSPParserError.invalidStatusLine(headerText)
        }

        let responseHead = try parseStatusLine(statusLine)
        let headers = try parseHeaders(Array(lines.dropFirst()))
        let contentLength = headers.last { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let availableBodyCount = data.distance(from: bodyStart, to: data.endIndex)
        if let contentLength, availableBodyCount < contentLength {
            return nil
        }

        let body: Data?
        let consumedBytes: Int
        if let contentLength {
            let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
            body = contentLength == 0 ? nil : Data(data[bodyStart..<bodyEnd])
            consumedBytes = data.distance(from: data.startIndex, to: bodyEnd)
        } else {
            body = availableBodyCount == 0 ? nil : Data(data[bodyStart...])
            consumedBytes = data.count
        }

        let response = RTSPResponse(
            version: responseHead.version,
            statusCode: responseHead.statusCode,
            reasonPhrase: responseHead.reasonPhrase,
            headers: headers,
            body: body
        )
        return (response, consumedBytes)
    }

    private static func parseStatusLine(_ statusLine: String) throws -> (version: String, statusCode: Int, reasonPhrase: String) {
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw RTSPParserError.invalidStatusLine(statusLine)
        }

        let version = String(parts[0])
        guard version == "RTSP/1.0" else {
            throw RTSPParserError.unsupportedVersion(version)
        }

        let codeString = String(parts[1])
        guard let statusCode = Int(codeString) else {
            throw RTSPParserError.invalidStatusCode(codeString)
        }

        let reasonPhrase = parts.count == 3 ? String(parts[2]) : ""
        return (version, statusCode, reasonPhrase)
    }

    private static func parseHeaders(_ lines: [String]) throws -> [RTSPHeader] {
        try lines.map { line in
            guard let colonIndex = line.firstIndex(of: ":") else {
                throw RTSPParserError.invalidHeaderLine(line)
            }

            let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw RTSPParserError.invalidHeaderName(line)
            }

            let valueStart = line.index(after: colonIndex)
            let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            return RTSPHeader(name, value)
        }
    }

    private static func headerSeparatorRange(in data: Data) throws -> Range<Data.Index> {
        if let range = data.range(of: Data([13, 10, 13, 10])) {
            return range
        }

        if let range = data.range(of: Data([10, 10])) {
            return range
        }

        throw RTSPParserError.missingHeaderTerminator
    }

    private static func decodeHeaderText(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(data: data, encoding: .isoLatin1)
    }
}
