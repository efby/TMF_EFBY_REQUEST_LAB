import EfbyDomain
import Foundation

public struct PersistWorkspaceSnapshotUseCase: Sendable {
    private let saveWorkspace: SaveWorkspaceUseCase
    private let sharedRepository: any SharedCollectionsRepositoryProtocol

    public init(
        saveWorkspace: SaveWorkspaceUseCase,
        sharedRepository: any SharedCollectionsRepositoryProtocol
    ) {
        self.saveWorkspace = saveWorkspace
        self.sharedRepository = sharedRepository
    }

    public func callAsFunction(
        _ snapshot: WorkspaceState,
        workspaceRoot: URL?,
        options: WorkspacePersistenceOptions
    ) async throws {
        try await saveWorkspace(snapshot)
        guard let workspaceRoot, options.mirrorsSharedWorkdir else { return }

        if options.syncSharedCollections {
            try await sharedRepository.saveCollections(snapshot.collections, to: workspaceRoot)
        }
        if options.syncSharedEnvironments {
            try await sharedRepository.saveEnvironments(snapshot.environments, to: workspaceRoot)
        }
        if options.syncSharedUtilities {
            try await sharedRepository.saveUtilityLibraries(snapshot.utilityLibraries, to: workspaceRoot)
        }
        if options.syncSharedFlows {
            try await sharedRepository.saveFlows(snapshot.flows, to: workspaceRoot)
        }
        try await sharedRepository.saveWorkspaceSnapshot(snapshot, to: workspaceRoot)
    }
}
