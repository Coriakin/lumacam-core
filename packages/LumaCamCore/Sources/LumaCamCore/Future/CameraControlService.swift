import Foundation

public protocol CameraControlService: Sendable {
    func panLeft(cameraID: UUID) async throws
    func panRight(cameraID: UUID) async throws
    func tiltUp(cameraID: UUID) async throws
    func tiltDown(cameraID: UUID) async throws
    func zoomIn(cameraID: UUID) async throws
    func zoomOut(cameraID: UUID) async throws
}
