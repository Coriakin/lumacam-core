import Foundation

enum RTSPTransportHeaderError: Error, Equatable, Sendable {
    case emptyHeader
    case invalidAlternative(String)
    case invalidTransportSpec(String)
    case invalidParameter(String)
    case invalidInterleavedChannel(String)
    case invalidPortPair(String)
    case noTCPInterleavedAlternative
    case multipleTCPInterleavedAlternatives(Int)
}

struct RTSPTransportHeader: Equatable, Sendable {
    var alternatives: [RTSPTransportAlternative]

    init(alternatives: [RTSPTransportAlternative] = []) {
        self.alternatives = alternatives
    }

    static func parse(_ headerValue: String) throws -> RTSPTransportHeader {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RTSPTransportHeaderError.emptyHeader
        }

        let value: String
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let headerName = trimmed[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if headerName.caseInsensitiveCompare("Transport") == .orderedSame {
                value = String(trimmed[trimmed.index(after: colonIndex)...])
            } else {
                value = trimmed
            }
        } else {
            value = trimmed
        }

        let alternatives = try splitTopLevel(value, separator: ",").map { fragment in
            try RTSPTransportAlternative.parse(fragment)
        }

        guard !alternatives.isEmpty else {
            throw RTSPTransportHeaderError.emptyHeader
        }

        return RTSPTransportHeader(alternatives: alternatives)
    }

    func tcpInterleavedAlternative() -> RTSPTransportAlternative? {
        alternatives.first { $0.isTCPInterleaved }
    }

    func singleTCPInterleavedAlternative() throws -> RTSPTransportAlternative {
        let matches = alternatives.filter { $0.isTCPInterleaved }
        guard !matches.isEmpty else {
            throw RTSPTransportHeaderError.noTCPInterleavedAlternative
        }
        guard matches.count == 1, let match = matches.first else {
            throw RTSPTransportHeaderError.multipleTCPInterleavedAlternatives(matches.count)
        }
        return match
    }
}

struct RTSPTransportAlternative: Equatable, Sendable {
    var profile: String
    var lowerTransport: String?
    var castMode: String?
    var parameters: [RTSPTransportParameter]
    var interleavedChannelPair: RTSPTransportChannelPair?
    var ssrc: String?
    var serverPort: RTSPTransportPortPair?
    var clientPort: RTSPTransportPortPair?

    var isTCPInterleaved: Bool {
        guard let lowerTransport else { return false }
        return lowerTransport.caseInsensitiveCompare("TCP") == .orderedSame && interleavedChannelPair != nil
    }

    func parameter(named name: String) -> RTSPTransportParameter? {
        parameters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func parse(_ fragment: String) throws -> RTSPTransportAlternative {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RTSPTransportHeaderError.invalidAlternative(fragment)
        }

        let parts = try splitTopLevel(trimmed, separator: ";")
        guard let transportSpec = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !transportSpec.isEmpty else {
            throw RTSPTransportHeaderError.invalidTransportSpec(fragment)
        }

        let parsedSpec = try parseTransportSpec(transportSpec, rawFragment: fragment)
        var parameters: [RTSPTransportParameter] = []
        var interleavedChannelPair: RTSPTransportChannelPair?
        var ssrc: String?
        var serverPort: RTSPTransportPortPair?
        var clientPort: RTSPTransportPortPair?
        var castMode: String?

        for rawParameter in parts.dropFirst() {
            let parameter = rawParameter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parameter.isEmpty else { continue }

            let parsedParameter = try parseParameter(parameter)
            parameters.append(parsedParameter)

            switch parsedParameter.name.lowercased() {
            case "unicast", "multicast":
                castMode = parsedParameter.name.lowercased()
            case "interleaved":
                guard let value = parsedParameter.value else {
                    throw RTSPTransportHeaderError.invalidInterleavedChannel(parameter)
                }
                interleavedChannelPair = try parseChannelPair(value, error: .invalidInterleavedChannel(parameter))
            case "ssrc":
                ssrc = parsedParameter.value
            case "server_port":
                guard let value = parsedParameter.value else {
                    throw RTSPTransportHeaderError.invalidPortPair(parameter)
                }
                serverPort = try parsePortPair(value, error: .invalidPortPair(parameter))
            case "client_port":
                guard let value = parsedParameter.value else {
                    throw RTSPTransportHeaderError.invalidPortPair(parameter)
                }
                clientPort = try parsePortPair(value, error: .invalidPortPair(parameter))
            default:
                break
            }
        }

        return RTSPTransportAlternative(
            profile: parsedSpec.profile,
            lowerTransport: parsedSpec.lowerTransport,
            castMode: castMode,
            parameters: parameters,
            interleavedChannelPair: interleavedChannelPair,
            ssrc: ssrc,
            serverPort: serverPort,
            clientPort: clientPort
        )
    }
}

