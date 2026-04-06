import Testing
import Foundation
import CoreMedia
import LumaCamCore
@testable import NativeRTSP

// MARK: - RTSP Response Parsing

@Suite("RTSP Parser")
struct RTSPParserTests {

    @Test func parsesOKResponse() throws {
        let raw = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n"
        let response = try RTSPParser.parseResponse(raw.data(using: .utf8)!)
        #expect(response.statusCode == 200)
        #expect(response.reasonPhrase == "OK")
        #expect(response.headerValue(named: "CSeq") == "1")
    }

    @Test func parses401Response() throws {
        let raw = "RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Basic realm=\"Camera\"\r\n\r\n"
        let response = try RTSPParser.parseResponse(raw.data(using: .utf8)!)
        #expect(response.statusCode == 401)
        #expect(response.headerValue(named: "WWW-Authenticate") != nil)
    }

    @Test func parsesResponseWithBody() throws {
        let body = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"
        let raw = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let response = try RTSPParser.parseResponse(raw.data(using: .utf8)!)
        #expect(response.statusCode == 200)
        #expect(response.body.flatMap { String(data: $0, encoding: .utf8) } == body)
    }

    @Test func throwsOnIncompleteResponse() {
        let raw = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
        #expect(throws: (any Error).self) {
            try RTSPParser.parseResponse(raw.data(using: .utf8)!)
        }
    }

    @Test func throwsOnInvalidVersion() {
        let raw = "HTTP/1.1 200 OK\r\n\r\n"
        #expect(throws: (any Error).self) {
            try RTSPParser.parseResponse(raw.data(using: .utf8)!)
        }
    }

    @Test func streamingParserReturnsNilOnIncompleteData() throws {
        let partial = "RTSP/1.0 200 OK\r\nCSeq: 1\r".data(using: .utf8)!
        let result = try RTSPParser.parseResponse(from: partial)
        #expect(result == nil)
    }

    @Test func streamingParserReturnsConsumedByteCount() throws {
        let raw = "RTSP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA"
        let data = raw.data(using: .utf8)!
        let result = try #require(try RTSPParser.parseResponse(from: data))
        #expect(result.response.statusCode == 200)
        #expect(result.consumedBytes == data.count - "EXTRA".count)
    }

    @Test func acceptsLFOnlyLineEndings() throws {
        let raw = "RTSP/1.0 200 OK\nCSeq: 1\nContent-Length: 0\n\n"
        let response = try RTSPParser.parseResponse(raw.data(using: .utf8)!)
        #expect(response.statusCode == 200)
    }
}

// MARK: - RTSP Request Building

@Suite("RTSP Request")
struct RTSPRequestTests {

    @Test func optionsRequestSerialization() {
        let url = URL(string: "rtsp://cam.local/stream1")!
        let request = RTSPRequest(method: .options, url: url, headers: [RTSPHeader("CSeq", "1")])
        let text = String(data: request.serializedData(), encoding: .utf8)!
        #expect(text.hasPrefix("OPTIONS rtsp://cam.local/stream1 RTSP/1.0\r\n"))
        #expect(text.contains("CSeq: 1"))
    }

    @Test func describeRequestIncludesCustomHeader() {
        let url = URL(string: "rtsp://cam.local/stream1")!
        let request = RTSPRequest(
            method: .describe,
            url: url,
            headers: [RTSPHeader("CSeq", "2"), RTSPHeader("Accept", "application/sdp")]
        )
        let text = String(data: request.serializedData(), encoding: .utf8)!
        #expect(text.contains("Accept: application/sdp"))
    }
}

// MARK: - RTSP Authentication

@Suite("RTSP Authenticator")
struct RTSPAuthenticatorTests {

    @Test func basicAuthHeaderFormat() {
        let headerValue = "Basic realm=\"TestRealm\""
        let challenges = RTSPAuthenticator.parseChallenges(from: headerValue)
        let challenge = challenges.first!
        let header = RTSPAuthenticator.authorizationHeaderValue(
            username: "admin",
            password: "secret",
            method: "DESCRIBE",
            uri: "rtsp://cam.local/stream1",
            challenge: challenge
        )
        #expect(header?.hasPrefix("Basic ") == true)
        let token = String(header!.dropFirst("Basic ".count))
        let decoded = Data(base64Encoded: token).flatMap { String(data: $0, encoding: .utf8) }
        #expect(decoded == "admin:secret")
    }

