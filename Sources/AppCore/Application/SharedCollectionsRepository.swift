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
        try loadManagedJSONFiles(from: managedCollectionsDirectory(in: rootDirectory)) {
            try codec.importCollection(data: $0)
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
        let files = try encodedFiles(
            collections,
            fileSuffix: ".postman_collection.json",
            fallbackBaseName: "collection",
            name: { $0.info.name },
            encode: { try codec.export($0) }
        )
        try replaceManagedJSONFiles(files, in: managedCollectionsDirectory(in: rootDirectory)) {
            _ = try codec.importCollection(data: $0)
        }
    }

    public func saveCollection(_ collection: CollectionModel, to rootDirectory: URL) throws {
        let file = (name: sanitizedFilename(for: collection.info.name), data: try codec.export(collection))
        try replaceManagedJSONFiles(
            [file],
            in: managedCollectionsDirectory(in: rootDirectory),
            replacingAllJSON: false
        ) {
            _ = try codec.importCollection(data: $0)
        }
    }

    public func loadEnvironments(from rootDirectory: URL) throws -> [EnvironmentProfile] {
        try loadManagedJSONFiles(from: managedEnvironmentsDirectory(in: rootDirectory)) {
            try environmentCodec.importEnvironment(data: $0)
        }
    }

    public func saveEnvironments(_ environments: [EnvironmentProfile], to rootDirectory: URL) throws {
        let files = try encodedFiles(
            environments,
            fileSuffix: ".postman_environment.json",
            fallbackBaseName: "environment",
            name: { $0.name },
            encode: { try environmentCodec.exportEnvironment($0) }
        )
        try replaceManagedJSONFiles(files, in: managedEnvironmentsDirectory(in: rootDirectory)) {
            _ = try environmentCodec.importEnvironment(data: $0)
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
        let url = workspaceSnapshotURL(in: rootDirectory)
        if fileManager.fileExists(atPath: url.path), try Data(contentsOf: url) == data {
            return
        }
        try data.write(to: url, options: .atomic)
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
        try recoverManagedDirectory(directory)
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension.lowercased() == "json" }
    }

    private func loadManagedJSONFiles<T: Decodable>(from directory: URL, as type: T.Type) throws -> [T] {
        try loadManagedJSONFiles(from: directory) { try decoder.decode(type, from: $0) }
    }

    private func loadManagedJSONFiles<T>(from directory: URL, decode: (Data) throws -> T) throws -> [T] {
        try recoverManagedDirectory(directory)
        return try managedJSONFiles(in: directory).map { url in
            try readManagedJSONFile(at: url, decode: decode)
        }
    }

    private func managedJSONFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func readManagedJSONFile<T>(at url: URL, decode: (Data) throws -> T) throws -> T {
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            throw AppError.persistence("No se pudo leer el archivo '\(url.path)': \(error.localizedDescription)")
        }
    }

    private func saveManagedJSONFiles<T: Codable>(
        _ values: [T],
        to directory: URL,
        fileSuffix: String,
        fallbackBaseName: String,
        name: (T) -> String
    ) throws {
        let files = try encodedFiles(
            values,
            fileSuffix: fileSuffix,
            fallbackBaseName: fallbackBaseName,
            name: name,
            encode: { try encoder.encode($0) }
        )
        try replaceManagedJSONFiles(files, in: directory) {
            _ = try decoder.decode(T.self, from: $0)
        }
    }

    private func encodedFiles<T>(
        _ values: [T],
        fileSuffix: String,
        fallbackBaseName: String,
        name: (T) -> String,
        encode: (T) throws -> Data
    ) throws -> [(name: String, data: Data)] {
        var usedFilenames: Set<String> = []
        return try values.map { value in
            let filename = makeUniqueFilename(
                for: name(value),
                usedFilenames: &usedFilenames,
                fileSuffix: fileSuffix,
                fallbackBaseName: fallbackBaseName
            )
            return (filename, try encode(value))
        }
    }

    /// Prepare the entire replacement before moving the current directory to a recoverable backup.
    /// Both renames stay on the same volume. A restart between them restores the previous directory.
    private func replaceManagedJSONFiles(
        _ files: [(name: String, data: Data)],
        in directory: URL,
        replacingAllJSON: Bool = true,
        validate: (Data) throws -> Void
    ) throws {
        try recoverManagedDirectory(directory)
        let existingFiles = try managedJSONFiles(in: directory)
        var existingData: [String: Data] = [:]
        for url in existingFiles {
            existingData[url.lastPathComponent] = try readManagedJSONFile(at: url) { data in
                try validate(data)
                return data
            }
        }
        // Byte-identical incoming data has already been validated from the current file.
        for file in files where existingData[file.name] != file.data {
            try validate(file.data)
        }

        let hadPreviousDirectory = fileManager.fileExists(atPath: directory.path)
        if hadPreviousDirectory {
            let properties = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else {
                throw AppError.persistence("No se puede reemplazar el directorio enlazado '\(directory.path)'.")
            }
        }

        let staging = transactionDirectory(for: directory, suffix: "staging")
        let backup = transactionDirectory(for: directory, suffix: "backup")
        // A remaining backup alongside the validated current directory belongs to a completed save.
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        let sameFilenames = !replacingAllJSON || existingData.count == files.count
        if hadPreviousDirectory, sameFilenames, files.allSatisfy({ existingData[$0.name] == $0.data }) {
            return
        }
        defer { try? fileManager.removeItem(at: staging) }

        if hadPreviousDirectory {
            // Keep non-JSON files and subdirectories in the managed directory unchanged.
            try fileManager.copyItem(at: directory, to: staging)
        } else {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        if replacingAllJSON {
            let incomingNames = Set(files.map { $0.name })
            for url in existingFiles where !incomingNames.contains(url.lastPathComponent) {
                try fileManager.removeItem(at: staging.appendingPathComponent(url.lastPathComponent))
            }
        }
        for file in files where existingData[file.name] != file.data {
            try file.data.write(to: staging.appendingPathComponent(file.name), options: .atomic)
        }

        if hadPreviousDirectory {
            try fileManager.moveItem(at: directory, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: directory)
        } catch {
            if hadPreviousDirectory {
                do {
                    try fileManager.moveItem(at: backup, to: directory)
                } catch let recoveryError {
                    throw AppError.persistence(
                        "No se pudo completar el guardado: \(error.localizedDescription). "
                            + "La copia anterior se conserva en '\(backup.path)' para recuperarla: \(recoveryError.localizedDescription)"
                    )
                }
            }
            throw error
        }
        // Failure to remove an obsolete backup must not turn an installed save into a failure.
        try? fileManager.removeItem(at: backup)
    }

    private func transactionDirectory(for directory: URL, suffix: String) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).efby-\(suffix)", isDirectory: true)
    }

    private func recoverManagedDirectory(_ directory: URL) throws {
        let backup = transactionDirectory(for: directory, suffix: "backup")
        if !fileManager.fileExists(atPath: directory.path), fileManager.fileExists(atPath: backup.path) {
            try fileManager.moveItem(at: backup, to: directory)
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
