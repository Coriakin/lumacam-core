import Foundation

struct NativeRTSPSelectedVideoTrack: Sendable, Equatable {
    let controlURL: URL
    let playbackControlURL: URL
    let payloadType: String
    let codecName: String
    let clockRate: Int
    let spropParameterSets: [String]
    let sps: Data?
    let pps: Data?

    init(selection: SDPTrackSelection) {
        controlURL = selection.controlURL
        playbackControlURL = selection.playbackControlURL
        payloadType = selection.rtpMap.payloadType
        codecName = selection.rtpMap.encodingName
        clockRate = selection.rtpMap.clockRate
        spropParameterSets = selection.spropParameterSets
        sps = selection.sps
        pps = selection.pps
    }

    var summary: String {
        let spropDescription = spropParameterSets.isEmpty ? "no-sprop" : "sprop-count=\(spropParameterSets.count)"
        return "setup=\(controlURL.absoluteString) play=\(playbackControlURL.absoluteString) payload=\(payloadType) codec=\(codecName) clock=\(clockRate) \(spropDescription)"
    }
}