    @Test func digestAuthQuotesAlgorithmParameter() throws {
        let headerValue = #"Digest realm="cam", nonce="n1", algorithm=MD5"#
        let challenges = RTSPAuthenticator.parseChallenges(from: headerValue)
        let challenge = try #require(challenges.first)
        let header = RTSPAuthenticator.authorizationHeaderValue(
            username: "viewer",
            password: "secret",
            method: "DESCRIBE",
            uri: "rtsp://192.168.1.201/s0",
            challenge: challenge
        )
        #expect(header?.contains(#"algorithm="MD5""#) == true)
    }

    @Test func digestAuthContainsExpectedFields() {
        let headerValue = #"Digest realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", algorithm=MD5, qop="auth""#
        let challenges = RTSPAuthenticator.parseChallenges(from: headerValue)
        let challenge = challenges.first!
        let header = RTSPAuthenticator.authorizationHeaderValue(
            username: "Mufasa",
            password: "Circle Of Life",
            method: "DESCRIBE",
            uri: "/dir/index.html",
            challenge: challenge
        )
        #expect(header?.hasPrefix("Digest ") == true)
        #expect(header?.contains("username=\"Mufasa\"") == true)
        #expect(header?.contains("realm=\"testrealm@host.com\"") == true)
        #expect(header?.contains("uri=\"/dir/index.html\"") == true)
        #expect(header?.contains("response=") == true)
    }

    @Test func digestAuthIntProducesAuthorizationWhenOnlyAuthIntOffered() throws {
        let headerValue = #"Digest realm="cam", nonce="abcnonce", qop="auth-int""#
        let challenges = RTSPAuthenticator.parseChallenges(from: headerValue)
        let challenge = try #require(challenges.first)
        let header = RTSPAuthenticator.authorizationHeaderValue(
            username: "viewer",
            password: "secret",
            method: "OPTIONS",
            uri: "rtsp://192.168.1.201:554/s0",
            challenge: challenge
        )
        #expect(header != nil)
        #expect(header?.contains("qop=auth-int") == true)
        #expect(header?.contains("nc=00000001") == true)
    }

    @Test func preferredChallengeSelectsDigestOverBasic() {
        let headerValues = [
            "Basic realm=\"cam\"",
            #"Digest realm="cam", nonce="abc123""#,
        ]
        let challenge = RTSPAuthenticator.preferredChallenge(from: headerValues)
        #expect(challenge?.scheme == .digest)
    }

    @Test func unknownSchemeProducesNilChallenge() {
        let headerValue = "Bearer token=abc"
        let challenges = RTSPAuthenticator.parseChallenges(from: headerValue)
        #expect(challenges.isEmpty)
    }
}

// MARK: - SDP Parsing

@Suite("SDP Parser")
struct SDPParserTests {

    private let minimalSDP = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=Test
        t=0 0
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z2QAKqwrQCgC,aO48gA==
        a=control:trackID=0

        """

    @Test func parsesVideoTrack() throws {
        let sdp = try SDPParser.parse(minimalSDP)
        #expect(sdp.mediaDescriptions.count == 1)
        let media = try #require(sdp.mediaDescriptions.first)
        #expect(media.mediaType == "video")
        #expect(media.rtpMaps.first?.encodingName == "H264")
        #expect(media.rtpMaps.first?.clockRate == 90000)
    }

    @Test func parsesControlURL() throws {
        let sdp = try SDPParser.parse(minimalSDP)
        let media = try #require(sdp.mediaDescriptions.first)
        #expect(media.controlAttribute == "trackID=0")
    }

    @Test func extractsSpropParameterSets() throws {
        let sdp = try SDPParser.parse(minimalSDP)
        let media = try #require(sdp.mediaDescriptions.first)
        let fmtp = media.fmtp(for: "96")
        #expect(fmtp != nil)
        #expect(fmtp?.parameters.contains("sprop-parameter-sets") == true)
    }

    @Test func multipleMediaDescriptions() throws {
        let sdpText = """
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=Multi
            t=0 0
            m=video 0 RTP/AVP 96
            a=rtpmap:96 H264/90000
            a=control:trackID=0
            m=audio 0 RTP/AVP 97
            a=rtpmap:97 MPEG4-GENERIC/44100
            a=control:trackID=1

