import Foundation
import EfbyDomain

public struct WorkspacePersistenceOptions: Sendable, Equatable {
    public var syncSharedCollections: Bool
    public var syncSharedEnvironments: Bool
    public var syncSharedFlows: Bool
    public var syncSharedUtilities: Bool

    public init(
        syncSharedCollections: Bool = true,
        syncSharedEnvironments: Bool = true,
        syncSharedFlows: Bool = true,
        syncSharedUtilities: Bool = true
    ) {
        self.syncSharedCollections = syncSharedCollections
        self.syncSharedEnvironments = syncSharedEnvironments
        self.syncSharedFlows = syncSharedFlows
        self.syncSharedUtilities = syncSharedUtilities
    }

    public static var localOnly: WorkspacePersistenceOptions {
        WorkspacePersistenceOptions(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: false
        )
    }

    public var mirrorsSharedWorkdir: Bool {
        syncSharedCollections || syncSharedEnvironments || syncSharedFlows || syncSharedUtilities
    }
}

/// Keeps the newest local state separate from each explicitly requested shared update.
public struct WorkspacePersistencePayload: Sendable {
    public var localSnapshot: WorkspaceState
    public var sharedMetadata: WorkspaceState?
    public var collections: [CollectionModel]?
    public var environments: [EnvironmentProfile]?
    public var flows: [WorkspaceFlowDefinition]?
    public var utilityLibraries: [WorkspaceScriptUtility]?

    public init(snapshot: WorkspaceState, options: WorkspacePersistenceOptions) {
        localSnapshot = snapshot
        sharedMetadata = options.mirrorsSharedWorkdir ? snapshot : nil
        collections = options.syncSharedCollections ? snapshot.collections : nil
        environments = options.syncSharedEnvironments ? snapshot.environments : nil
        flows = options.syncSharedFlows ? snapshot.flows : nil
        utilityLibraries = options.syncSharedUtilities ? snapshot.utilityLibraries : nil
    }

    public var options: WorkspacePersistenceOptions {
        WorkspacePersistenceOptions(syncSharedCollections: collections != nil, syncSharedEnvironments: environments != nil,
            syncSharedFlows: flows != nil, syncSharedUtilities: utilityLibraries != nil)
    }

    public mutating func merge(_ newer: WorkspacePersistencePayload) {
        localSnapshot = newer.localSnapshot
        if let value = newer.sharedMetadata { sharedMetadata = value }
        if let value = newer.collections { collections = value }
        if let value = newer.environments { environments = value }
        if let value = newer.flows { flows = value }
        if let value = newer.utilityLibraries { utilityLibraries = value }
    }
}

public struct WorkspacePersistenceReceipt: Sendable {
    public let localSnapshot: WorkspaceState
    public let sharedSnapshot: WorkspaceState?
    public let options: WorkspacePersistenceOptions
    public let workspaceRoot: URL?

    public init(localSnapshot: WorkspaceState, sharedSnapshot: WorkspaceState?, options: WorkspacePersistenceOptions, workspaceRoot: URL?) {
        self.localSnapshot = localSnapshot
        self.sharedSnapshot = sharedSnapshot
        self.options = options
        self.workspaceRoot = workspaceRoot
    }
}
