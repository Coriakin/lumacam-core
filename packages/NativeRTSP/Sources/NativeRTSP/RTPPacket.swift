import Foundation

enum RTPPacketError: Error, Equatable, Sendable {
    case emptyPacket
    case unsupportedVersion(UInt8)
    case truncatedHeader
    case truncatedCSRCList
    case truncatedExtensionHeader
    case truncatedExtensionPayload
    case truncatedPadding
}

struct RTPPacket: Sendable, Equatable {
    static let headerVersion: UInt8 = 2

    let version: UInt8
    let isPadding: Bool
    let hasExtension: Bool
    let marker: Bool
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let csrcIdentifiers: [UInt32]
    let extensionProfile: UInt16?
    let extensionData: Data?
    let payload: Data
    let paddingCount: UInt8

    init(data: Data) throws {
        guard !data.isEmpty else {
            throw RTPPacketError.emptyPacket
        }

        guard data.count >= 12 else {
            throw RTPPacketError.truncatedHeader
        }

        let firstByte = data[data.startIndex]
        let secondByte = data[data.index(after: data.startIndex)]

        let version = firstByte >> 6
        guard version == Self.headerVersion else {
            throw RTPPacketError.unsupportedVersion(version)
        }

        let padding = (firstByte & 0x20) != 0
        let extensionPresent = (firstByte & 0x10) != 0
        let csrcCount = Int(firstByte & 0x0F)
        let marker = (secondByte & 0x80) != 0
        let payloadType = secondByte & 0x7F

        var offset = 12

        guard data.count >= offset + (csrcCount * 4) else {
            throw RTPPacketError.truncatedCSRCList
        }

        var csrcIdentifiers: [UInt32] = []
        csrcIdentifiers.reserveCapacity(csrcCount)
        for _ in 0..<csrcCount {
            let identifier = Self.readUInt32(data, at: offset)
            csrcIdentifiers.append(identifier)
            offset += 4
        }

        var extensionProfile: UInt16?
        var extensionData: Data?
        if extensionPresent {
            guard data.count >= offset + 4 else {
                throw RTPPacketError.truncatedExtensionHeader
            }

            let profile = Self.readUInt16(data, at: offset)
            let extensionLengthWords = Int(Self.readUInt16(data, at: offset + 2))
            offset += 4

            let extensionLengthBytes = extensionLengthWords * 4
            guard data.count >= offset + extensionLengthBytes else {
                throw RTPPacketError.truncatedExtensionPayload
            }

            extensionProfile = profile
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: extensionLengthBytes)
            extensionData = Data(data[start..<end])
            offset += extensionLengthBytes
        }

        var paddingCount: UInt8 = 0
        if padding {
            paddingCount = data[data.index(before: data.endIndex)]
            guard paddingCount > 0, Int(paddingCount) <= data.count, offset <= data.count - Int(paddingCount) else {
                throw RTPPacketError.truncatedPadding
            }
        } else {
            guard offset <= data.count else {
                throw RTPPacketError.truncatedHeader
            }
        }

        let payloadEnd = padding ? data.count - Int(paddingCount) : data.count
        guard offset <= payloadEnd else {
            throw RTPPacketError.truncatedHeader
        }

        self.version = version
        isPadding = padding
        hasExtension = extensionPresent
        self.marker = marker
        self.payloadType = payloadType
        sequenceNumber = Self.readUInt16(data, at: 2)
        timestamp = Self.readUInt32(data, at: 4)
        ssrc = Self.readUInt32(data, at: 8)
        self.csrcIdentifiers = csrcIdentifiers
        self.extensionProfile = extensionProfile
        self.extensionData = extensionData
        if offset == payloadEnd {
            payload = Data()
        } else {
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(data.startIndex, offsetBy: payloadEnd)
            payload = Data(data[start..<end])
        }
        self.paddingCount = paddingCount
    }

    var payloadLength: Int {
        payload.count
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        let i = data.index(data.startIndex, offsetBy: index)
        let j = data.index(after: i)
        return (UInt16(data[i]) << 8) | UInt16(data[j])
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        let i0 = data.index(data.startIndex, offsetBy: index)
        let i1 = data.index(i0, offsetBy: 1)
        let i2 = data.index(i0, offsetBy: 2)
        let i3 = data.index(i0, offsetBy: 3)
        return (UInt32(data[i0]) << 24)
            | (UInt32(data[i1]) << 16)
            | (UInt32(data[i2]) << 8)
            | UInt32(data[i3])
    }
}