            """
        let sdp = try SDPParser.parse(sdpText)
        #expect(sdp.mediaDescriptions.count == 2)
        #expect(sdp.mediaDescriptions[0].mediaType == "video")
        #expect(sdp.mediaDescriptions[1].mediaType == "audio")
    }
}

// MARK: - SDP Track Selection

@Suite("SDP Track Selection")
struct SDPTrackSelectionTests {

    private let validSDP = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=Camera
        t=0 0
        a=control:rtsp://cam.local/stream1
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z2QAKqwrQCgC,aO48gA==
        a=control:trackID=0

        """

    @Test func selectsH264Track() throws {
        let sdp = try SDPParser.parse(validSDP)
        let baseURL = URL(string: "rtsp://cam.local/stream1")!
        let selection = try SDPTrackSelector.selectPlayableH264VideoTrack(in: sdp, baseRTSPURL: baseURL)
        #expect(selection.rtpMap.encodingName == "H264")
    }

    /// UniFi / EvoStream often list `m=audio` before `m=video`; we must skip audio and still select H.264.
    @Test func selectsH264WhenAudioMediaPrecedesVideo() throws {
        let sdpText = """
            v=0
            o=- 0 0 IN IP4 192.168.1.201
            s=s0
            t=0 0
            a=control:*
            m=audio 0 RTP/AVP 96
            a=rtpmap:96 mpeg4-generic/48000/1
            a=control:trackID=1
            m=video 0 RTP/AVP 97
            a=rtpmap:97 H264/90000
            a=fmtp:97 packetization-mode=1;sprop-parameter-sets=Z2QAKqwrQCgC,aO48gA==
            a=control:trackID=2

            """
        let sdp = try SDPParser.parse(sdpText)
        let baseURL = URL(string: "rtsp://192.168.1.201/s0")!
        let selection = try SDPTrackSelector.selectPlayableH264VideoTrack(in: sdp, baseRTSPURL: baseURL)
        #expect(selection.rtpMap.encodingName == "H264")
        #expect(selection.rtpMap.payloadType == "97")
    }

    @Test func decodesSpropParameterSets() throws {
        let sdp = try SDPParser.parse(validSDP)
        let baseURL = URL(string: "rtsp://cam.local/stream1")!
        let selection = try SDPTrackSelector.selectPlayableH264VideoTrack(in: sdp, baseRTSPURL: baseURL)
        #expect(selection.sps != nil)
        #expect(selection.pps != nil)
        #expect(selection.spropParameterSets.count == 2)
    }

    @Test func throwsForNoVideoTrack() throws {
        let audioOnlySDP = """
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=Audio
            t=0 0
            m=audio 0 RTP/AVP 97
            a=rtpmap:97 MPEG4-GENERIC/44100
            a=control:trackID=0

            """
        let sdp = try SDPParser.parse(audioOnlySDP)
        let baseURL = URL(string: "rtsp://cam.local/audio")!
        #expect(throws: (any Error).self) {
            try SDPTrackSelector.selectPlayableH264VideoTrack(in: sdp, baseRTSPURL: baseURL)
        }
    }

    @Test func throwsForNonH264VideoTrack() throws {
        let h265SDP = """
            v=0
            o=- 0 0 IN IP4 127.0.0.1
            s=HEVC
            t=0 0
            m=video 0 RTP/AVP 96
            a=rtpmap:96 H265/90000
            a=control:trackID=0

            """
        let sdp = try SDPParser.parse(h265SDP)
        let baseURL = URL(string: "rtsp://cam.local/hevc")!
        #expect(throws: (any Error).self) {
            try SDPTrackSelector.selectPlayableH264VideoTrack(in: sdp, baseRTSPURL: baseURL)
        }
    }
}

// MARK: - RTP Interleaved Frame Parsing

@Suite("RTSP Interleaved Frame")
struct RTSPInterleavedFrameTests {

