import Foundation

public struct WebSocketPreparationOutcome: Sendable {
    public var urlRequest: URLRequest
    public var rawRequest: String
    public var updatedRequestHeaders: [KeyValueEntry]?
    public var updatedRequestQueryItems: [KeyValueEntry]?
    public var updatedRequestBody: RequestBodyModel?
    public var updatedGlobals: [VariableValue]
    public var updatedCollection: [VariableValue]
    public var updatedEnvironment: [VariableValue]
    public var updatedEnvironments: [EnvironmentProfile]
    public var activeEnvironmentID: UUID?
    public var updatedLocal: [KeyValueEntry]
    public var logs: [String]

    public init(
        urlRequest: URLRequest,
        rawRequest: String,
        updatedRequestHeaders: [KeyValueEntry]? = nil,
        updatedRequestQueryItems: [KeyValueEntry]? = nil,
        updatedRequestBody: RequestBodyModel? = nil,
        updatedGlobals: [VariableValue],
        updatedCollection: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        updatedLocal: [KeyValueEntry],
        logs: [String]
    ) {
        self.urlRequest = urlRequest
        self.rawRequest = rawRequest
        self.updatedRequestHeaders = updatedRequestHeaders
        self.updatedRequestQueryItems = updatedRequestQueryItems
        self.updatedRequestBody = updatedRequestBody
        self.updatedGlobals = updatedGlobals
        self.updatedCollection = updatedCollection
        self.updatedEnvironment = updatedEnvironment
        self.updatedEnvironments = updatedEnvironments
        self.activeEnvironmentID = activeEnvironmentID
        self.updatedLocal = updatedLocal
        self.logs = logs
    }
}

public enum WebSocketReceiveEvent: Sendable {
    case entry(WebSocketTranscriptEntry)
    case closed(String)
    case failure(String)
}

public struct WebSocketMessageScriptOutcome: Sendable {
    public var updatedGlobals: [VariableValue]
    public var updatedCollection: [VariableValue]
    public var updatedEnvironment: [VariableValue]
    public var updatedEnvironments: [EnvironmentProfile]
    public var activeEnvironmentID: UUID?
    public var updatedLocal: [KeyValueEntry]
    public var logs: [String]
    public var shouldDisconnect: Bool

    public init(
        updatedGlobals: [VariableValue],
        updatedCollection: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        updatedLocal: [KeyValueEntry],
        logs: [String],
        shouldDisconnect: Bool
    ) {
        self.updatedGlobals = updatedGlobals
        self.updatedCollection = updatedCollection
        self.updatedEnvironment = updatedEnvironment
        self.updatedEnvironments = updatedEnvironments
        self.activeEnvironmentID = activeEnvironmentID
        self.updatedLocal = updatedLocal
        self.logs = logs
        self.shouldDisconnect = shouldDisconnect
    }
}
