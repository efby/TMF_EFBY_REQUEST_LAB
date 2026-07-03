import Foundation

public actor WorkspaceRepository {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let customStorageURL: URL?

    public init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.customStorageURL = storageURL
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> WorkspaceState {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return .starter
        }

        let data = try Data(contentsOf: url)
        let state = try decoder.decode(WorkspaceState.self, from: data)
        return try migrateIfNeeded(state)
    }

    public func save(_ state: WorkspaceState) throws {
        let url = try storageURL()
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func migrateIfNeeded(_ state: WorkspaceState) throws -> WorkspaceState {
        guard state.schemaVersion <= WorkspaceState.currentSchemaVersion else {
            throw AppError.persistence("La base local pertenece a una version mas nueva de la app.")
        }

        if state.schemaVersion == WorkspaceState.currentSchemaVersion {
            return state
        }

        var migrated = state
        if migrated.activeWorkspaceName == nil,
           migrated.sharedCollectionsDirectoryPath != nil {
            migrated.activeWorkspaceName = "default"
        }
        if migrated.schemaVersion < 3 {
            migrated.requestDrafts = migrated.requestDrafts.filter { !$0.workspaceName.isEmpty }
        }
        migrated.schemaVersion = WorkspaceState.currentSchemaVersion
        return migrated
    }

    private func storageURL() throws -> URL {
        if let customStorageURL {
            let parentDirectory = customStorageURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDirectory.path) {
                try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            }
            return customStorageURL
        }

        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("EFBYPostman", isDirectory: true)

        if !fileManager.fileExists(atPath: baseURL.path) {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }

        return baseURL.appendingPathComponent("workspace.json")
    }
}
