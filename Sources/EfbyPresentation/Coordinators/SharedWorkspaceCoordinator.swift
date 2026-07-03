import EfbyApplication
import EfbyDomain
import Foundation

/// Carga y fusiona el contenido del workdir compartido (colecciones, entornos, flows).
@MainActor
public final class SharedWorkspaceCoordinator {
    public struct LoadedContent {
        public var collections: [CollectionModel]
        public var environments: [EnvironmentProfile]
        public var utilityLibraries: [WorkspaceScriptUtility]
        public var flows: [WorkspaceFlowDefinition]
        public var globalVariables: [VariableValue]?
        public var history: [HistoryEntry]?
        public var requestDrafts: [RequestDraftState]?
        public var activeEnvironmentID: UUID?
        public var persistedEnvironments: [EnvironmentProfile]
        public var infoMessage: String?
        public var pendingSaves: [PendingSave]
    }

    public enum PendingSave {
        case collections([CollectionModel], workspaceRoot: URL)
        case environments([EnvironmentProfile], workspaceRoot: URL)
        case utilityLibraries([WorkspaceScriptUtility], workspaceRoot: URL)
        case flows([WorkspaceFlowDefinition], workspaceRoot: URL)
    }

    public struct RepositoryContext {
        public var workspaceNames: [String]
        public var activeWorkspaceName: String?
        public var gitRemoteDescription: String?
        public var shouldPersistLocalWorkspace: Bool
    }

    private let persistenceCoordinator: WorkspacePersistenceCoordinator
    private let gitService: any GitRepositoryServiceProtocol
    private let normalizeFlows: ([WorkspaceFlowDefinition], [CollectionModel]) -> [WorkspaceFlowDefinition]

    public init(
        persistenceCoordinator: WorkspacePersistenceCoordinator,
        gitService: any GitRepositoryServiceProtocol,
        normalizeFlows: @escaping ([WorkspaceFlowDefinition], [CollectionModel]) -> [WorkspaceFlowDefinition]
    ) {
        self.persistenceCoordinator = persistenceCoordinator
        self.gitService = gitService
        self.normalizeFlows = normalizeFlows
    }

    public func refreshRepositoryContext(
        repositoryRoot: URL,
        currentWorkspace: WorkspaceState
    ) async throws -> RepositoryContext {
        try await persistenceCoordinator.ensureWorkdirMarker(in: repositoryRoot)
        var workspaceNames = try await persistenceCoordinator.workspaceNames(in: repositoryRoot)
        if workspaceNames.isEmpty {
            let defaultWorkspace = try await persistenceCoordinator.ensureDefaultWorkspace(in: repositoryRoot)
            workspaceNames = [defaultWorkspace]
        }

        var activeWorkspaceName = currentWorkspace.activeWorkspaceName
        var shouldPersistLocalWorkspace = false

        if activeWorkspaceName == nil || !workspaceNames.contains(activeWorkspaceName ?? "") {
            activeWorkspaceName = workspaceNames.first
            shouldPersistLocalWorkspace = true
        }

        if activeWorkspaceName == "default",
           workspaceNames.count > 1,
           let preferredWorkspace = try await preferredWorkspaceAfterInitialGitSync(
            from: workspaceNames,
            repositoryRoot: repositoryRoot
           ) {
            activeWorkspaceName = preferredWorkspace
            shouldPersistLocalWorkspace = true
        }

        let gitRemoteDescription = try await gitService.remoteURL(at: repositoryRoot)
        return RepositoryContext(
            workspaceNames: workspaceNames,
            activeWorkspaceName: activeWorkspaceName,
            gitRemoteDescription: gitRemoteDescription,
            shouldPersistLocalWorkspace: shouldPersistLocalWorkspace
        )
    }

