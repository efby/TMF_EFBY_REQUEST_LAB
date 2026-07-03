import EfbyApplication
import EfbyDomain
import Foundation

/// Coordina el ciclo de vida WebSocket desacoplado del ViewModel principal.
@MainActor
public final class WebSocketExecutionCoordinator {
    private let webSocketService: any WebSocketExecutionServiceProtocol

    public init(webSocketService: any WebSocketExecutionServiceProtocol) {
        self.webSocketService = webSocketService
    }

    public func prepareConnection(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) throws -> WebSocketPreparationOutcome {
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

    public func resolveOutgoingMessage(
        from request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> String {
        webSocketService.resolveOutgoingMessage(
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
    ) -> String {
        webSocketService.resolve(
            text,
            globals: globals,
            collectionVariables: collectionVariables,
            environmentVariables: environmentVariables,
            localVariables: localVariables,
            request: request,
            utilityLibraries: utilityLibraries
        )
    }

    public func executeIncomingMessageScripts(
        message: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> WebSocketMessageScriptOutcome {
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

    public func executeDoneScripts(
        cause: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> WebSocketMessageScriptOutcome {
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
