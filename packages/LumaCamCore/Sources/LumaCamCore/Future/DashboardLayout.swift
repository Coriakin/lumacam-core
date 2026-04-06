import Foundation

public enum DashboardLayout: String, Codable, CaseIterable, Sendable {
    case focusedSingle
    case splitTwo
    case gridFour

    public var displayName: String {
        switch self {
        case .focusedSingle:
            "Focused"
        case .splitTwo:
            "Two Up"
        case .gridFour:
            "Four Up"
        }
    }
}
