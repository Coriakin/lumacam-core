import Foundation

public struct SDPSessionDescription: Sendable, Equatable {
    public var version: String?
    public var origin: SDPOrigin?
    public var sessionName: String?
    public var sessionInformation: String?
    public var uri: String?
    public var email: String?
    public var phone: String?
    public var connection: SDPConnectionInformation?
    public var bandwidths: [SDPBandwidth]
    public var timeRanges: [SDPTimeRange]
    public var attributes: [SDPAttribute]
    public var mediaDescriptions: [SDPMediaDescription]

    public init(
        version: String? = nil,
        origin: SDPOrigin? = nil,
        sessionName: String? = nil,
        sessionInformation: String? = nil,
        uri: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        connection: SDPConnectionInformation? = nil,
        bandwidths: [SDPBandwidth] = [],
        timeRanges: [SDPTimeRange] = [],
        attributes: [SDPAttribute] = [],
        mediaDescriptions: [SDPMediaDescription] = []
    ) {
        self.version = version
        self.origin = origin
        self.sessionName = sessionName
        self.sessionInformation = sessionInformation
        self.uri = uri
        self.email = email
        self.phone = phone
        self.connection = connection
        self.bandwidths = bandwidths
        self.timeRanges = timeRanges
        self.attributes = attributes
        self.mediaDescriptions = mediaDescriptions
    }

    public var controlAttribute: String? {
        attributes.last { $0.name.caseInsensitiveCompare("control") == .orderedSame }?.value
    }
}

public struct SDPOrigin: Sendable, Equatable {
    public var username: String
    public var sessionID: String
    public var sessionVersion: String
    public var networkType: String
    public var addressType: String
    public var unicastAddress: String

    public init(
        username: String,
        sessionID: String,
        sessionVersion: String,
        networkType: String,
        addressType: String,
        unicastAddress: String
    ) {
        self.username = username
        self.sessionID = sessionID
        self.sessionVersion = sessionVersion
        self.networkType = networkType
        self.addressType = addressType
        self.unicastAddress = unicastAddress
    }
}

public struct SDPConnectionInformation: Sendable, Equatable {
    public var networkType: String
    public var addressType: String
    public var address: String

    public init(networkType: String, addressType: String, address: String) {
        self.networkType = networkType
        self.addressType = addressType
        self.address = address
    }
}

public struct SDPBandwidth: Sendable, Equatable {
    public var type: String
    public var value: UInt64

    public init(type: String, value: UInt64) {
        self.type = type
        self.value = value
    }
}

public struct SDPTimeRange: Sendable, Equatable {
    public var startTime: UInt64
    public var stopTime: UInt64
    public var repeatTimes: [SDPRepeatTime]

    public init(startTime: UInt64, stopTime: UInt64, repeatTimes: [SDPRepeatTime] = []) {
        self.startTime = startTime
        self.stopTime = stopTime
        self.repeatTimes = repeatTimes
    }
}

public struct SDPRepeatTime: Sendable, Equatable {
    public var interval: UInt64
    public var duration: UInt64
    public var offsets: [UInt64]

    public init(interval: UInt64, duration: UInt64, offsets: [UInt64] = []) {
        self.interval = interval
        self.duration = duration
        self.offsets = offsets
    }
}

public struct SDPAttribute: Sendable, Equatable {
    public var name: String
    public var value: String?

    public init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }
}

public struct SDPRTPMapAttribute: Sendable, Equatable {
    public var payloadType: String
    public var encodingName: String
    public var clockRate: Int
    public var encodingParameters: String?

    public init(
        payloadType: String,
        encodingName: String,
        clockRate: Int,
        encodingParameters: String? = nil
    ) {
        self.payloadType = payloadType
        self.encodingName = encodingName
        self.clockRate = clockRate
        self.encodingParameters = encodingParameters
    }
}

public struct SDPFmtpAttribute: Sendable, Equatable {
    public var payloadType: String
    public var parameters: String

    public init(payloadType: String, parameters: String) {
        self.payloadType = payloadType
        self.parameters = parameters
    }
}

public struct SDPMediaDescription: Sendable, Equatable {
    public var mediaType: String
    public var port: UInt16
    public var portCount: UInt16?
    public var transportProtocol: String
    public var formats: [String]
    public var information: String?
    public var connection: SDPConnectionInformation?
    public var bandwidths: [SDPBandwidth]
    public var attributes: [SDPAttribute]
    public var rtpMaps: [SDPRTPMapAttribute]
    public var fmtpAttributes: [SDPFmtpAttribute]

    public init(
        mediaType: String,
        port: UInt16,
        portCount: UInt16? = nil,
        transportProtocol: String,
        formats: [String] = [],
        information: String? = nil,
        connection: SDPConnectionInformation? = nil,
        bandwidths: [SDPBandwidth] = [],
        attributes: [SDPAttribute] = [],
        rtpMaps: [SDPRTPMapAttribute] = [],
        fmtpAttributes: [SDPFmtpAttribute] = []
    ) {
        self.mediaType = mediaType
        self.port = port
        self.portCount = portCount
        self.transportProtocol = transportProtocol
        self.formats = formats
        self.information = information
        self.connection = connection
        self.bandwidths = bandwidths
        self.attributes = attributes
        self.rtpMaps = rtpMaps
        self.fmtpAttributes = fmtpAttributes
    }

    public var controlAttribute: String? {
        attributes.first { $0.name.caseInsensitiveCompare("control") == .orderedSame }?.value
    }

    public var isVideo: Bool {
        mediaType.caseInsensitiveCompare("video") == .orderedSame
    }

    public func rtpMap(for payloadType: String) -> SDPRTPMapAttribute? {
        rtpMaps.first { $0.payloadType == payloadType }
    }

    public func fmtp(for payloadType: String) -> SDPFmtpAttribute? {
        fmtpAttributes.first { $0.payloadType == payloadType }
    }
}
