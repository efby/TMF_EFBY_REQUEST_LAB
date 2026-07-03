import EfbyApplication
import EfbyDomain
import Foundation

/// Coordina persistencia local y del workdir compartido.
@MainActor
public final class WorkspacePersistenceCoordinator {
    private let loadWorkspace: LoadWorkspaceUseCase
    private let saveWorkspace: SaveWorkspaceUseCase
    private let persistSnapshot: PersistWorkspaceSnapshotUseCase
    private let sharedRepository: any SharedCollectionsRepositoryProtocol

    public init(
        loadWorkspace: LoadWorkspaceUseCase,
        saveWorkspace: SaveWorkspaceUseCase,
        persistSnapshot: PersistWorkspaceSnapshotUseCase,
        sharedRepository: any SharedCollectionsRepositoryProtocol
    ) {
        self.loadWorkspace = loadWorkspace
        self.saveWorkspace = saveWorkspace
        self.persistSnapshot = persistSnapshot
        self.sharedRepository = sharedRepository
    }

    public func loadLocal() async throws -> WorkspaceState {
        try await loadWorkspace()
    }

    public func saveLocal(_ state: WorkspaceState) async throws {
        try await saveWorkspace(state)
    }

    public func persist(
        snapshot: WorkspaceState,
        workspaceRoot: URL?,
        options: WorkspacePersistenceOptions
    ) async throws {
        try await persistSnapshot(snapshot, workspaceRoot: workspaceRoot, options: options)
    }

    public func ensureWorkdirMarker(in repositoryRoot: URL) async throws {
        try await sharedRepository.ensureWorkdirMarker(in: repositoryRoot)
    }

    public func workspaceNames(in repositoryRoot: URL) async throws -> [String] {
        try await sharedRepository.workspaceNames(in: repositoryRoot)
    }

    public func ensureDefaultWorkspace(in repositoryRoot: URL) async throws -> String {
        try await sharedRepository.ensureDefaultWorkspace(in: repositoryRoot)
    }

    public func createWorkspace(named name: String, in repositoryRoot: URL) async throws -> String {
        try await sharedRepository.createWorkspace(named: name, in: repositoryRoot)
    }

    public func importCollections(from sourceDirectory: URL) async throws -> [CollectionModel] {
        try await sharedRepository.importCollections(from: sourceDirectory)
    }

    public func workspaceHasManagedContent(named workspaceName: String, in repositoryRoot: URL) async throws -> Bool {
        try await sharedRepository.workspaceHasManagedContent(named: workspaceName, in: repositoryRoot)
    }

    public func workspaceDirectory(in repositoryRoot: URL, named workspaceName: String) -> URL {
        sharedRepository.workspaceDirectory(in: repositoryRoot, named: workspaceName)
    }

    public func loadCollections(from workspaceRoot: URL) async throws -> [CollectionModel] {
        try await sharedRepository.loadCollections(from: workspaceRoot)
    }

    public func loadEnvironments(from workspaceRoot: URL) async throws -> [EnvironmentProfile] {
        try await sharedRepository.loadEnvironments(from: workspaceRoot)
    }

    public func loadUtilityLibraries(from workspaceRoot: URL) async throws -> [WorkspaceScriptUtility] {
        try await sharedRepository.loadUtilityLibraries(from: workspaceRoot)
    }

    public func loadFlows(from workspaceRoot: URL) async throws -> [WorkspaceFlowDefinition] {
        try await sharedRepository.loadFlows(from: workspaceRoot)
    }

    public func loadWorkspaceSnapshot(from workspaceRoot: URL) async throws -> WorkspaceState? {
        try await sharedRepository.loadWorkspaceSnapshot(from: workspaceRoot)
    }

    public func saveCollections(_ collections: [CollectionModel], to workspaceRoot: URL) async throws {
        try await sharedRepository.saveCollections(collections, to: workspaceRoot)
    }

    public func saveEnvironments(_ environments: [EnvironmentProfile], to workspaceRoot: URL) async throws {
        try await sharedRepository.saveEnvironments(environments, to: workspaceRoot)
    }

    public func saveUtilityLibraries(_ utilities: [WorkspaceScriptUtility], to workspaceRoot: URL) async throws {
        try await sharedRepository.saveUtilityLibraries(utilities, to: workspaceRoot)
    }

    public func saveFlows(_ flows: [WorkspaceFlowDefinition], to workspaceRoot: URL) async throws {
        try await sharedRepository.saveFlows(flows, to: workspaceRoot)
    }

    public func saveWorkspaceSnapshot(_ snapshot: WorkspaceState, to workspaceRoot: URL) async throws {
        try await sharedRepository.saveWorkspaceSnapshot(snapshot, to: workspaceRoot)
    }

    public func saveSharedGitSnapshot(
        collections: [CollectionModel],
        environments: [EnvironmentProfile],
        utilities: [WorkspaceScriptUtility],
        flows: [WorkspaceFlowDefinition],
        snapshot: WorkspaceState,
        to workspaceRoot: URL
    ) async throws {
        try await sharedRepository.saveCollections(collections, to: workspaceRoot)
        try await sharedRepository.saveEnvironments(environments, to: workspaceRoot)
        try await sharedRepository.saveUtilityLibraries(utilities, to: workspaceRoot)
        try await sharedRepository.saveFlows(flows, to: workspaceRoot)
        try await sharedRepository.saveWorkspaceSnapshot(snapshot, to: workspaceRoot)
    }
}