    public func loadSharedContent(
        workspaceRoot: URL,
        existingCollections: [CollectionModel],
        existingUtilities: [WorkspaceScriptUtility],
        existingFlows: [WorkspaceFlowDefinition],
        currentActiveEnvironmentID: UUID?,
        forceInfoMessage: Bool,
        activeWorkspaceName: String?
    ) async throws -> LoadedContent {
        let sharedSnapshot = try await persistenceCoordinator.loadWorkspaceSnapshot(from: workspaceRoot)
        let sharedCollections = Self.preserveCollectionIdentifiers(
            from: existingCollections,
            in: try await persistenceCoordinator.loadCollections(from: workspaceRoot)
        )
        let sharedEnvironments = try await persistenceCoordinator.loadEnvironments(from: workspaceRoot)
        let sharedUtilities = try await persistenceCoordinator.loadUtilityLibraries(from: workspaceRoot)
        let sharedFlows = try await persistenceCoordinator.loadFlows(from: workspaceRoot)

        var pendingSaves: [PendingSave] = []
        var collections = existingCollections
        var environments: [EnvironmentProfile] = []
        var utilityLibraries = existingUtilities
        var flows = existingFlows
        var activeEnvironmentID = currentActiveEnvironmentID
        var persistedEnvironments: [EnvironmentProfile] = []

        if !sharedCollections.isEmpty {
            collections = sharedCollections
        } else if let sharedSnapshot, !sharedSnapshot.collections.isEmpty {
            collections = Self.preserveCollectionIdentifiers(
                from: existingCollections,
                in: sharedSnapshot.collections
            )
            pendingSaves.append(.collections(collections, workspaceRoot: workspaceRoot))
        } else {
            collections = []
        }

        if !sharedEnvironments.isEmpty {
            environments = sharedEnvironments
            persistedEnvironments = sharedEnvironments
            if activeEnvironmentID == nil || !sharedEnvironments.contains(where: { $0.id == activeEnvironmentID }) {
                activeEnvironmentID = sharedEnvironments.first(where: \.isEnabled)?.id
            }
        } else if let sharedSnapshot, !sharedSnapshot.environments.isEmpty {
            environments = sharedSnapshot.environments
            persistedEnvironments = sharedSnapshot.environments
            if activeEnvironmentID == nil || !sharedSnapshot.environments.contains(where: { $0.id == activeEnvironmentID }) {
                activeEnvironmentID = sharedSnapshot.activeEnvironmentID
                    ?? sharedSnapshot.environments.first(where: \.isEnabled)?.id
            }
            pendingSaves.append(.environments(sharedSnapshot.environments, workspaceRoot: workspaceRoot))
        } else {
            environments = []
            persistedEnvironments = []
            activeEnvironmentID = nil
        }

        if !sharedUtilities.isEmpty {
            utilityLibraries = sharedUtilities
        } else if let sharedSnapshot, !sharedSnapshot.utilityLibraries.isEmpty {
            utilityLibraries = sharedSnapshot.utilityLibraries
            pendingSaves.append(.utilityLibraries(sharedSnapshot.utilityLibraries, workspaceRoot: workspaceRoot))
        } else if !existingUtilities.isEmpty {
            pendingSaves.append(.utilityLibraries(existingUtilities, workspaceRoot: workspaceRoot))
        }

        if !sharedFlows.isEmpty {
            flows = normalizeFlows(sharedFlows, collections)
        } else if let sharedSnapshot, !sharedSnapshot.flows.isEmpty {
            flows = normalizeFlows(sharedSnapshot.flows, collections)
            pendingSaves.append(.flows(flows, workspaceRoot: workspaceRoot))
        } else if existingFlows.isEmpty {
            flows = []
        } else {
            flows = normalizeFlows(existingFlows, collections)
            pendingSaves.append(.flows(flows, workspaceRoot: workspaceRoot))
        }

        let infoMessage: String?
        if forceInfoMessage {
            if sharedCollections.isEmpty && sharedEnvironments.isEmpty && sharedUtilities.isEmpty && sharedFlows.isEmpty {
                infoMessage = "No shared files found yet in \(workspaceRoot.path)."
            } else {
                let workspaceName = activeWorkspaceName ?? "workspace"
                infoMessage = "Loaded \(sharedCollections.count) collections, \(sharedEnvironments.count) environments, \(sharedUtilities.count) utilities, and \(sharedFlows.count) flows from \(workspaceName)."
            }
        } else {
            infoMessage = nil
        }

        return LoadedContent(
            collections: collections,
            environments: environments,
            utilityLibraries: utilityLibraries,
            flows: flows,
            globalVariables: sharedSnapshot?.globalVariables,
            history: sharedSnapshot?.history,
            requestDrafts: sharedSnapshot?.requestDrafts,
            activeEnvironmentID: activeEnvironmentID,
            persistedEnvironments: persistedEnvironments,
            infoMessage: infoMessage,
            pendingSaves: pendingSaves
        )
    }