    @Test func parsesValidFrame() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var frame = Data([0x24, 0x00, 0x00, 0x04])
        frame.append(payload)
        switch RTSPInterleavedFrameParser.parse(from: frame) {
        case .complete(let parsed, let consumed):
            #expect(parsed.channel == 0)
            #expect(parsed.payload == payload)
            #expect(consumed == 8)
        default:
            Issue.record("Expected .complete")
        }
    }

    @Test func returnsIncompleteWhenPayloadTruncated() {
        let frame = Data([0x24, 0x00, 0x00, 0x04, 0xDE, 0xAD])
        switch RTSPInterleavedFrameParser.parse(from: frame) {
        case .incomplete: break
        default: Issue.record("Expected .incomplete")
        }
    }

    @Test func returnsInvalidForNonInterleavedData() {
        let frame = "RTSP/1.0 200 OK\r\n".data(using: .utf8)!
        switch RTSPInterleavedFrameParser.parse(from: frame) {
        case .invalid: break
        default: Issue.record("Expected .invalid")
        }
    }

    @Test func parsesLargePayload() {
        let payloadSize = 1400
        let payload = Data(repeating: 0xAB, count: payloadSize)
        var frame = Data([0x24, 0x01])
        frame.append(UInt8((payloadSize >> 8) & 0xFF))
        frame.append(UInt8(payloadSize & 0xFF))
        frame.append(payload)
        switch RTSPInterleavedFrameParser.parse(from: frame) {
        case .complete(let parsed, _):
            #expect(parsed.channel == 1)
            #expect(parsed.payload.count == payloadSize)
        default:
            Issue.record("Expected .complete")
        }
    }
}

// MARK: - RTP Packet Parsing

@Suite("RTP Packet")
struct RTPPacketTests {

    @Test func parsesMinimalRTPPacket() throws {
        var header = Data(count: 12)
        header[0] = 0x80           // V=2, P=0, X=0, CC=0
        header[1] = 0x60           // M=0, PT=96
        header[2] = 0x00; header[3] = 0x01  // seq=1
        header[4] = 0x00; header[5] = 0x01; header[6] = 0x5F; header[7] = 0x90 // ts=90000
        header[8] = 0x00; header[9] = 0x00; header[10] = 0x30; header[11] = 0x39 // SSRC=12345
        let payload = Data([0x65, 0x88, 0x84])
        let packet = try RTPPacket(data: header + payload)
        #expect(packet.payloadType == 96)
        #expect(packet.sequenceNumber == 1)
        #expect(packet.timestamp == 90000)
        #expect(packet.ssrc == 12345)
        #expect(packet.marker == false)
        #expect(packet.payload == payload)
    }

    @Test func parsesMarkerBit() throws {
        var header = Data(count: 12)
        header[0] = 0x80
        header[1] = 0xE0 // M=1, PT=96
        let packet = try RTPPacket(data: header)
        #expect(packet.marker == true)
    }

    @Test func throwsOnTooShortData() {
        #expect(throws: (any Error).self) {
            try RTPPacket(data: Data(count: 11))
        }
    }

    @Test func throwsOnWrongVersion() {
        var data = Data(count: 12)
        data[0] = 0x40 // Version=1 (invalid)
        #expect(throws: (any Error).self) {
            try RTPPacket(data: data)
        }
    }
}

// MARK: - H.264 RTP Depacketizer

@Suite("H.264 RTP Depacketizer")
struct H264RTPDepacketizerTests {

    private func makeRTPPacket(
        sequenceNumber: UInt16,
        timestamp: UInt32 = 90000,
        marker: Bool = false,
        payload: Data
    ) -> RTPPacket {
        var header = Data(count: 12)
        header[0] = 0x80
        header[1] = marker ? 0xE0 : 0x60
        header[2] = UInt8((sequenceNumber >> 8) & 0xFF)
        header[3] = UInt8(sequenceNumber & 0xFF)
        var ts = timestamp.bigEndian
        withUnsafeBytes(of: &ts) { header.replaceSubrange(4..<8, with: $0) }
        return try! RTPPacket(data: header + payload)
    }

    @Test func singleNALUnit() throws {
        let nalPayload = Data([0x65, 0x88, 0x84, 0x00])
        let depacketizer = H264RTPDepacketizer()
        let result = try depacketizer.depacketize(packet: makeRTPPacket(sequenceNumber: 1, payload: nalPayload))
        #expect(result.count == 1)
        #expect(result[0].starts(with: [0x00, 0x00, 0x00, 0x01]))
        #expect(result[0].dropFirst(4) == nalPayload)
    }

