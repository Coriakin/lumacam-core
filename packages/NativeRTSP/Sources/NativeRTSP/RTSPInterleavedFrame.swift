import Foundation

public struct RTSPInterleavedFrame: Sendable, Equatable {
    public let channel: UInt8
    public let payload: Data

    public init(channel: UInt8, payload: Data) {
        self.channel = channel
        self.payload = payload
    }

    public var encodedLength: Int {
        4 + payload.count
    }
}

public enum RTSPInterleavedFrameParserError: Error, Equatable, Sendable {
    case invalidPrefix(UInt8)
    case truncatedHeader
    case truncatedPayload(expected: Int, available: Int)
}

public enum RTSPInterleavedFrameParseResult: Sendable, Equatable {
    case complete(frame: RTSPInterleavedFrame, consumedBytes: Int)
    case incomplete(requiredBytes: Int, availableBytes: Int)
    case invalid(RTSPInterleavedFrameParserError)
}

public enum RTSPInterleavedFrameParser {
    public static func parse(from buffer: Data) -> RTSPInterleavedFrameParseResult {
        guard !buffer.isEmpty else {
            return .incomplete(requiredBytes: 1, availableBytes: 0)
        }

        guard buffer[buffer.startIndex] == 0x24 else {
            return .invalid(.invalidPrefix(buffer[buffer.startIndex]))
        }

        guard buffer.count >= 4 else {
            return .incomplete(requiredBytes: 4, availableBytes: buffer.count)
        }

        let channelIndex = buffer.index(after: buffer.startIndex)
        let lengthHighIndex = buffer.index(channelIndex, offsetBy: 1)
        let lengthLowIndex = buffer.index(channelIndex, offsetBy: 2)

        let channel = buffer[channelIndex]
        let payloadLength = Int(buffer[lengthHighIndex]) << 8 | Int(buffer[lengthLowIndex])
        let totalLength = 4 + payloadLength

        guard buffer.count >= totalLength else {
            return .incomplete(requiredBytes: totalLength, availableBytes: buffer.count)
        }

        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
        let payloadEnd = buffer.index(payloadStart, offsetBy: payloadLength)
        let payload = Data(buffer[payloadStart..<payloadEnd])

        return .complete(
            frame: RTSPInterleavedFrame(channel: channel, payload: payload),
            consumedBytes: totalLength
        )
    }
}
