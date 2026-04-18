import Foundation

/// Engines that deliver decoded video to a display surface can conform to expose when the last sample was enqueued.
///
/// Used for stall detection: if playback state is `.playing` but this clock stops advancing, the stream may be frozen.
@MainActor
public protocol PlaybackFrameActivityReporting: AnyObject {
    /// Wall-clock time of the last video sample handed to the display pipeline.
    /// `nil` when idle, not yet applicable, or the engine does not track frame delivery.
    var lastVideoFrameWallClock: Date? { get }
}