    @Test func stAPAWithTwoNALUs() throws {
        let nal1 = Data([0x67, 0x42, 0x00, 0x1F])
        let nal2 = Data([0x68, 0xCE, 0x38, 0x80])
        var payload = Data([0x18]) // STAP-A
        payload.append(UInt8(nal1.count >> 8)); payload.append(UInt8(nal1.count & 0xFF))
        payload.append(contentsOf: nal1)
        payload.append(UInt8(nal2.count >> 8)); payload.append(UInt8(nal2.count & 0xFF))
        payload.append(contentsOf: nal2)
        let result = try H264RTPDepacketizer().depacketize(packet: makeRTPPacket(sequenceNumber: 1, payload: payload))
        #expect(result.count == 2)
        #expect(result[0].dropFirst(4) == nal1)
        #expect(result[1].dropFirst(4) == nal2)
    }

    @Test func fuAFragmentedNALUnit() throws {
        let nalRefIdc: UInt8 = 0x60
        let nalType: UInt8 = 5
        let fuIndicator: UInt8 = nalRefIdc | 0x1C

        func makeFrag(start: Bool, end: Bool, data: Data) -> Data {
            var fuHeader: UInt8 = nalType
            if start { fuHeader |= 0x80 }
            if end { fuHeader |= 0x40 }
            return Data([fuIndicator, fuHeader]) + data
        }

        let d = H264RTPDepacketizer()
        let r1 = try d.depacketize(packet: makeRTPPacket(sequenceNumber: 1, payload: makeFrag(start: true, end: false, data: Data([0x01, 0x02]))))
        #expect(r1.isEmpty)
        let r2 = try d.depacketize(packet: makeRTPPacket(sequenceNumber: 2, payload: makeFrag(start: false, end: false, data: Data([0x03]))))
        #expect(r2.isEmpty)
        let r3 = try d.depacketize(packet: makeRTPPacket(sequenceNumber: 3, payload: makeFrag(start: false, end: true, data: Data([0x04]))))
        #expect(r3.count == 1)
        #expect(r3[0].starts(with: [0x00, 0x00, 0x00, 0x01]))
        let reconstructed = r3[0].dropFirst(4)
        #expect(reconstructed[reconstructed.startIndex] == nalRefIdc | nalType)
        #expect(reconstructed.dropFirst() == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test func outOfOrderFragmentationThrows() throws {
        let fuIndicator: UInt8 = 0x5C
        let fuHeaderStart: UInt8 = 0x85
        let d = H264RTPDepacketizer()
        _ = try d.depacketize(packet: makeRTPPacket(sequenceNumber: 1, payload: Data([fuIndicator, fuHeaderStart, 0x01])))
        #expect(throws: (any Error).self) {
            try d.depacketize(packet: self.makeRTPPacket(sequenceNumber: 3, payload: Data([fuIndicator, 0x05, 0x03])))
        }
    }

    @Test func resetClearsState() throws {
        let fuIndicator: UInt8 = 0x5C
        let fuHeaderStart: UInt8 = 0x85
        let d = H264RTPDepacketizer()
        _ = try d.depacketize(packet: makeRTPPacket(sequenceNumber: 1, payload: Data([fuIndicator, fuHeaderStart, 0x01])))
        d.reset()
        let result = try d.depacketize(packet: makeRTPPacket(sequenceNumber: 1, payload: Data([fuIndicator, fuHeaderStart | 0x40, 0xAB])))
        #expect(result.count == 1)
    }
}

// MARK: - H.264 Sample Buffer Builder

@Suite("H.264 Sample Buffer Builder")
struct H264SampleBufferBuilderTests {

    private let spsBytesBase64 = "Z0IAHqtAoEsYKDAAAAMAgAAAGXiCiAA="
    private let ppsBytesBase64 = "aM44gA=="

    private func spsData() -> Data { Data(base64Encoded: spsBytesBase64)! }
    private func ppsData() -> Data { Data(base64Encoded: ppsBytesBase64)! }

