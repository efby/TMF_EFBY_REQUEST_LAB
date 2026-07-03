import Foundation

public struct ExecutionOutcome: Sendable {
    public var response: HTTPResponseModel
    public var rawRequest: String
    public var rawResponse: String
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
        response: HTTPResponseModel,
        rawRequest: String,
        rawResponse: String,
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
        self.response = response
        self.rawRequest = rawRequest
        self.rawResponse = rawResponse
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
