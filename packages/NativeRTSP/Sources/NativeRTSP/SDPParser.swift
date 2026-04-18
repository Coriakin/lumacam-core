import Foundation

public enum SDPParserError: Error, Equatable, Sendable {
    case emptyDocument
    case invalidLine(String)
    case invalidVersion(String)
    case invalidOrigin(String)
    case invalidConnection(String)
    case invalidBandwidth(String)
    case invalidTimeRange(String)
    case invalidRepeatTime(String)
    case invalidMediaDescription(String)
    case invalidRTPMap(String)
    case invalidFMTP(String)
}

public enum SDPParser {
    public static func parse(_ text: String) throws -> SDPSessionDescription {
        try parseLines(text.components(separatedBy: .newlines))
    }

    public static func parse(_ data: Data, encoding: String.Encoding = .utf8) throws -> SDPSessionDescription {
        guard let text = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) else {
            throw SDPParserError.emptyDocument
        }
        return try parse(text)
    }

    public static func parseLines(_ lines: [String]) throws -> SDPSessionDescription {
        var session = SDPSessionDescription()
        var currentMediaIndex: Int?
        var currentRepeatTimeIndex: Int?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard line.count >= 2, let type = line.first, line[line.index(after: line.startIndex)] == "=" else {
                throw SDPParserError.invalidLine(line)
            }

            let value = String(line.dropFirst(2))
            switch type {
            case "v":
                session.version = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "o":
                session.origin = try parseOrigin(value)
            case "s":
                session.sessionName = value
            case "i":
                if let currentMediaIndex {
                    session.mediaDescriptions[currentMediaIndex].information = value
                } else {
                    session.sessionInformation = value
                }
            case "u":
                session.uri = value
            case "e":
                session.email = value
            case "p":
                session.phone = value
            case "c":
                let connection = try parseConnection(value)
                if let currentMediaIndex {
                    session.mediaDescriptions[currentMediaIndex].connection = connection
                } else {
                    session.connection = connection
                }
            case "b":
                let bandwidth = try parseBandwidth(value)
                if let currentMediaIndex {
                    session.mediaDescriptions[currentMediaIndex].bandwidths.append(bandwidth)
                } else {
                    session.bandwidths.append(bandwidth)
                }
            case "t":
                let timeRange = try parseTimeRange(value)
                session.timeRanges.append(timeRange)
                currentRepeatTimeIndex = session.timeRanges.indices.last
            case "r":
                let repeatTime = try parseRepeatTime(value)
                guard let currentRepeatTimeIndex else {
                    throw SDPParserError.invalidRepeatTime(value)
                }
                session.timeRanges[currentRepeatTimeIndex].repeatTimes.append(repeatTime)
            case "a":
                let attribute = parseAttribute(value)
                if let currentMediaIndex {
                    appendMediaAttribute(attribute, to: &session.mediaDescriptions[currentMediaIndex])
                } else {
                    session.attributes.append(attribute)
                }
            case "m":
                let media = try parseMediaDescription(value)
                session.mediaDescriptions.append(media)
                currentMediaIndex = session.mediaDescriptions.indices.last
                currentRepeatTimeIndex = nil
            case "z", "k":
                continue
            default:
                continue
            }
        }

        guard session.version != nil || !session.mediaDescriptions.isEmpty || !session.attributes.isEmpty else {
            throw SDPParserError.emptyDocument
        }

        return session
    }
}

private extension SDPParser {
    static func appendMediaAttribute(_ attribute: SDPAttribute, to media: inout SDPMediaDescription) {
        media.attributes.append(attribute)

        guard let value = attribute.value else { return }

        switch attribute.name.lowercased() {
        case "control":
            break
        case "rtpmap":
            if let parsed = try? parseRTPMap(value) {
                media.rtpMaps.append(parsed)
            }
        case "fmtp":
            if let parsed = try? parseFMTP(value) {
                media.fmtpAttributes.append(parsed)
            }
        default:
            break
        }
    }

