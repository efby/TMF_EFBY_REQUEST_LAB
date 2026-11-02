import Foundation

public enum ScriptExecutionInterruption: Error, Sendable, Equatable, LocalizedError {
    case cancelled
    case timeLimitExceeded(seconds: TimeInterval)
    case watchdogUnavailable

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "JavaScript execution was cancelled."
        case .timeLimitExceeded(let seconds):
            return "JavaScript execution exceeded its \(seconds) second time limit."
        case .watchdogUnavailable:
            return "JavaScript execution is unavailable because this system does not provide the required execution watchdog."
        }
    }

    public func checkInterruption() throws {
        if self == .cancelled { throw CancellationError() }
        throw self
    }
}