    public func applyPendingSaves(_ saves: [PendingSave]) async throws {
        for save in saves {
            switch save {
            case .collections(let collections, let workspaceRoot):
                try await persistenceCoordinator.saveCollections(collections, to: workspaceRoot)
            case .environments(let environments, let workspaceRoot):
                try await persistenceCoordinator.saveEnvironments(environments, to: workspaceRoot)
            case .utilityLibraries(let utilities, let workspaceRoot):
                try await persistenceCoordinator.saveUtilityLibraries(utilities, to: workspaceRoot)
            case .flows(let flows, let workspaceRoot):
                try await persistenceCoordinator.saveFlows(flows, to: workspaceRoot)
            }
        }
    }

    private func preferredWorkspaceAfterInitialGitSync(
        from workspaceNames: [String],
        repositoryRoot: URL
    ) async throws -> String? {
        let defaultHasContent = try await persistenceCoordinator.workspaceHasManagedContent(
            named: "default",
            in: repositoryRoot
        )
        guard !defaultHasContent else {
            return nil
        }

        for workspaceName in workspaceNames where workspaceName != "default" {
            if try await persistenceCoordinator.workspaceHasManagedContent(
                named: workspaceName,
                in: repositoryRoot
            ) {
                return workspaceName
            }
        }

        return workspaceNames.first(where: { $0 != "default" })
    }

    public static func preserveCollectionIdentifiers(
        from existingCollections: [CollectionModel],
        in importedCollections: [CollectionModel]
    ) -> [CollectionModel] {
        importedCollections.map { importedCollection in
            guard let existingCollection = existingCollections.first(where: {
                $0.info.name.caseInsensitiveCompare(importedCollection.info.name) == .orderedSame
            }) else {
                return importedCollection
            }

            var updatedCollection = importedCollection
            updatedCollection.id = existingCollection.id
            updatedCollection.items = preserveNodeIdentifiers(from: existingCollection.items, in: importedCollection.items)
            return updatedCollection
        }
    }

    private static func preserveNodeIdentifiers(
        from existingNodes: [CollectionNode],
        in importedNodes: [CollectionNode]
    ) -> [CollectionNode] {
        var remainingExistingNodes = existingNodes

        return importedNodes.map { importedNode in
            let matchIndex = remainingExistingNodes.firstIndex(where: {
                $0.kind == importedNode.kind &&
                $0.name.caseInsensitiveCompare(importedNode.name) == .orderedSame
            })

            guard let matchIndex else {
                return importedNode
            }

            let existingNode = remainingExistingNodes.remove(at: matchIndex)
            var updatedNode = importedNode
            updatedNode.id = existingNode.id

            if var request = updatedNode.request, let existingRequest = existingNode.request {
                request.id = existingRequest.id
                updatedNode.request = request
            }

            updatedNode.children = preserveNodeIdentifiers(from: existingNode.children, in: importedNode.children)
            return updatedNode
        }
    }
}
