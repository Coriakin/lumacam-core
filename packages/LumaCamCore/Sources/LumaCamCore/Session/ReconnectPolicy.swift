import Foundation

public struct ReconnectPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(
        maxAttempts: Int = 5,
        baseDelay: Duration = .seconds(2),
        maxDelay: Duration = .seconds(15)
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt <= maxAttempts else {
            return nil
        }

        let exponent = max(0, attempt - 1)
        let rawSeconds = min(pow(2.0, Double(exponent)) * baseDelay.seconds, maxDelay.seconds)
        return .seconds(rawSeconds)
    }
}

private extension Duration {
    var seconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
