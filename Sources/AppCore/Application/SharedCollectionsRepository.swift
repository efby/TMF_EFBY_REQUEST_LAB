import Foundation

public actor SharedCollectionsRepository {
    public static let workdirMarkerFilename = "_directoritrabajo"
    public static let workspaceSnapshotFilename = "workspace-state.json"

    private let fileManager: FileManager
    private let codec: PostmanCollectionCodec
    private let environmentCodec: PostmanEnvironmentCodec
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileManager: FileManager = .default,
        codec: PostmanCollectionCodec = PostmanCollectionCodec(),
        environmentCodec: PostmanEnvironmentCodec = PostmanEnvironmentCodec()
    ) {
        self.fileManager = fileManager
        self.codec = codec
        self.environmentCodec = environmentCodec
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loadCollections(from rootDirectory: URL) throws -> [CollectionModel] {
        let collectionsDirectory = managedCollectionsDirectory(in: rootDirectory)
        guard fileManager.fileExists(atPath: collectionsDirectory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: collectionsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try files.compactMap { url in
            let data = try Data(contentsOf: url)
            return try? codec.importCollection(data: data)
        }
    }

    public func importCollections(from sourceDirectory: URL) throws -> [CollectionModel] {
        let files = try recursiveJSONFiles(in: sourceDirectory)
        var imported: [CollectionModel] = []

        for file in files {
            let data = try Data(contentsOf: file)
            if let collection = try? codec.importCollection(data: data) {
                imported.append(collection)
            }
        }

        return imported
    }

    public func saveCollections(_ collections: [CollectionModel], to rootDirectory: URL) throws {
        let collectionsDirectory = managedCollectionsDirectory(in: rootDirectory)
        if !fileManager.fileExists(atPath: collectionsDirectory.path) {
            try fileManager.createDirectory(at: collectionsDirectory, withIntermediateDirectories: true)
        }

        let existingFiles = try fileManager.contentsOfDirectory(
            at: collectionsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }

        for file in existingFiles {
            try fileManager.removeItem(at: file)
        }

        var usedFilenames: Set<String> = []
        for collection in collections {
            let filename = makeUniqueFilename(
                for: collection.info.name,
                usedFilenames: &usedFilenames,
                fileSuffix: ".postman_collection.json",
                fallbackBaseName: "collection"
            )
            let outputURL = collectionsDirectory.appendingPathComponent(filename)
            let data = try codec.export(collection)
            try data.write(to: outputURL, options: .atomic)
        }
    }

    public func saveCollection(_ collection: CollectionModel, to rootDirectory: URL) throws {
        let collectionsDirectory = managedCollectionsDirectory(in: rootDirectory)
        if !fileManager.fileExists(atPath: collectionsDirectory.path) {
            try fileManager.createDirectory(at: collectionsDirectory, withIntermediateDirectories: true)
        }

        let filename = sanitizedFilename(for: collection.info.name)
        let outputURL = collectionsDirectory.appendingPathComponent(filename)
        let data = try codec.export(collection)
        try data.write(to: outputURL, options: .atomic)
    }

    public func loadEnvironments(from rootDirectory: URL) throws -> [EnvironmentProfile] {
        let environmentsDirectory = managedEnvironmentsDirectory(in: rootDirectory)
        guard fileManager.fileExists(atPath: environmentsDirectory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: environmentsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try files.compactMap { url in
            let data = try Data(contentsOf: url)
            return try? environmentCodec.importEnvironment(data: data)
        }
    }

    public func saveEnvironments(_ environments: [EnvironmentProfile], to rootDirectory: URL) throws {
        let environmentsDirectory = managedEnvironmentsDirectory(in: rootDirectory)
        if !fileManager.fileExists(atPath: environmentsDirectory.path) {
            try fileManager.createDirectory(at: environmentsDirectory, withIntermediateDirectories: true)
        }

        let existingFiles = try fileManager.contentsOfDirectory(
            at: environmentsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }

        for file in existingFiles {
            try fileManager.removeItem(at: file)
        }

        var usedFilenames: Set<String> = []
        for environment in environments {
            let filename = makeUniqueFilename(
                for: environment.name,
                usedFilenames: &usedFilenames,
                fileSuffix: ".postman_environment.json",
                fallbackBaseName: "environment"
            )
            let outputURL = environmentsDirectory.appendingPathComponent(filename)
            let data = try environmentCodec.exportEnvironment(environment)
            try data.write(to: outputURL, options: .atomic)
        }
    }

    public func loadUtilityLibraries(from rootDirectory: URL) throws -> [WorkspaceScriptUtility] {
        try loadManagedJSONFiles(
            from: managedUtilitiesDirectory(in: rootDirectory),
            as: WorkspaceScriptUtility.self
        )
    }

    public func saveUtilityLibraries(_ utilities: [WorkspaceScriptUtility], to rootDirectory: URL) throws {
        try saveManagedJSONFiles(
            utilities,
            to: managedUtilitiesDirectory(in: rootDirectory),
            fileSuffix: ".efby_utility.json",
            fallbackBaseName: "utility"
        ) { $0.name }
    }

    public func loadFlows(from rootDirectory: URL) throws -> [WorkspaceFlowDefinition] {
        try loadManagedJSONFiles(
            from: managedFlowsDirectory(in: rootDirectory),
            as: WorkspaceFlowDefinition.self
        )
    }

    public func saveFlows(_ flows: [WorkspaceFlowDefinition], to rootDirectory: URL) throws {
        try saveManagedJSONFiles(
            flows,
            to: managedFlowsDirectory(in: rootDirectory),
            fileSuffix: ".efby_flow.json",
            fallbackBaseName: "flow"
        ) { $0.name }
    }

    public func loadWorkspaceSnapshot(from rootDirectory: URL) throws -> WorkspaceState? {
        let snapshotURL = workspaceSnapshotURL(in: rootDirectory)
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: snapshotURL)
        return try decoder.decode(WorkspaceState.self, from: data)
    }

    public func saveWorkspaceSnapshot(_ state: WorkspaceState, to rootDirectory: URL) throws {
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        }

        var snapshot = state
        snapshot.sharedCollectionsDirectoryPath = nil
        snapshot.sharedCollectionsDirectoryBookmarkData = nil

        let data = try encoder.encode(snapshot)
        try data.write(to: workspaceSnapshotURL(in: rootDirectory), options: .atomic)
    }

    public func managedCollectionsDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("collections", isDirectory: true)
    }

    public func managedEnvironmentsDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("environments", isDirectory: true)
    }

    public func managedUtilitiesDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("utilities", isDirectory: true)
    }

    public func managedFlowsDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("flows", isDirectory: true)
    }

    public func workspaceSnapshotURL(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(Self.workspaceSnapshotFilename, isDirectory: false)
    }

    public func workspaceNames(in repositoryRoot: URL) throws -> [String] {
        let entries = try fileManager.contentsOfDirectory(
            at: repositoryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try entries.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                return nil
            }
            return url.lastPathComponent
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func ensureDefaultWorkspace(in repositoryRoot: URL) throws -> String {
        let existing = try workspaceNames(in: repositoryRoot)
        if let first = existing.first {
            return first
        }

        let defaultName = "default"
        let workspaceDirectory = workspaceDirectory(in: repositoryRoot, named: defaultName)
        if !fileManager.fileExists(atPath: workspaceDirectory.path) {
            try fileManager.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        }
        return defaultName
    }

    public func createWorkspace(named name: String, in repositoryRoot: URL) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.persistence("Workspace name cannot be empty.")
        }

        let workspaceDirectory = workspaceDirectory(in: repositoryRoot, named: trimmed)
        if fileManager.fileExists(atPath: workspaceDirectory.path) {
            throw AppError.persistence("A workspace named '\(trimmed)' already exists.")
        }

        try fileManager.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        return trimmed
    }

    public func workspaceHasManagedContent(named workspaceName: String, in repositoryRoot: URL) throws -> Bool {
        let workspaceRoot = workspaceDirectory(in: repositoryRoot, named: workspaceName)
        let collectionsDirectory = managedCollectionsDirectory(in: workspaceRoot)
        let environmentsDirectory = managedEnvironmentsDirectory(in: workspaceRoot)
        let utilitiesDirectory = managedUtilitiesDirectory(in: workspaceRoot)
        let flowsDirectory = managedFlowsDirectory(in: workspaceRoot)

        return try directoryHasJSONFiles(collectionsDirectory)
            || directoryHasJSONFiles(environmentsDirectory)
            || directoryHasJSONFiles(utilitiesDirectory)
            || directoryHasJSONFiles(flowsDirectory)
    }

    public nonisolated func workspaceDirectory(in repositoryRoot: URL, named workspaceName: String) -> URL {
        repositoryRoot.appendingPathComponent(workspaceName, isDirectory: true)
    }

    public func workdirMarkerURL(in repositoryRoot: URL) -> URL {
        repositoryRoot.appendingPathComponent(Self.workdirMarkerFilename, isDirectory: false)
    }

    public func hasWorkdirMarker(in repositoryRoot: URL) -> Bool {
        let exactMarker = workdirMarkerURL(in: repositoryRoot)
        if fileManager.fileExists(atPath: exactMarker.path) {
            return true
        }

        let hiddenDotMarker = repositoryRoot.appendingPathComponent(".directoritrabajo", isDirectory: false)
        return fileManager.fileExists(atPath: hiddenDotMarker.path)
    }

    public func hasGitConfiguration(in repositoryRoot: URL) -> Bool {
        let gitURL = repositoryRoot.appendingPathComponent(".git", isDirectory: false)
        return fileManager.fileExists(atPath: gitURL.path)
    }

    public func ensureWorkdirMarker(in repositoryRoot: URL) throws {
        let markerURL = workdirMarkerURL(in: repositoryRoot)
        if !fileManager.fileExists(atPath: markerURL.path) {
            let data = Data("efby-request-lab-workdir\n".utf8)
            try data.write(to: markerURL, options: .atomic)
        }

        var resourceValues = URLResourceValues()
        resourceValues.isHidden = true
        var mutableMarkerURL = markerURL
        try? mutableMarkerURL.setResourceValues(resourceValues)
    }

    private func recursiveJSONFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "json" {
                results.append(url)
            }
        }
        return results.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func directoryHasJSONFiles(_ directory: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension.lowercased() == "json" }
    }

    private func loadManagedJSONFiles<T: Decodable>(from directory: URL, as type: T.Type) throws -> [T] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try files.map { url in
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        }
    }

    private func saveManagedJSONFiles<T: Encodable>(
        _ values: [T],
        to directory: URL,
        fileSuffix: String,
        fallbackBaseName: String,
        name: (T) -> String
    ) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let existingFiles = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }

        for file in existingFiles {
            try fileManager.removeItem(at: file)
        }

        var usedFilenames: Set<String> = []
        for value in values {
            let filename = makeUniqueFilename(
                for: name(value),
                usedFilenames: &usedFilenames,
                fileSuffix: fileSuffix,
                fallbackBaseName: fallbackBaseName
            )
            let outputURL = directory.appendingPathComponent(filename)
            let data = try encoder.encode(value)
            try data.write(to: outputURL, options: .atomic)
        }
    }

    private func makeUniqueFilename(
        for name: String,
        usedFilenames: inout Set<String>,
        fileSuffix: String,
        fallbackBaseName: String
    ) -> String {
        let base = sanitizedFilenameBase(for: name, fallbackBaseName: fallbackBaseName)
        var candidate = "\(base)\(fileSuffix)"
        var index = 2

        while usedFilenames.contains(candidate) {
            candidate = "\(base)-\(index)\(fileSuffix)"
            index += 1
        }

        usedFilenames.insert(candidate)
        return candidate
    }

    private func sanitizedFilename(for collectionName: String) -> String {
        "\(sanitizedFilenameBase(for: collectionName, fallbackBaseName: "collection")).postman_collection.json"
    }

    private func sanitizedFilenameBase(for name: String, fallbackBaseName: String) -> String {
        let normalized = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let slug = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return slug.isEmpty ? fallbackBaseName : slug
    }
}
