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
