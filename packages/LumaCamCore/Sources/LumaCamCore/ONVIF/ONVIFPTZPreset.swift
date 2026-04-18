import Foundation

/// A position preset stored on the camera (ONVIF GetPresets / GotoPreset).
public struct ONVIFPTZPreset: Identifiable, Hashable, Sendable {
    public var token: String
    /// Human-readable name from the camera, when provided.
    public var name: String?

    public var id: String { token }

    public init(token: String, name: String? = nil) {
        self.token = token
        self.name = name
    }

    public var displayLabel: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? token : trimmed
    }
}

public enum ONVIFPTZPresetParsing {
    /// Parses `<tptz:GetPresetsResponse>` body (full SOAP response is fine).
    public static func presets(from xml: String) -> [ONVIFPTZPreset] {
        var seen = Set<String>()
        var result: [ONVIFPTZPreset] = []

        let closedPattern =
            #"(?s)<(?:[\w-]+:)?Preset\b[^>]*\btoken="([^"]+)"[^>]*>(.*?)</(?:[\w-]+:)?Preset>"#
        if let closedRegex = try? NSRegularExpression(pattern: closedPattern, options: [.caseInsensitive]) {
            let ns = xml as NSString
            closedRegex.enumerateMatches(in: xml, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                let tokenRange = match.range(at: 1)
                let innerRange = match.range(at: 2)
                guard tokenRange.location != NSNotFound else { return }
                let token = ns.substring(with: tokenRange)
                guard seen.insert(token).inserted else { return }
                let inner = innerRange.location != NSNotFound ? ns.substring(with: innerRange) : ""
                let name = extractName(from: inner)
                result.append(ONVIFPTZPreset(token: token, name: name))
            }
        }

        let voidPattern =
            #"<(?:[\w-]+:)?Preset\b[^>]*\btoken="([^"]+)"[^>]*/>"#
        if let voidRegex = try? NSRegularExpression(pattern: voidPattern, options: [.caseInsensitive]) {
            let ns = xml as NSString
            voidRegex.enumerateMatches(in: xml, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                let tokenRange = match.range(at: 1)
                guard tokenRange.location != NSNotFound else { return }
                let token = ns.substring(with: tokenRange)
                guard seen.insert(token).inserted else { return }
                result.append(ONVIFPTZPreset(token: token, name: nil))
            }
        }

        return result
    }

    private static func extractName(from inner: String) -> String? {
        let pattern = #"(?s)<(?:[\w-]+:)?Name[^>]*>([^<]*)</(?:[\w-]+:)?Name>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = inner as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: inner, options: [], range: full), m.numberOfRanges >= 2 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        let raw = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
