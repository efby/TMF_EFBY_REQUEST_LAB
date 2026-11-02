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
        _ = try await callAsFunction(WorkspacePersistencePayload(snapshot: snapshot, options: options), workspaceRoot: workspaceRoot)
    }

    public func callAsFunction(_ payload: WorkspacePersistencePayload, workspaceRoot: URL?,
                              confirmedLocalSnapshot: WorkspaceState? = nil) async throws -> WorkspacePersistenceReceipt {
        let options = payload.options
        guard let workspaceRoot, var shared = payload.sharedMetadata, options.mirrorsSharedWorkdir else {
            let confirmed = confirmedLocalSnapshot ?? payload.localSnapshot
            try await saveWorkspace(confirmed)
            return WorkspacePersistenceReceipt(localSnapshot: confirmed, sharedSnapshot: nil, options: options, workspaceRoot: workspaceRoot)
        }
        try await saveWorkspace(payload.localSnapshot)
        let previous = try await sharedRepository.loadWorkspaceSnapshot(from: workspaceRoot)
        if let collections = payload.collections { shared.collections = collections }
        else if let previous { shared.collections = previous.collections }
        else { shared.collections = try await sharedRepository.loadCollections(from: workspaceRoot) }
        if let environments = payload.environments { shared.environments = environments }
        else if let previous { shared.environments = previous.environments }
        else { shared.environments = try await sharedRepository.loadEnvironments(from: workspaceRoot) }
        if let flows = payload.flows { shared.flows = flows }
        else if let previous { shared.flows = previous.flows }
        else { shared.flows = try await sharedRepository.loadFlows(from: workspaceRoot) }
        if let utilities = payload.utilityLibraries { shared.utilityLibraries = utilities }
        else if let previous { shared.utilityLibraries = previous.utilityLibraries }
        else { shared.utilityLibraries = try await sharedRepository.loadUtilityLibraries(from: workspaceRoot) }
        // Editing drafts is local work, not permission to publish them through another area's save.
        shared.requestDrafts = previous?.requestDrafts ?? []
        if !shared.environments.contains(where: { $0.id == shared.activeEnvironmentID }) {
            shared.activeEnvironmentID = shared.environments.first(where: \.isEnabled)?.id
        }
        try await saveShared(shared, workspaceRoot: workspaceRoot, options: options)
        let confirmed = try await confirmLocal(payload.localSnapshot, with: confirmedLocalSnapshot)
        return WorkspacePersistenceReceipt(localSnapshot: confirmed, sharedSnapshot: shared,
            options: options, workspaceRoot: workspaceRoot)
    }

    private func confirmLocal(_ original: WorkspaceState, with confirmed: WorkspaceState?) async throws -> WorkspaceState {
        guard let confirmed, confirmed != original else { return original }
        try await saveWorkspace(confirmed)
        return confirmed
    }

    private func saveShared(_ snapshot: WorkspaceState, workspaceRoot: URL?, options: WorkspacePersistenceOptions) async throws {
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
