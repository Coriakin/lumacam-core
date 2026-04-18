import Foundation
import Observation

@MainActor
@Observable
public final class CameraSession {
    public let profile: CameraProfile
    public let engine: any StreamPlaybackEngine

    public private(set) var state: StreamPlaybackState = .idle
    public private(set) var statistics: PlaybackStatistics?
    public private(set) var lastError: PlaybackError?
    public private(set) var isVisible = false
    public private(set) var isAudioEnabled = false
    /// True when `.playing` but no new video frames have reached the display pipeline for `videoStallThreshold`.
    public private(set) var isVideoStallSuspected = false

    private let reconnectPolicy: ReconnectPolicy
    private let connectionTimeout: Duration
    /// No new `lastVideoFrameWallClock` for this long while `.playing` ⇒ treat as stalled (if the engine reports a clock).
    private let videoStallThreshold: Duration
    private let stallPollInterval: Duration
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var stallMonitorTask: Task<Void, Never>?
    private var isUserInitiatedConnection = false
    private var reconnectAttempt = 0
    private var ignoreNextStop = false
    private var connectionGeneration = 0
    private let sessionID = UUID()

    public init(
        profile: CameraProfile,
        engine: any StreamPlaybackEngine,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        connectionTimeout: Duration = .seconds(10),
        videoStallThreshold: Duration = .seconds(5),
        stallPollInterval: Duration = .milliseconds(500)
    ) {
        self.profile = profile
        self.engine = engine
        self.reconnectPolicy = reconnectPolicy
        self.connectionTimeout = connectionTimeout
        self.videoStallThreshold = videoStallThreshold
        self.stallPollInterval = stallPollInterval

        LumaCamDiagnostics.log(
            "session created session=\(sessionID.uuidString.lowercased()) \(profile.diagnosticsSummary)",
            level: .debug,
            category: "session",
            cameraID: profile.id
        )

        engine.onStateChange = { [weak self] newState in
            self?.handleEngineStateChange(newState)
        }

        engine.onStatisticsChange = { [weak self] statistics in
            self?.handleStatisticsChange(statistics)
        }
    }

    /// Enable/disable audio for this session (defaults to `false`).
    ///
    /// If the session is currently user-connected and visible, this triggers a reconnect so the
    /// underlying RTSP control plane can negotiate audio tracks (or skip them entirely).
    public func setAudioEnabled(_ enabled: Bool) {
        guard isAudioEnabled != enabled else { return }
        isAudioEnabled = enabled

        if let audioEngine = engine as? AudioConfigurableStreamPlaybackEngine {
            audioEngine.setAudioEnabled(enabled)
        }

        guard isUserInitiatedConnection, isVisible else { return }

        LumaCamDiagnostics.log(
            "audio toggle changed; reconnecting session=\(sessionID.uuidString.lowercased()) enabled=\(enabled)",
            level: .debug,
            category: "session",
            cameraID: profile.id
        )

        reconnectTask?.cancel()
        connectionTimeoutTask?.cancel()
        stopStallMonitoring()
        reconnectAttempt = 0
        ignoreNextStop = true
        engine.stop()
        startEngine()
    }

    public func connect() {
        LumaCamDiagnostics.log(
            "connect requested session=\(sessionID.uuidString.lowercased()) visible=\(isVisible) state=\(state.diagnosticsSummary)",
            category: "session",
            cameraID: profile.id
        )
        reconnectTask?.cancel()
        connectionTimeoutTask?.cancel()
        stopStallMonitoring()
        reconnectAttempt = 0
        isUserInitiatedConnection = true
        startEngine()
    }

    public func disconnect() {
        LumaCamDiagnostics.log(
            "disconnect requested session=\(sessionID.uuidString.lowercased()) visible=\(isVisible) state=\(state.diagnosticsSummary)",
            category: "session",
            cameraID: profile.id
        )
        reconnectTask?.cancel()
        connectionTimeoutTask?.cancel()
        stopStallMonitoring()
        isUserInitiatedConnection = false
        ignoreNextStop = true
        engine.stop()
        state = .stopped
    }

