import Foundation

public struct Countdown: Equatable, Sendable {
    public let totalSeconds: Int
    public private(set) var remainingSeconds: Int

    public init(seconds: Int) {
        totalSeconds = max(0, seconds)
        remainingSeconds = totalSeconds
    }

    public var isFinished: Bool { remainingSeconds <= 0 }
    public var label: String { "\(max(0, remainingSeconds))" }

    /// Advances one second and returns true when the countdown has finished.
    @discardableResult
    public mutating func tick() -> Bool {
        guard remainingSeconds > 0 else { return true }
        remainingSeconds -= 1
        return remainingSeconds == 0
    }
}
