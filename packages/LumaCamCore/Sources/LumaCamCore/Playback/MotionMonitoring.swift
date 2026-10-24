import Foundation

/// Whole-picture luminance comparison. Input is a fixed, small grayscale grid.
/// Subtracting the mean change suppresses exposure shifts; the pixel threshold suppresses noise.
public struct MotionFrameDetector: Sendable {
    private var previous: [UInt8]?
    public init() {}
    public mutating func reset() { previous = nil }

    public mutating func observe(_ pixels: [UInt8]) -> Bool {
        defer { previous = pixels.isEmpty ? nil : pixels }
        guard !pixels.isEmpty, let previous, previous.count == pixels.count else { return false }
        let shift = zip(pixels, previous).reduce(0.0) { $0 + Double(Int($1.0) - Int($1.1)) } / Double(pixels.count)
        let changed = zip(pixels, previous).reduce(0) {
            $0 + (abs(Double(Int($1.0) - Int($1.1)) - shift) >= 16 ? 1 : 0)
        }
        return Double(changed) / Double(pixels.count) >= 0.015
    }
}

public struct MotionActivity: Sendable {
    public let intensity: Double
    public let shouldChime: Bool
}

/// Monotonic seconds are supplied by the caller, making timing independent of frame rate.
public struct MotionActivityTracker: Sendable {
    private var lastObservation: Double?
    private var previousMotion = false
    private var lastMotion: Double?
    private var quietStart: Double?
    private var peak = 0.0
    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func observe(motion: Bool, at time: Double) -> MotionActivity {
        guard time.isFinite else { reset(); return MotionActivity(intensity: 0, shouldChime: false) }
        // Missing frames cannot establish sustained motion or the quiet interval needed for a chime.
        if let lastObservation, time < lastObservation || time - lastObservation > 2 { reset() }
        let elapsed = lastObservation.map { max(0, time - $0) } ?? 0
        defer { lastObservation = time; previousMotion = motion }
        if motion {
            let chime = quietStart.map { time - $0 >= 60 } ?? false
            quietStart = nil
            if !previousMotion, let lastMotion {
                peak *= 1 - max(0, min(1, (time - lastMotion - 1) / 5))
            }
            if peak == 0 { peak = 0.12 }
            if previousMotion { peak = min(1, peak + 0.88 * elapsed / 10) }
            lastMotion = time
            return MotionActivity(intensity: peak, shouldChime: chime)
        }
        if quietStart == nil { quietStart = time }
        guard let lastMotion else { return MotionActivity(intensity: 0, shouldChime: false) }
        let fade = max(0, min(1, (time - lastMotion - 1) / 5))
        if fade >= 1 { peak = 0 }
        return MotionActivity(intensity: peak * (1 - fade), shouldChime: false)
    }
}

public enum MotionMonitoringSettings {
    public static let enabledKey = "motionMonitoring.enabled"
    public static let chimeKey = "motionMonitoring.chime"
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
    public static func isChimeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: chimeKey)
    }
}
