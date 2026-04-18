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
