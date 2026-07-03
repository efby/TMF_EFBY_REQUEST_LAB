import EfbyDomain
import Foundation

public struct ExecuteHTTPRequestUseCase: Sendable {
    private let httpService: any HTTPExecutionServiceProtocol

    public init(httpService: any HTTPExecutionServiceProtocol) {
        self.httpService = httpService
    }

    public func callAsFunction(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) async throws -> ExecutionOutcome {
        try await httpService.execute(
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
