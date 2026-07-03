import EfbyApplication
import Foundation

/// Coordina el ciclo de vida de pestañas de petición HTTP/WebSocket.
@MainActor
public final class RequestTabCoordinator {
    private let executeHTTPRequest: ExecuteHTTPRequestUseCase

    public init(executeHTTPRequest: ExecuteHTTPRequestUseCase) {
        self.executeHTTPRequest = executeHTTPRequest
    }

    public func execute(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> ExecutionOutcome {
        try await executeHTTPRequest(
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
