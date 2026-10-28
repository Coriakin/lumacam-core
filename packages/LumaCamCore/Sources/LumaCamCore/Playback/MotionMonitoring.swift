import Foundation

/// Whole-picture luminance comparison. Input is a 64 × 36 grayscale grid.
/// Subtracting the mean change suppresses exposure shifts; the pixel threshold suppresses noise.
public struct MotionFrameDetector: Sendable {
    private var previous: [UInt8]?
    public private(set) var changedFraction = 0.0
    public private(set) var noiseThreshold = 0.0
    public init() {}
    public mutating func reset() { previous = nil; changedFraction = 0; noiseThreshold = 0 }

    public mutating func observe(_ pixels: [UInt8]) -> Bool {
        changedFraction = 0
        noiseThreshold = 0
        defer { previous = pixels.count == 64 * 36 ? pixels : nil }
        guard pixels.count == 64 * 36, let previous, previous.count == pixels.count else { return false }
        let shift = zip(pixels, previous).reduce(0.0) { $0 + Double(Int($1.0) - Int($1.1)) } / Double(pixels.count)
        let residuals = zip(pixels, previous).map { abs(Double(Int($0.0) - Int($0.1)) - shift) }
        // Typical frame-to-frame changes estimate the camera's noise floor. This allows
        // coherent low-contrast infrared texture to count without amplifying random sensor noise.
        let sorted = residuals.sorted()
        noiseThreshold = max(2, sorted[sorted.count / 2] * 3)
        let significant = residuals.map { $0 >= noiseThreshold }
        var coherent = 0
        for index in significant.indices where significant[index] {
            let x = index % 64, y = index / 64
            var neighbors = 0
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < 64, ny >= 0, ny < 36, significant[ny * 64 + nx] { neighbors += 1 }
                }
            }
            if neighbors >= 2 { coherent += 1 }
        }
        changedFraction = Double(coherent) / Double(pixels.count)
        return changedFraction >= 0.004
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
