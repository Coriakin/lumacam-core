import Foundation

public protocol CameraControlService: Sendable {
    func panLeft(cameraID: UUID) async throws
    func panRight(cameraID: UUID) async throws
    func tiltUp(cameraID: UUID) async throws
    func tiltDown(cameraID: UUID) async throws
    func zoomIn(cameraID: UUID) async throws
    func zoomOut(cameraID: UUID) async throws
    /// Call when the user releases a control or leaves Live so continuous-move cameras stop safely.
    func stop(cameraID: UUID) async throws
}
