import XCTest
@testable import LumaCamCore

final class ONVIFZoomTests: XCTestCase {
    func testDiscoveryQueriesSelectedPTZConfiguration() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ZoomDiscoveryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ONVIFPTZClient(urlSession: session)
        let camera = CameraProfile(
            endpoint: CameraEndpoint(displayName: "Fixture", host: "camera.invalid", path: "/stream", username: "viewer", resolvedPassword: "fixture"),
            ptz: PTZConfiguration(backend: .onvif)
        )
        let supported = try await client.supportsContinuousZoom(profile: camera)
        XCTAssertTrue(supported)
    }

    func testOldCameraConfigurationDefaultsToAutomatic() throws {
        let config = try JSONDecoder().decode(PTZConfiguration.self, from: Data(#"{"backend":"onvif"}"#.utf8))
        XCTAssertEqual(config.zoomMode, .automatic)
    }

    func testZoomOverridesRoundTrip() throws {
        for mode in PTZZoomMode.allCases {
            let config = PTZConfiguration(backend: .onvif, zoomMode: mode)
            XCTAssertEqual(try JSONDecoder().decode(PTZConfiguration.self, from: JSONEncoder().encode(config)), config)
        }
    }

    func testConfigurationTokenBelongsToSelectedProfile() throws {
        let xml = """
        <m:GetProfilesResponse xmlns:m="http://www.onvif.org/ver10/media/wsdl" xmlns:t="http://www.onvif.org/ver10/schema">
          <m:Profiles token="fixed"><t:Name>Fixed</t:Name></m:Profiles>
          <m:Profiles token="other"><t:PTZConfiguration token="wrong"/></m:Profiles>
          <m:Profiles token="selected"><t:PTZConfiguration token="zoom&amp;pan"/></m:Profiles>
        </m:GetProfilesResponse>
        """
        XCTAssertEqual(try ONVIFZoomCapabilityParsing.configurationToken(Data(xml.utf8), profileToken: "selected"), "zoom&pan")
        XCTAssertNil(try ONVIFZoomCapabilityParsing.configurationToken(Data(xml.utf8), profileToken: "fixed"))
        XCTAssertNil(try ONVIFZoomCapabilityParsing.configurationToken(Data(xml.utf8), profileToken: "missing"))
    }

    func testContinuousZoomSupported() throws {
        XCTAssertTrue(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options(zoomSpace())))
    }

    func testPanTiltOnlyAndAbsoluteZoomDoNotEnableContinuousZoom() throws {
        XCTAssertFalse(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options("<t:ContinuousPanTiltVelocitySpace/>")))
        XCTAssertFalse(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options(zoomSpace().replacingOccurrences(of: "ContinuousZoomVelocitySpace", with: "AbsoluteZoomPositionSpace"))))
    }

    func testEmptyAndIncompatibleZoomSpacesDoNotEnableZoom() throws {
        XCTAssertFalse(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options("<t:ContinuousZoomVelocitySpace/>")))
        XCTAssertFalse(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options(zoomSpace(min: "0", max: "0"))))
        XCTAssertFalse(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options(zoomSpace(min: "-0.1", max: "0.1"))))
        XCTAssertFalse(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(options(zoomSpace().replacingOccurrences(of: "VelocityGenericSpace", with: "VendorSpace"))))
    }

    func testMalformedOrFaultResponsesAreUnknownNotUnsupported() {
        for xml in ["broken", "<GetConfigurationOptionsResponse/>", "<Fault/>"] {
            XCTAssertThrowsError(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(Data(xml.utf8)))
        }
    }

    func testNamespacePrefixesDoNotAffectDetection() throws {
        let xml = String(decoding: options(zoomSpace()), as: UTF8.self)
            .replacingOccurrences(of: "t:", with: "schema:")
            .replacingOccurrences(of: "xmlns:t=", with: "xmlns:schema=")
        XCTAssertTrue(try ONVIFZoomCapabilityParsing.supportsContinuousZoom(Data(xml.utf8)))
    }

    private func options(_ spaces: String) -> Data {
        Data("""
        <p:GetConfigurationOptionsResponse xmlns:p="http://www.onvif.org/ver20/ptz/wsdl" xmlns:t="http://www.onvif.org/ver10/schema">
          <p:PTZConfigurationOptions><t:Spaces>\(spaces)</t:Spaces></p:PTZConfigurationOptions>
        </p:GetConfigurationOptionsResponse>
        """.utf8)
    }

    private func zoomSpace(min: String = "-1", max: String = "1") -> String {
        """
        <t:ContinuousZoomVelocitySpace>
          <t:URI>http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace</t:URI>
          <t:XRange><t:Min>\(min)</t:Min><t:Max>\(max)</t:Max></t:XRange>
        </t:ContinuousZoomVelocitySpace>
        """
    }
}

/// Exercises real discovery and authenticated SOAP construction without contacting a camera.
private final class ZoomDiscoveryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        let action = request.value(forHTTPHeaderField: "SOAPAction") ?? ""
        let body: String
        if action.hasSuffix("GetCapabilities") {
            body = """
            <tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
            <tds:Capabilities><tt:Media><tt:XAddr>http://camera.invalid/media</tt:XAddr></tt:Media>
            <tt:PTZ><tt:XAddr>http://camera.invalid/ptz</tt:XAddr></tt:PTZ></tds:Capabilities>
            </tds:GetCapabilitiesResponse>
            """
        } else if action.hasSuffix("GetProfiles") {
            // First profile is fixed; discovery must choose the second PTZ profile.
            body = """
            <m:GetProfilesResponse xmlns:m="http://www.onvif.org/ver10/media/wsdl" xmlns:t="http://www.onvif.org/ver10/schema">
            <m:Profiles token="fixed"><t:Name>Fixed</t:Name></m:Profiles>
            <m:Profiles token="movable"><t:PTZConfiguration token="configuration"/></m:Profiles>
            </m:GetProfilesResponse>
            """
        } else if action.hasSuffix("GetConfigurationOptions") {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            guard String(decoding: data, as: UTF8.self).contains("<tptz:ConfigurationToken>configuration</tptz:ConfigurationToken>") else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            body = """
            <p:GetConfigurationOptionsResponse xmlns:p="http://www.onvif.org/ver20/ptz/wsdl" xmlns:t="http://www.onvif.org/ver10/schema">
            <p:PTZConfigurationOptions><t:Spaces><t:ContinuousZoomVelocitySpace>
            <t:URI>http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace</t:URI>
            <t:XRange><t:Min>-1</t:Min><t:Max>1</t:Max></t:XRange>
            </t:ContinuousZoomVelocitySpace></t:Spaces></p:PTZConfigurationOptions></p:GetConfigurationOptionsResponse>
            """
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