    public func setVisible(_ visible: Bool) {
        LumaCamDiagnostics.log(
            "visibility changed session=\(sessionID.uuidString.lowercased()) visible=\(visible)",
            level: .debug,
            category: "session",
            cameraID: profile.id
        )
        isVisible = visible
        engine.setVisible(visible)

        if !visible {
            reconnectTask?.cancel()
            connectionTimeoutTask?.cancel()
            stopStallMonitoring()
            if state.isActivePlayback {
                LumaCamDiagnostics.log(
                    "visibility change stopping active playback session=\(sessionID.uuidString.lowercased())",
                    level: .debug,
                    category: "session",
                    cameraID: profile.id
                )
                ignoreNextStop = true
                engine.stop()
                state = .stopped
            }
            return
        }

        if isUserInitiatedConnection && !state.isActivePlayback {
            connect()
        }
    }

    private func startEngine() {
        do {
            connectionGeneration += 1
            lastError = nil
            LumaCamDiagnostics.log(
                "starting engine session=\(sessionID.uuidString.lowercased()) generation=\(connectionGeneration) reconnectAttempt=\(reconnectAttempt) endpoint=\(profile.endpoint.diagnosticsSummary)",
                category: "session",
                cameraID: profile.id
            )
            state = reconnectAttempt == 0 ? .preparing : .reconnecting(attempt: reconnectAttempt, delay: .zero)
            if let audioEngine = engine as? AudioConfigurableStreamPlaybackEngine {
                audioEngine.setAudioEnabled(isAudioEnabled)
            }
            try engine.prepare(endpoint: profile.endpoint)
            LumaCamDiagnostics.log(
                "engine prepared session=\(sessionID.uuidString.lowercased()) generation=\(connectionGeneration)",
                category: "session",
                cameraID: profile.id
            )
            state = .connecting
            scheduleConnectionTimeout(for: connectionGeneration)
            engine.start()
        } catch let error as PlaybackError {
            finishWithFailure(error)
        } catch {
            finishWithFailure(.unknown(error.localizedDescription))
        }
    }

    private func handleEngineStateChange(_ newState: StreamPlaybackState) {
        if ignoreNextStop, newState == .stopped {
            LumaCamDiagnostics.log(
                "ignoring expected stop callback session=\(sessionID.uuidString.lowercased())",
                level: .debug,
                category: "session",
                cameraID: profile.id
            )
            ignoreNextStop = false
            return
        }

        let previousState = state
        if shouldIgnoreLateStop(previousState: previousState, newState: newState) {
            LumaCamDiagnostics.log(
                "ignoring late stop callback session=\(sessionID.uuidString.lowercased()) previousState=\(previousState.diagnosticsSummary)",
                level: .debug,
                category: "session",
                cameraID: profile.id
            )
            return
        }

        state = newState
        LumaCamDiagnostics.log(
            "state transition session=\(sessionID.uuidString.lowercased()) \(previousState.diagnosticsSummary) -> \(newState.diagnosticsSummary)",
            category: "session",
            cameraID: profile.id
        )

        switch newState {
        case .playing:
            connectionTimeoutTask?.cancel()
            reconnectAttempt = 0
            lastError = nil
            startStallMonitoring()
        case let .failed(error):
            finishWithFailure(error)
        case .stopped:
            connectionTimeoutTask?.cancel()
            stopStallMonitoring()
            scheduleReconnectIfNeeded()
        case .idle:
            connectionTimeoutTask?.cancel()
            stopStallMonitoring()
        case .preparing, .connecting, .reconnecting:
            stopStallMonitoring()
        }
    }

    private func finishWithFailure(_ error: PlaybackError) {
        connectionTimeoutTask?.cancel()
        stopStallMonitoring()
        lastError = error
        state = .failed(error)
        LumaCamDiagnostics.log(
            "playback failed session=\(sessionID.uuidString.lowercased()) error=\(error.diagnosticsSummary)",
            level: .error,
            category: "session",
            cameraID: profile.id
        )
        scheduleReconnectIfNeeded()
    }

