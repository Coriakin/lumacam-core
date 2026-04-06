import Foundation

enum H264RTPDepacketizerError: Error, Equatable, Sendable {
    case unsupportedPayloadType(UInt8)
    case invalidSingleNALUnit
    case invalidSTAPA
    case invalidFUHeader
    case outOfOrderFragmentation
}

final class H264RTPDepacketizer: @unchecked Sendable {
    private static let annexBStartCode = Data([0x00, 0x00, 0x00, 0x01])

    private let expectedPayloadTypes: Set<UInt8>
    private var activeFragment: Data?
    private var activeFragmentSequenceNumber: UInt16?
    private var activeFragmentNALType: UInt8?

    init(expectedPayloadTypes: Set<UInt8> = []) {
        self.expectedPayloadTypes = expectedPayloadTypes
    }

    func reset() {
        activeFragment = nil
        activeFragmentSequenceNumber = nil
        activeFragmentNALType = nil
    }

    func depacketize(packet: RTPPacket) throws -> [Data] {
        if !expectedPayloadTypes.isEmpty, !expectedPayloadTypes.contains(packet.payloadType) {
            throw H264RTPDepacketizerError.unsupportedPayloadType(packet.payloadType)
        }

        guard let nalType = packet.payload.first.map({ $0 & 0x1F }) else {
            return []
        }

        switch nalType {
        case 1...23:
            return [annexBChunk(from: packet.payload)]
        case 24:
            return try depacketizeSTAPA(packet.payload)
        case 28:
            return try depacketizeFUA(packet: packet)
        case 25, 26, 27, 29, 30, 31:
            throw H264RTPDepacketizerError.invalidSingleNALUnit
        default:
            throw H264RTPDepacketizerError.invalidSingleNALUnit
        }
    }

    private func depacketizeSTAPA(_ payload: Data) throws -> [Data] {
        var offset = 1
        var nalUnits: [Data] = []

        while offset + 2 <= payload.count {
            let nalLength = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2

            guard nalLength > 0, offset + nalLength <= payload.count else {
                throw H264RTPDepacketizerError.invalidSTAPA
            }

            let nalUnit = payload[offset..<(offset + nalLength)]
            nalUnits.append(annexBChunk(from: Data(nalUnit)))
            offset += nalLength
        }

        guard offset == payload.count else {
            throw H264RTPDepacketizerError.invalidSTAPA
        }

        return nalUnits
    }

    private func depacketizeFUA(packet: RTPPacket) throws -> [Data] {
        guard packet.payload.count >= 2 else {
            throw H264RTPDepacketizerError.invalidFUHeader
        }

        let fuIndicator = packet.payload[0]
        let fuHeader = packet.payload[1]
        let start = (fuHeader & 0x80) != 0
        let end = (fuHeader & 0x40) != 0
        let reconstructedNALType = fuHeader & 0x1F
        let nalRefIdc = fuIndicator & 0x60
        let nalHeader = nalRefIdc | reconstructedNALType
        let fragmentPayload = packet.payload.dropFirst(2)

        if start {
            if activeFragment != nil {
                reset()
            }

            activeFragment = Data(Self.annexBStartCode)
            activeFragment?.append(nalHeader)
            activeFragment?.append(contentsOf: fragmentPayload)
            activeFragmentSequenceNumber = packet.sequenceNumber
            activeFragmentNALType = reconstructedNALType

            if end {
                let complete = activeFragment ?? Data()
                reset()
                return [complete]
            }

            return []
        }

        guard var fragment = activeFragment, let expectedType = activeFragmentNALType, expectedType == reconstructedNALType else {
            throw H264RTPDepacketizerError.outOfOrderFragmentation
        }

        if let previousSequenceNumber = activeFragmentSequenceNumber {
            let expectedSequenceNumber = previousSequenceNumber &+ 1
            if expectedSequenceNumber != packet.sequenceNumber {
                reset()
                throw H264RTPDepacketizerError.outOfOrderFragmentation
            }
        }

        fragment.append(contentsOf: fragmentPayload)
        activeFragment = fragment
        activeFragmentSequenceNumber = packet.sequenceNumber

        if end {
            let complete = fragment
            reset()
            return [complete]
        }

        return []
    }

    private func annexBChunk(from nalUnit: Data) -> Data {
        var chunk = Self.annexBStartCode
        chunk.append(contentsOf: nalUnit)
        return chunk
    }
}
