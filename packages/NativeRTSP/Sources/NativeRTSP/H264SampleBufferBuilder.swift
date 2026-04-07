import CoreMedia
import VideoToolbox

enum H264SampleBufferBuilderError: Error, Sendable {
    case missingFormatDescription
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case emptyAccessUnit
}

/// Converts H.264 Annex-B NALU chunks from the depacketizer into CMSampleBuffers
/// suitable for enqueuing to an AVSampleBufferDisplayLayer.
///
/// Thread-affinity: use from a single task/thread; not thread-safe.
final class H264SampleBufferBuilder {

    private let clockRate: Int
    private var formatDescription: CMVideoFormatDescription?
    private var rtpBaseTimestamp: UInt32?

    // In-band parameter sets accumulated before format description is built
    private var pendingSPS: Data?
    private var pendingPPS: Data?

    init(clockRate: Int) {
        self.clockRate = clockRate
    }

    var hasFormatDescription: Bool { formatDescription != nil }

    /// Clear accumulated state. Call on reconnect/stream switch, or when the downstream
    /// renderer/decoder is flushed so timestamps and parameter sets don't carry over.
    func reset() {
        formatDescription = nil
        rtpBaseTimestamp = nil
        pendingSPS = nil
        pendingPPS = nil
    }

    /// Pre-configure from out-of-band SPS/PPS (e.g. sprop-parameter-sets from SDP).
    /// Throws if the data is unusable, but the builder remains usable; it will try
    /// again when in-band parameter sets arrive.
    func configure(sps: Data, pps: Data) throws {
        formatDescription = try makeFormatDescription(sps: sps, pps: pps)
    }

    /// Process one H.264 access unit (one or more Annex-B NALU chunks from the depacketizer).
    ///
    /// - Scans for in-band SPS (type 7) and PPS (type 8) and updates the format description.
    /// - Returns a CMSampleBuffer when a format description is available and there are
    ///   decodable NALUs in the access unit. Returns nil while waiting for parameter sets.
    func process(annexBChunks: [Data], rtpTimestamp: UInt32) throws -> CMSampleBuffer? {
        var videoChunks: [Data] = []

        for chunk in annexBChunks {
            let raw = stripAnnexBStartCode(from: chunk)
            guard !raw.isEmpty else { continue }
            let nalType = raw[raw.startIndex] & 0x1F
            switch nalType {
            case 7:
                pendingSPS = Data(raw)
            case 8:
                pendingPPS = Data(raw)
            default:
                videoChunks.append(chunk)
            }
        }

        // Try to build or refresh format description from accumulated in-band parameter sets
        if pendingSPS != nil || pendingPPS != nil {
            tryRefreshFormatDescription()
        }

        guard let formatDescription, !videoChunks.isEmpty else {
            return nil
        }

        let presentationTime = makePresentationTime(rtpTimestamp: rtpTimestamp)
        let avccData = try convertToAVCC(annexBChunks: videoChunks)
        return try makeSampleBuffer(
            avccData: avccData,
            formatDescription: formatDescription,
            presentationTime: presentationTime
        )
    }

    /// Returns the video dimensions from the current format description, if available.
    var videoDimensions: CMVideoDimensions? {
        formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
    }

    // MARK: - Private

    private func tryRefreshFormatDescription() {
        guard let sps = pendingSPS, let pps = pendingPPS else { return }
        if let desc = try? makeFormatDescription(sps: sps, pps: pps) {
            formatDescription = desc
            pendingSPS = nil
            pendingPPS = nil
        }
    }

    private func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        let rawSPS = stripAnnexBStartCode(from: sps)
        let rawPPS = stripAnnexBStartCode(from: pps)
        return try rawSPS.withUnsafeBytes { spsPtr in
            try rawPPS.withUnsafeBytes { ppsPtr in
                guard
                    let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    throw H264SampleBufferBuilderError.missingFormatDescription
                }
                let ptrs: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [rawSPS.count, rawPPS.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
                guard status == noErr, let desc else {
                    throw H264SampleBufferBuilderError.missingFormatDescription
                }
                return desc
            }
        }
    }

    private func convertToAVCC(annexBChunks: [Data]) throws -> Data {
        let strippedChunks = annexBChunks.map { stripAnnexBStartCode(from: $0) }.filter { !$0.isEmpty }

        var result = Data()
        result.reserveCapacity(strippedChunks.reduce(0) { $0 + 4 + $1.count })
        for raw in strippedChunks {
            var length = UInt32(raw.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(contentsOf: raw)
        }
        guard !result.isEmpty else {
            throw H264SampleBufferBuilderError.emptyAccessUnit
        }
        return result
    }

    private func stripAnnexBStartCode(from data: Data) -> Data {
        let s = data.startIndex
        if data.count >= 4,
           data[s] == 0x00, data[s + 1] == 0x00,
           data[s + 2] == 0x00, data[s + 3] == 0x01 {
            return data[(s + 4)...]
        }
        if data.count >= 3,
           data[s] == 0x00, data[s + 1] == 0x00,
           data[s + 2] == 0x01 {
            return data[(s + 3)...]
        }
        return data
    }

    private func makePresentationTime(rtpTimestamp: UInt32) -> CMTime {
        let timescale = CMTimeScale(clockRate)
        guard let base = rtpBaseTimestamp else {
            rtpBaseTimestamp = rtpTimestamp
            return .zero
        }
        // UInt32 wrap-around subtraction gives correct delta even across the 32-bit rollover
        let deltaTicks = Int64(rtpTimestamp &- base)
        return CMTime(value: deltaTicks, timescale: timescale)
    }

    private func makeSampleBuffer(
        avccData: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let count = avccData.count

        // Allocate a CoreMedia-owned block and copy the AVCC data into it.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw H264SampleBufferBuilderError.blockBufferCreationFailed(status)
        }

        status = avccData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw H264SampleBufferBuilderError.blockBufferCreationFailed(status)
        }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [count],
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw H264SampleBufferBuilderError.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }
}
