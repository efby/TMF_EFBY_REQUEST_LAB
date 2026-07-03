import EfbyDomain
import Foundation

public protocol SharedCollectionsRepositoryProtocol: Actor {
    func loadCollections(from rootDirectory: URL) throws -> [CollectionModel]
    func importCollections(from sourceDirectory: URL) throws -> [CollectionModel]
    func saveCollections(_ collections: [CollectionModel], to rootDirectory: URL) throws
    func loadEnvironments(from rootDirectory: URL) throws -> [EnvironmentProfile]
    func saveEnvironments(_ environments: [EnvironmentProfile], to rootDirectory: URL) throws
    func loadUtilityLibraries(from rootDirectory: URL) throws -> [WorkspaceScriptUtility]
    func saveUtilityLibraries(_ utilities: [WorkspaceScriptUtility], to rootDirectory: URL) throws
    func loadFlows(from rootDirectory: URL) throws -> [WorkspaceFlowDefinition]
    func saveFlows(_ flows: [WorkspaceFlowDefinition], to rootDirectory: URL) throws
    func loadWorkspaceSnapshot(from rootDirectory: URL) throws -> WorkspaceState?
    func saveWorkspaceSnapshot(_ state: WorkspaceState, to rootDirectory: URL) throws
    func workspaceNames(in repositoryRoot: URL) throws -> [String]
    func ensureDefaultWorkspace(in repositoryRoot: URL) throws -> String
    func createWorkspace(named name: String, in repositoryRoot: URL) throws -> String
    func workspaceHasManagedContent(named workspaceName: String, in repositoryRoot: URL) throws -> Bool
    nonisolated func workspaceDirectory(in repositoryRoot: URL, named workspaceName: String) -> URL
    func ensureWorkdirMarker(in repositoryRoot: URL) throws
}
