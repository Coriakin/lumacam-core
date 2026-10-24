import XCTest
@testable import LumaCamCore

final class MotionMonitoringTests: XCTestCase {
    private func feed(_ tracker: inout MotionActivityTracker, motion: Bool, from: Double, through: Double) -> MotionActivity {
        var result = MotionActivity(intensity: 0, shouldChime: false)
        for tick in Int(from * 4)...Int(through * 4) { result = tracker.observe(motion: motion, at: Double(tick) / 4) }
        return result
    }

    func testSyntheticFramesRejectStillNoiseAndGlobalBrightnessButDetectObject() {
        var detector = MotionFrameDetector()
        let still = [UInt8](repeating: 80, count: 64 * 36)
        XCTAssertFalse(detector.observe(still))
        XCTAssertFalse(detector.observe(still))
        XCTAssertFalse(detector.observe(still.enumerated().map { UInt8(Int($0.element) + ($0.offset % 5) - 2) }))
        XCTAssertFalse(detector.observe([UInt8](repeating: 120, count: still.count)))
        var object = [UInt8](repeating: 120, count: still.count)
        for y in 10..<18 { for x in 20..<30 { object[y * 64 + x] = 220 } }
        XCTAssertTrue(detector.observe(object))
        detector.reset()
        XCTAssertFalse(detector.observe(object))
        XCTAssertFalse(detector.observe([]))
        XCTAssertFalse(detector.observe(still))
        XCTAssertFalse(detector.observe([0, 255]))
    }

    func testSustainedMotionRampsOverTenSecondsAtDifferentFrameRates() {
        for interval in [0.25, 0.5, 1.0] {
            var activity = MotionActivityTracker()
            XCTAssertEqual(activity.observe(motion: true, at: 0).intensity, 0.12, accuracy: 0.001)
            var last = 0.12
            for tick in 1...Int(10 / interval) {
                let next = activity.observe(motion: true, at: Double(tick) * interval).intensity
                XCTAssertGreaterThanOrEqual(next, last)
                if Double(tick) * interval < 9 { XCTAssertLessThan(next, 1) }
                last = next
            }
            XCTAssertEqual(last, 1, accuracy: 0.001)
        }
    }

    func testBriefMotionStaysGentleThenFadesGradually() {
        var activity = MotionActivityTracker()
        let brief = feed(&activity, motion: true, from: 0, through: 0.25).intensity
        XCTAssertLessThan(brief, 0.2)
        XCTAssertEqual(feed(&activity, motion: false, from: 0.5, through: 1.25).intensity, brief, accuracy: 0.001)
        let middle = feed(&activity, motion: false, from: 1.5, through: 3.75).intensity
        XCTAssertGreaterThan(middle, 0)
        XCTAssertLessThan(middle, brief)
        XCTAssertEqual(feed(&activity, motion: false, from: 4, through: 6.25).intensity, 0)
        XCTAssertEqual(activity.observe(motion: true, at: 6.5).intensity, 0.12, accuracy: 0.001)
    }

    func testRepeatedShortPausesPreserveButDoNotBuildActivity() {
        var activity = MotionActivityTracker()
        let before = feed(&activity, motion: true, from: 0, through: 4).intensity
        _ = feed(&activity, motion: false, from: 4.25, through: 4.75)
        let after = activity.observe(motion: true, at: 5).intensity
        XCTAssertEqual(after, before, accuracy: 0.001)
        _ = feed(&activity, motion: false, from: 5.25, through: 5.75)
        XCTAssertEqual(activity.observe(motion: true, at: 6).intensity, before, accuracy: 0.001)
        activity.reset()
        XCTAssertEqual(activity.observe(motion: false, at: 20).intensity, 0)
    }

    func testQuietChimeRequiresContinuousObservationsAndRearmsAfterSixtySeconds() {
        var activity = MotionActivityTracker()
        XCTAssertFalse(activity.observe(motion: true, at: 0).shouldChime)
        _ = feed(&activity, motion: false, from: 0.25, through: 59.75)
        XCTAssertFalse(activity.observe(motion: true, at: 60).shouldChime)
        _ = feed(&activity, motion: false, from: 60.25, through: 120)
        XCTAssertTrue(activity.observe(motion: true, at: 120.25).shouldChime)
        XCTAssertFalse(activity.observe(motion: true, at: 120.5).shouldChime)
        _ = activity.observe(motion: false, at: 120.75)
        XCTAssertFalse(activity.observe(motion: true, at: 190).shouldChime, "Missing frames are not observed quiet")
        activity.reset()
        XCTAssertFalse(activity.observe(motion: true, at: 200).shouldChime)
    }

    func testSettingsDefaultsAndDisable() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(MotionMonitoringSettings.isEnabled(in: defaults))
        XCTAssertFalse(MotionMonitoringSettings.isChimeEnabled(in: defaults))
        defaults.set(false, forKey: MotionMonitoringSettings.enabledKey)
        XCTAssertFalse(MotionMonitoringSettings.isEnabled(in: defaults))
    }
}
