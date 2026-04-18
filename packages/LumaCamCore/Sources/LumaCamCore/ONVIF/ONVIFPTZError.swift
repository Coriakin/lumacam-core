import Foundation

public enum ONVIFPTZError: Error, LocalizedError, Sendable {
    case missingCredentials
    case invalidDeviceURL
    case badHTTPStatus(Int)
    case soapFault(String)
    case parseError(String)
    case noPTZEndpoint
    case noMediaEndpoint
    case noProfileToken

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "ONVIF PTZ needs a camera account username (and password) in Authentication."
        case .invalidDeviceURL:
            "Could not build the ONVIF device URL. Check PTZ host and port."
        case .badHTTPStatus(let code):
            "ONVIF request failed with HTTP \(code)."
        case .soapFault(let reason):
            "ONVIF fault: \(reason)"
        case .parseError(let reason):
            "Could not read ONVIF response: \(reason)"
        case .noPTZEndpoint:
            "Camera did not report a PTZ service address (ONVIF GetCapabilities)."
        case .noMediaEndpoint:
            "Camera did not report a media service address (ONVIF GetCapabilities)."
        case .noProfileToken:
            "No ONVIF media profile with a token was found."
        }
    }
}