    private func scheduleConnectionTimeout(for generation: Int) {
        connectionTimeoutTask?.cancel()
        let timeout = connectionTimeout
        LumaCamDiagnostics.log(
            "scheduling connection timeout session=\(sessionID.uuidString.lowercased()) generation=\(generation) timeout=\(Int(timeout.components.seconds))s",
            level: .debug,
            category: "session",
            cameraID: profile.id
        )
        connectionTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.connectionGeneration == generation else { return }
                guard self.state == .connecting || self.state == .preparing else { return }

                LumaCamDiagnostics.log(
                    "connection timeout fired session=\(self.sessionID.uuidString.lowercased()) generation=\(generation) state=\(self.state.diagnosticsSummary)",
                    level: .warning,
                    category: "session",
                    cameraID: self.profile.id
                )
                self.ignoreNextStop = true
                self.engine.stop()
                self.finishWithFailure(
                    .transportFailure(
                        "RTSP negotiation timed out after \(Int(self.connectionTimeout.components.seconds))s. Verify the path, credentials, and transport."
                    )
                )
            }
        }
    }

    private func scheduleReconnectIfNeeded() {
        guard isUserInitiatedConnection, isVisible else {
            LumaCamDiagnostics.log(
                "reconnect skipped session=\(sessionID.uuidString.lowercased()) userInitiated=\(isUserInitiatedConnection) visible=\(isVisible)",
                level: .debug,
                category: "session",
                cameraID: profile.id
            )
            return
        }

        reconnectAttempt += 1
        guard let delay = reconnectPolicy.delay(forAttempt: reconnectAttempt) else {
            LumaCamDiagnostics.log(
                "reconnect policy exhausted session=\(sessionID.uuidString.lowercased()) attempts=\(reconnectAttempt)",
                level: .warning,
                category: "session",
                cameraID: profile.id
            )
            return
        }

        state = .reconnecting(attempt: reconnectAttempt, delay: delay)
        LumaCamDiagnostics.log(
            "reconnect scheduled session=\(sessionID.uuidString.lowercased()) attempt=\(reconnectAttempt) delay=\(Int(delay.components.seconds))s",
            category: "session",
            cameraID: profile.id
        )
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.startEngine()
        }
    }

    private func handleStatisticsChange(_ statistics: PlaybackStatistics?) {
        self.statistics = statistics
        let summary = statistics?.diagnosticsSummary ?? "cleared"
        LumaCamDiagnostics.log(
            "statistics updated session=\(sessionID.uuidString.lowercased()) \(summary)",
            level: .debug,
            category: "session",
            cameraID: profile.id
        )
    }

    private func stopStallMonitoring() {
        stallMonitorTask?.cancel()
        stallMonitorTask = nil
        isVideoStallSuspected = false
    }

    private func startStallMonitoring() {
        stopStallMonitoring()
        let threshold = videoStallThreshold
        let poll = stallPollInterval
        stallMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: poll)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.state == .playing else { return }
                    guard let reporter = self.engine as? PlaybackFrameActivityReporting,
                          let lastClock = reporter.lastVideoFrameWallClock
                    else {
                        self.isVideoStallSuspected = false
                        return
                    }
                    let limit = Self.timeInterval(from: threshold)
                    let elapsed = Date.now.timeIntervalSince(lastClock)
                    self.isVideoStallSuspected = elapsed > limit
                }
            }
        }
    }

    private static func timeInterval(from duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private func shouldIgnoreLateStop(
        previousState: StreamPlaybackState,
        newState: StreamPlaybackState
    ) -> Bool {
        guard newState == .stopped else {
            return false
        }

        switch previousState {
        case .reconnecting, .failed:
            return true
        case .idle, .preparing, .connecting, .playing, .stopped:
            return false
        }
    }
}
