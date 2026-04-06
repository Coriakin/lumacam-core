import Foundation

public enum SDPTrackSelectionError: Error, Equatable, Sendable {
    case noPlayableVideoTrack
    case multiplePlayableVideoTracks(Int)
    case unsupportedVideoCodec(String)
    case invalidControlURL(String)
    case invalidSpropParameterSets(String)
}

public struct SDPTrackSelection: Sendable, Equatable {
    public let mediaDescription: SDPMediaDescription
    public let rtpMap: SDPRTPMapAttribute
    public let fmtp: SDPFmtpAttribute?
    public let controlURL: URL
    public let playbackControlURL: URL
    public let spropParameterSets: [String]
    public let sps: Data?
    public let pps: Data?

    public init(
        mediaDescription: SDPMediaDescription,
        rtpMap: SDPRTPMapAttribute,
        fmtp: SDPFmtpAttribute?,
        controlURL: URL,
        playbackControlURL: URL,
        spropParameterSets: [String],
        sps: Data?,
        pps: Data?
    ) {
        self.mediaDescription = mediaDescription
        self.rtpMap = rtpMap
        self.fmtp = fmtp
        self.controlURL = controlURL
        self.playbackControlURL = playbackControlURL
        self.spropParameterSets = spropParameterSets
        self.sps = sps
        self.pps = pps
    }
}

public enum SDPTrackSelector {
    public static func selectPlayableH264VideoTrack(
        in sessionDescription: SDPSessionDescription,
        baseRTSPURL: URL
    ) throws -> SDPTrackSelection {
        let videoTracks = sessionDescription.mediaDescriptions.filter(\.isVideo)

        guard !videoTracks.isEmpty else {
            throw SDPTrackSelectionError.noPlayableVideoTrack
        }

        // Ignore non-video media (e.g. AAC) — MVP plays H.264 only; no SETUP for audio.

        var candidates: [SDPTrackSelection] = []
        let sessionControl = sessionControlAttribute(in: sessionDescription)

        for media in videoTracks {
            for payloadType in media.formats {
                guard let rtpMap = media.rtpMap(for: payloadType),
                      rtpMap.encodingName.caseInsensitiveCompare("H264") == .orderedSame else {
                    continue
                }

                let fmtp = media.fmtp(for: payloadType)
                let spropParameterSets = try parseSPropParameterSets(from: fmtp)
                let (sps, pps) = try decodeParameterSets(spropParameterSets)
                let controlURL = try resolveControlURL(
                    mediaControl: media.controlAttribute,
                    sessionControl: sessionControl,
                    baseRTSPURL: baseRTSPURL
                )
                let playbackControlURL = try resolvePlaybackControlURL(
                    mediaControl: media.controlAttribute,
                    sessionControl: sessionControl,
                    baseRTSPURL: baseRTSPURL
                )

                candidates.append(
                    SDPTrackSelection(
                        mediaDescription: media,
                        rtpMap: rtpMap,
                        fmtp: fmtp,
                        controlURL: controlURL,
                        playbackControlURL: playbackControlURL,
                        spropParameterSets: spropParameterSets,
                        sps: sps,
                        pps: pps
                    )
                )
            }
        }

        switch candidates.count {
        case 0:
            let codec = videoTracks
                .compactMap { track in track.rtpMaps.first?.encodingName }
                .first ?? videoTracks.first?.mediaType ?? "unknown"
            throw SDPTrackSelectionError.unsupportedVideoCodec(codec)
        case 1:
            return candidates[0]
        default:
            throw SDPTrackSelectionError.multiplePlayableVideoTracks(candidates.count)
        }
    }

    public static func resolveControlURL(
        mediaControl: String?,
        sessionControl: String?,
        baseRTSPURL: URL
    ) throws -> URL {
        let candidate = mediaControl?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? sessionControl?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let control = candidate, !control.isEmpty, control != "*" else {
            return baseRTSPURL
        }

        if let absolute = URL(string: control), absolute.scheme != nil {
            return absolute
        }

        guard var components = URLComponents(url: baseRTSPURL, resolvingAgainstBaseURL: false) else {
            throw SDPTrackSelectionError.invalidControlURL(control)
        }

        let basePath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let resolvedPath: String
        if control.hasPrefix("/") {
            resolvedPath = control
        } else {
            resolvedPath = basePath.hasSuffix("/") ? basePath + control : basePath + "/" + control
        }

        components.percentEncodedPath = resolvedPath
        guard let resolvedURL = components.url else {
            throw SDPTrackSelectionError.invalidControlURL(control)
        }

        return resolvedURL
    }

    public static func resolvePlaybackControlURL(
        mediaControl: String?,
        sessionControl: String?,
        baseRTSPURL: URL
    ) throws -> URL {
        if let sessionControl,
           !sessionControl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sessionControl.trimmingCharacters(in: .whitespacesAndNewlines) != "*" {
            return try resolveControlURL(
                mediaControl: sessionControl,
                sessionControl: nil,
                baseRTSPURL: baseRTSPURL
            )
        }

        return try resolveControlURL(
            mediaControl: mediaControl,
            sessionControl: sessionControl,
            baseRTSPURL: baseRTSPURL
        )
    }

    public static func parseSPropParameterSets(from fmtp: SDPFmtpAttribute?) throws -> [String] {
        guard let fmtp else { return [] }

        let parameters = parseKeyValuePairs(fmtp.parameters)
        guard let raw = parameters["sprop-parameter-sets"], !raw.isEmpty else {
            return []
        }

        let values = splitParameterList(raw, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !values.isEmpty, values.count <= 2 else {
            throw SDPTrackSelectionError.invalidSpropParameterSets(raw)
        }

        return values
    }

    public static func decodeParameterSets(_ spropParameterSets: [String]) throws -> (sps: Data?, pps: Data?) {
        guard !spropParameterSets.isEmpty else {
            return (nil, nil)
        }

        let decoded = try spropParameterSets.map { encoded -> Data in
            guard let data = Data(base64Encoded: encoded) else {
                throw SDPTrackSelectionError.invalidSpropParameterSets(encoded)
            }
            return data
        }

        let sps = decoded.first
        let pps = decoded.count > 1 ? decoded[1] : nil
        return (sps, pps)
    }

    private static func sessionControlAttribute(in sessionDescription: SDPSessionDescription) -> String? {
        sessionDescription.attributes.first { $0.name.caseInsensitiveCompare("control") == .orderedSame }?.value
    }

    private static func parseKeyValuePairs(_ text: String) -> [String: String] {
        var values: [String: String] = [:]

        for fragment in splitParameterList(text, separator: ";") {
            let token = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }

            if let equalsIndex = token.firstIndex(of: "=") {
                let key = token[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = token[token.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                values[key] = unquote(value)
            } else {
                values[token.lowercased()] = ""
            }
        }

        return values
    }

    private static func splitParameterList(_ text: String, separator: Character) -> [String] {
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

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }

        return String(trimmed.dropFirst().dropLast())
    }
}
