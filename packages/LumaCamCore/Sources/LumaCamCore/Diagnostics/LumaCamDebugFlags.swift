import Foundation

/// Debug switches stored in `UserDefaults`. Used by the app Settings UI and RTSP logging.
public enum LumaCamDebugFlags {
    public static let verboseRTSPProtocolKey = "LumaCam.verboseRTSPProtocolLog"
    public static let logRTSPPlaintextSecretsKey = "LumaCam.logRTSPPlaintextSecrets"
    /// Watch snapshot `URLSession` loads: request URL, auth source, HTTP status (no passwords or Basic tokens).
    public static let verboseSnapshotHTTPLoadKey = "LumaCam.verboseSnapshotHTTPLoad"

    /// Log RTSP request lines, response status, and `WWW-Authenticate` details (no passwords unless plaintext secrets is on).
    public static var verboseRTSPProtocolLog: Bool {
        UserDefaults.standard.bool(forKey: verboseRTSPProtocolKey)
    }

    /// Log usernames, passwords, and full `Authorization` headers. **Dangerous** — enable only for local troubleshooting in Xcode.
    public static var logRTSPPlaintextSecrets: Bool {
        UserDefaults.standard.bool(forKey: logRTSPPlaintextSecretsKey)
    }

    public static var verboseSnapshotHTTPLoad: Bool {
        UserDefaults.standard.bool(forKey: verboseSnapshotHTTPLoadKey)
    }
}
