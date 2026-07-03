import EfbyDomain
import Foundation

// MARK: - HTTP

public protocol HTTPExecutionServiceProtocol: Sendable {
    func execute(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> ExecutionOutcome
}

// MARK: - Postman

public protocol PostmanCollectionCodecProtocol: Sendable {
    func importCollection(data: Data) throws -> CollectionModel
    func export(_ collection: CollectionModel, targetVersion: PostmanSchemaVersion?) throws -> Data
}