struct RTSPTransportChannelPair: Equatable, Sendable {
    var first: Int
    var second: Int
}

struct RTSPTransportPortPair: Equatable, Sendable {
    var first: Int
    var second: Int
}

enum RTSPTransportParameter: Equatable, Sendable {
    case token(String)
    case keyValue(name: String, value: String?)

    var name: String {
        switch self {
        case .token(let name), .keyValue(let name, _):
            return name
        }
    }

    var value: String? {
        switch self {
        case .token:
            return nil
        case .keyValue(_, let value):
            return value
        }
    }
}

private extension RTSPTransportAlternative {
    struct TransportSpec: Equatable, Sendable {
        let profile: String
        let lowerTransport: String?
    }
}

private extension RTSPTransportAlternative {
    static func parseTransportSpec(_ transportSpec: String, rawFragment: String) throws -> TransportSpec {
        let components = transportSpec
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard components.count >= 2 else {
            throw RTSPTransportHeaderError.invalidTransportSpec(rawFragment)
        }

        if components.count == 2 {
            return TransportSpec(profile: components.joined(separator: "/"), lowerTransport: nil)
        }

        return TransportSpec(
            profile: components[..<(components.count - 1)].joined(separator: "/"),
            lowerTransport: components.last
        )
    }

    static func parseParameter(_ parameter: String) throws -> RTSPTransportParameter {
        if let equalsIndex = parameter.firstIndex(of: "=") {
            let name = parameter[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = parameter[parameter.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw RTSPTransportHeaderError.invalidParameter(parameter)
            }

            return .keyValue(name: name, value: unquote(rawValue))
        }

        let token = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw RTSPTransportHeaderError.invalidParameter(parameter)
        }
        return .token(token)
    }

    static func parseChannelPair(_ value: String, error: RTSPTransportHeaderError) throws -> RTSPTransportChannelPair {
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let firstToken = parts.first,
              let first = Int(firstToken.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw error
        }

        let second: Int
        if parts.count == 1 {
            second = first
        } else if let parsedSecond = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            second = parsedSecond
        } else {
            throw error
        }

        return RTSPTransportChannelPair(first: first, second: second)
    }

    static func parsePortPair(_ value: String, error: RTSPTransportHeaderError) throws -> RTSPTransportPortPair {
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let firstToken = parts.first,
              let first = Int(firstToken.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw error
        }

        let second: Int
        if parts.count == 1 {
            second = first
        } else if let parsedSecond = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            second = parsedSecond
        } else {
            throw error
        }

        return RTSPTransportPortPair(first: first, second: second)
    }
}

private func splitTopLevel(_ value: String, separator: Character) throws -> [String] {
    var parts: [String] = []
    var current = ""
    var isInQuotes = false
    var isEscaping = false

    for character in value {
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
            current.removeAll(keepingCapacity: true)
            continue
        }

        current.append(character)
    }

    if isInQuotes {
        throw RTSPTransportHeaderError.invalidAlternative(value)
    }

    parts.append(current)
    return parts
}

private func unquote(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
        return trimmed.isEmpty ? nil : trimmed
    }

    return String(trimmed.dropFirst().dropLast())
}
