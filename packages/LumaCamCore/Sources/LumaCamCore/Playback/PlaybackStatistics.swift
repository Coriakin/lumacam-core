import Foundation

public struct PlaybackStatistics: Equatable, Sendable {
    public var resolutionDescription: String?
    public var codecDescription: String?
    public var latencyEstimateMilliseconds: Int?
    public var droppedFrameCount: Int?

    public init(
        resolutionDescription: String? = nil,
        codecDescription: String? = nil,
        latencyEstimateMilliseconds: Int? = nil,
        droppedFrameCount: Int? = nil
    ) {
        self.resolutionDescription = resolutionDescription
        self.codecDescription = codecDescription
        self.latencyEstimateMilliseconds = latencyEstimateMilliseconds
        self.droppedFrameCount = droppedFrameCount
    }
}