    static func parseOrigin(_ value: String) throws -> SDPOrigin {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count == 6 {
            return SDPOrigin(
                username: parts[0],
                sessionID: parts[1],
                sessionVersion: parts[2],
                networkType: parts[3],
                addressType: parts[4],
                unicastAddress: parts[5]
            )
        }

        guard parts.count >= 7 else {
            throw SDPParserError.invalidOrigin(value)
        }

        guard let anchor = parts.indices.dropFirst(3).first(where: { i in
            parts[i] == "IN" && i + 2 < parts.count
                && (parts[i + 1] == "IP4" || parts[i + 1] == "IP6")
        }) else {
            throw SDPParserError.invalidOrigin(value)
        }

        let addressTail = parts[(anchor + 2)...].joined(separator: " ")
        guard !addressTail.isEmpty else {
            throw SDPParserError.invalidOrigin(value)
        }

        return SDPOrigin(
            username: parts[0],
            sessionID: parts[1],
            sessionVersion: parts[2],
            networkType: parts[anchor],
            addressType: parts[anchor + 1],
            unicastAddress: addressTail
        )
    }

    static func parseConnection(_ value: String) throws -> SDPConnectionInformation {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 3 else {
            throw SDPParserError.invalidConnection(value)
        }

        return SDPConnectionInformation(
            networkType: parts[0],
            addressType: parts[1],
            address: parts[2...].joined(separator: " ")
        )
    }

    static func parseBandwidth(_ value: String) throws -> SDPBandwidth {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let bandwidth = UInt64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SDPParserError.invalidBandwidth(value)
        }

        return SDPBandwidth(type: String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines), value: bandwidth)
    }

    static func parseTimeRange(_ value: String) throws -> SDPTimeRange {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2,
              let startTime = UInt64(parts[0]),
              let stopTime = UInt64(parts[1]) else {
            throw SDPParserError.invalidTimeRange(value)
        }

        return SDPTimeRange(startTime: startTime, stopTime: stopTime)
    }

    static func parseRepeatTime(_ value: String) throws -> SDPRepeatTime {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2,
              let interval = UInt64(parts[0]),
              let duration = UInt64(parts[1]) else {
            throw SDPParserError.invalidRepeatTime(value)
        }

        let offsets = try parts.dropFirst(2).map { part -> UInt64 in
            guard let offset = UInt64(part) else {
                throw SDPParserError.invalidRepeatTime(value)
            }
            return offset
        }

        return SDPRepeatTime(interval: interval, duration: duration, offsets: offsets)
    }

    static func parseAttribute(_ value: String) -> SDPAttribute {
        guard let colonIndex = value.firstIndex(of: ":") else {
            return SDPAttribute(name: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let name = String(value[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let attributeValue = String(value[value.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return SDPAttribute(name: name, value: attributeValue.isEmpty ? nil : attributeValue)
    }

    static func parseMediaDescription(_ value: String) throws -> SDPMediaDescription {
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 4 else {
            throw SDPParserError.invalidMediaDescription(value)
        }

        let portTokens = parts[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let port = UInt16(portTokens[0]) else {
            throw SDPParserError.invalidMediaDescription(value)
        }

        let portCount = portTokens.count == 2 ? UInt16(portTokens[1]) : nil
        let formats = Array(parts.dropFirst(3))
        guard !formats.isEmpty else {
            throw SDPParserError.invalidMediaDescription(value)
        }

        return SDPMediaDescription(
            mediaType: parts[0],
            port: port,
            portCount: portCount,
            transportProtocol: parts[2],
            formats: formats
        )
    }

    static func parseRTPMap(_ value: String) throws -> SDPRTPMapAttribute {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else {
            throw SDPParserError.invalidRTPMap(value)
        }

        let payloadType = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let encodingParts = parts[1].split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard encodingParts.count >= 2, let clockRate = Int(encodingParts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SDPParserError.invalidRTPMap(value)
        }

        return SDPRTPMapAttribute(
            payloadType: payloadType,
            encodingName: encodingParts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            clockRate: clockRate,
            encodingParameters: encodingParts.dropFirst(2).joined(separator: "/").nilIfEmpty
        )
    }

    static func parseFMTP(_ value: String) throws -> SDPFmtpAttribute {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else {
            throw SDPParserError.invalidFMTP(value)
        }

        return SDPFmtpAttribute(
            payloadType: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
