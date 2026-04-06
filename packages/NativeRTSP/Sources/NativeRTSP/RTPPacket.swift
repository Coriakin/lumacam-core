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

        let bytes = [UInt8](data)
        guard bytes.count >= 12 else {
            throw RTPPacketError.truncatedHeader
        }

        let firstByte = bytes[0]
        let secondByte = bytes[1]

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

        guard bytes.count >= offset + (csrcCount * 4) else {
            throw RTPPacketError.truncatedCSRCList
        }

        var csrcIdentifiers: [UInt32] = []
        csrcIdentifiers.reserveCapacity(csrcCount)
        for _ in 0..<csrcCount {
            let identifier = Self.readUInt32(bytes, at: offset)
            csrcIdentifiers.append(identifier)
            offset += 4
        }

        var extensionProfile: UInt16?
        var extensionData: Data?
        if extensionPresent {
            guard bytes.count >= offset + 4 else {
                throw RTPPacketError.truncatedExtensionHeader
            }

            let profile = Self.readUInt16(bytes, at: offset)
            let extensionLengthWords = Int(Self.readUInt16(bytes, at: offset + 2))
            offset += 4

            let extensionLengthBytes = extensionLengthWords * 4
            guard bytes.count >= offset + extensionLengthBytes else {
                throw RTPPacketError.truncatedExtensionPayload
            }

            extensionProfile = profile
            extensionData = Data(bytes[offset..<(offset + extensionLengthBytes)])
            offset += extensionLengthBytes
        }

        var paddingCount: UInt8 = 0
        if padding {
            guard let lastByte = bytes.last else {
                throw RTPPacketError.truncatedPadding
            }
            paddingCount = lastByte
            guard paddingCount > 0, Int(paddingCount) <= bytes.count, offset <= bytes.count - Int(paddingCount) else {
                throw RTPPacketError.truncatedPadding
            }
        } else {
            guard offset <= bytes.count else {
                throw RTPPacketError.truncatedHeader
            }
        }

        let payloadEnd = padding ? bytes.count - Int(paddingCount) : bytes.count
        guard offset <= payloadEnd else {
            throw RTPPacketError.truncatedHeader
        }

        self.version = version
        isPadding = padding
        hasExtension = extensionPresent
        self.marker = marker
        self.payloadType = payloadType
        sequenceNumber = Self.readUInt16(bytes, at: 2)
        timestamp = Self.readUInt32(bytes, at: 4)
        ssrc = Self.readUInt32(bytes, at: 8)
        self.csrcIdentifiers = csrcIdentifiers
        self.extensionProfile = extensionProfile
        self.extensionData = extensionData
        payload = Data(bytes[offset..<payloadEnd])
        self.paddingCount = paddingCount
    }

    var payloadLength: Int {
        payload.count
    }

    private static func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }
}
