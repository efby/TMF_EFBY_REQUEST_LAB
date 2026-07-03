import EfbyDomain
import Foundation

public protocol WebSocketConnectionProtocol: Actor {
    func startReceiving(
        onEvent: @escaping @Sendable (WebSocketReceiveEvent) async -> Void
    ) -> Task<Void, Never>
    func receiveNextEvent() async -> WebSocketReceiveEvent?
    func send(text: String) async throws
    func sendPing() async throws
    func disconnect() async
}

public protocol WebSocketExecutionServiceProtocol: Sendable {
    func prepareConnection(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) throws -> WebSocketPreparationOutcome

    func connect(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol

    func resolveOutgoingMessage(
        from request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> String

    func resolve(
        _ text: String,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        localVariables: [KeyValueEntry],
        request: APIRequestModel?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> String

    func executeIncomingMessageScripts(
        message: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> WebSocketMessageScriptOutcome

    func executeDoneScripts(
        cause: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> WebSocketMessageScriptOutcome
}
