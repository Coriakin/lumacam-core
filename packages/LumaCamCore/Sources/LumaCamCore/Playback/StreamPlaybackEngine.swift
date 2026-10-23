import Foundation

@MainActor
public protocol StreamPlaybackEngine: AnyObject {
    var onStateChange: ((StreamPlaybackState) -> Void)? { get set }
    var onStatisticsChange: ((PlaybackStatistics?) -> Void)? { get set }

    func prepare(endpoint: CameraEndpoint) throws
    func start()
    func stop()
    func setVisible(_ isVisible: Bool)
}

/// Optional capability for live engines that can enable/disable audio.
/// For RTSP, toggling audio typically requires reconnecting so the control plane can SETUP/skip audio tracks.
@MainActor
public protocol AudioConfigurableStreamPlaybackEngine: StreamPlaybackEngine {
    func setAudioEnabled(_ enabled: Bool)
}

/// Optional capability for engines that can adjust audio output volume.
@MainActor
public protocol AudioVolumeConfigurableStreamPlaybackEngine: StreamPlaybackEngine {
    /// Volume scalar in 0...1.
    func setAudioVolume(_ volume01: Float)
}

/// Optional capability for engines that can report current audio activity level.
@MainActor
public protocol AudioActivityReporting: AnyObject {
    /// Smoothed audio energy level in 0...1. (0 = silence)
    var audioLevel01: Float { get }
    /// Most recent wall-clock time we detected meaningful audio energy.
    var lastAudioActivity: Date? { get }
}

public struct AudioDebugSnapshot: Equatable, Sendable {
    public var codecName: String?
    public var hasSeenAudioRtp: Bool
    public var lastAudioRtpWallClock: Date?
    public var isPlayoutRunning: Bool
    public var playoutStartWallClock: Date?

    public init(
        codecName: String? = nil,
        hasSeenAudioRtp: Bool = false,
        lastAudioRtpWallClock: Date? = nil,
        isPlayoutRunning: Bool = false,
        playoutStartWallClock: Date? = nil
    ) {
        self.codecName = codecName
        self.hasSeenAudioRtp = hasSeenAudioRtp
        self.lastAudioRtpWallClock = lastAudioRtpWallClock
        self.isPlayoutRunning = isPlayoutRunning
        self.playoutStartWallClock = playoutStartWallClock
    }
}

/// Optional capability for engines to report audio pipeline state useful for diagnostics UI.
@MainActor
public protocol AudioDebugReporting: AnyObject {
    var audioDebugSnapshot: AudioDebugSnapshot? { get }
}
