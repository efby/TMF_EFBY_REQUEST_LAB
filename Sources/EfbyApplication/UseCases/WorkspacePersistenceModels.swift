import Foundation

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