    @Test func configureFromSpropDoesNotThrow() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        try builder.configure(sps: spsData(), pps: ppsData())
        #expect(builder.hasFormatDescription)
    }

    @Test func videoDimensionsAvailableAfterConfigure() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        try builder.configure(sps: spsData(), pps: ppsData())
        let dims = try #require(builder.videoDimensions)
        #expect(dims.width > 0)
        #expect(dims.height > 0)
    }

    @Test func returnsNilBeforeFormatDescriptionAvailable() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        let sliceNAL = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, 0x00])
        let result = try builder.process(annexBChunks: [sliceNAL], rtpTimestamp: 1000)
        #expect(result == nil)
    }

    @Test func inBandParameterSetsUnblockBuilding() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        let spsNAL = Data([0x00, 0x00, 0x00, 0x01]) + spsData()
        let ppsNAL = Data([0x00, 0x00, 0x00, 0x01]) + ppsData()
        let idrNAL = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00])
        let result = try builder.process(annexBChunks: [spsNAL, ppsNAL, idrNAL], rtpTimestamp: 0)
        #expect(result != nil)
    }

    @Test func firstFrameHasZeroPresentationTime() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        try builder.configure(sps: spsData(), pps: ppsData())
        let nal = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00])
        let sb = try #require(try builder.process(annexBChunks: [nal], rtpTimestamp: 1000))
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        #expect(abs(pts) < 0.001)
    }

    @Test func timestampAdvancesWithClockRate() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        try builder.configure(sps: spsData(), pps: ppsData())
        let nal = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00])
        let sb1 = try #require(try builder.process(annexBChunks: [nal], rtpTimestamp: 1000))
        let sb2 = try #require(try builder.process(annexBChunks: [nal], rtpTimestamp: 4000))
        let pts1 = CMSampleBufferGetPresentationTimeStamp(sb1).seconds
        let pts2 = CMSampleBufferGetPresentationTimeStamp(sb2).seconds
        #expect(abs(pts1) < 0.001)
        #expect(abs(pts2 - 3000.0 / 90000.0) < 0.001)
    }

    @Test func timestampWrapAroundHandled() throws {
        let builder = H264SampleBufferBuilder(clockRate: 90000)
        try builder.configure(sps: spsData(), pps: ppsData())
        let nal = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00])
        _ = try builder.process(annexBChunks: [nal], rtpTimestamp: 0xFFFF_FF00)
        let sb = try #require(try builder.process(annexBChunks: [nal], rtpTimestamp: 0x0000_00FF))
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        #expect(abs(pts - Double(0x1FF) / 90000.0) < 0.001)
    }
}

// MARK: - RTSP Transport Header Parsing

@Suite("RTSP Transport Header")
struct RTSPTransportHeaderTests {

    @Test func parsesTCPInterleavedTransport() throws {
        let header = try RTSPTransportHeader.parse("RTP/AVP/TCP;unicast;interleaved=0-1")
        let alt = try #require(header.alternatives.first)
        #expect(alt.lowerTransport == "TCP")
        #expect(alt.interleavedChannelPair?.first == 0)
        #expect(alt.interleavedChannelPair?.second == 1)
    }

    @Test func parsesMultipleAlternatives() throws {
        let header = try RTSPTransportHeader.parse("RTP/AVP/TCP;unicast;interleaved=0-1,RTP/AVP/UDP;unicast;client_port=1234-1235")
        #expect(header.alternatives.count == 2)
        #expect(header.alternatives[0].lowerTransport == "TCP")
        #expect(header.alternatives[1].lowerTransport == "UDP")
    }

    @Test func extractsServerPort() throws {
        let header = try RTSPTransportHeader.parse("RTP/AVP;unicast;server_port=5004-5005")
        #expect(header.alternatives.first?.serverPort?.first == 5004)
        #expect(header.alternatives.first?.serverPort?.second == 5005)
    }

    @Test func handlesMissingInterleavedForTCP() throws {
        let header = try RTSPTransportHeader.parse("RTP/AVP/TCP;unicast")
        #expect(header.alternatives.count == 1)
        #expect(header.alternatives[0].interleavedChannelPair == nil)
    }
}

// MARK: - Bundled fixtures (add camera captures alongside `sample_rtsp_describe_response.txt`)

@Suite("Bundled RTSP fixtures")
struct BundledRTSPFixtureTests {

    @Test func parsesDescribeResponseFromFixtureFile() throws {
        let url = try #require(Bundle.module.url(forResource: "sample_rtsp_describe_response", withExtension: "txt"))
        let data = try Data(contentsOf: url)
        let response = try RTSPParser.parseResponse(data)
        #expect(response.statusCode == 200)
        let body = try #require(response.body)
        let bodyString = try #require(String(data: body, encoding: .utf8))
        #expect(bodyString.contains("m=video"))
        let sdp = try SDPParser.parse(bodyString)
        #expect(sdp.mediaDescriptions.contains { $0.mediaType == "video" })
    }
}
