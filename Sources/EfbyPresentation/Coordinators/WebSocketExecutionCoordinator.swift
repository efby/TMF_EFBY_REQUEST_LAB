import EfbyApplication
import EfbyDomain
import Foundation

/// Coordina el ciclo de vida WebSocket desacoplado del ViewModel principal.
@MainActor
public final class WebSocketExecutionCoordinator {
    private nonisolated let webSocketService: any WebSocketExecutionServiceProtocol

    public init(webSocketService: any WebSocketExecutionServiceProtocol) {
        self.webSocketService = webSocketService
    }

    @concurrent public nonisolated func prepareConnection(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> WebSocketPreparationOutcome {
        try webSocketService.prepareConnection(
            request: request,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            workspaceEnvironments: workspaceEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            utilityLibraries: utilityLibraries
        )
    }

    public func connect(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol {
        try await webSocketService.connect(prepared: prepared, request: request)
    }

    @concurrent public nonisolated func resolveOutgoingMessage(
        from request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> String {
        try webSocketService.resolveOutgoingMessage(
            from: request,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            utilityLibraries: utilityLibraries
        )
    }

    public func resolve(
        _ text: String,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        localVariables: [KeyValueEntry],
        request: APIRequestModel?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) throws -> String {
        try webSocketService.resolve(
            text,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            localVariables: localVariables,
            request: request,
            utilityLibraries: utilityLibraries
        )
    }

    @concurrent public nonisolated func resolveAsync(
        _ text: String,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        localVariables: [KeyValueEntry],
        request: APIRequestModel?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> String {
        try webSocketService.resolve(
            text,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            localVariables: localVariables,
            request: request,
            utilityLibraries: utilityLibraries
        )
    }

    @concurrent public nonisolated func executeIncomingMessageScripts(
        message: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async -> WebSocketMessageScriptOutcome {
        webSocketService.executeIncomingMessageScripts(
            message: message,
            request: request,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            workspaceEnvironments: workspaceEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            utilityLibraries: utilityLibraries
        )
    }

    @concurrent public nonisolated func executeDoneScripts(
        cause: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async -> WebSocketMessageScriptOutcome {
        webSocketService.executeDoneScripts(
            cause: cause,
            request: request,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            workspaceEnvironments: workspaceEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            utilityLibraries: utilityLibraries
        )
    }
}
