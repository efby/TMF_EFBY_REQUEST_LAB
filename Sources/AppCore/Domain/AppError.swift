import Foundation

public enum AppError: LocalizedError, Sendable {
    case invalidDocument(String)
    case unsupportedFormat(String)
    case invalidURL(String)
    case network(String)
    case persistence(String)
    case export(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let message):
            return message
        case .unsupportedFormat(let message):
            return message
        case .invalidURL(let message):
            return message
        case .network(let message):
            return message
        case .persistence(let message):
            return message
        case .export(let message):
            return message
        }
    }
}
