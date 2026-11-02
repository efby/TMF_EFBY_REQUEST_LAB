import EfbyPresentation
import Foundation
import XCTest

final class RepositoryWriteEfficiencyTests: XCTestCase {
    private var directory: URL!
    private let oldModificationDate = Date(timeIntervalSince1970: 1_600_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("efby-write-efficiency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testIdenticalLocalWorkspaceSaveKeepsBytesAndModificationDate() async throws {
        let url = directory.appendingPathComponent("workspace.json")
        let repository = WorkspaceRepository(storageURL: url)
        let state = WorkspaceState.starter
        try await repository.save(state)
        let original = try stampAndRead(url)

        try await repository.save(state)
        try await repository.save(state)

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try modificationDate(url), oldModificationDate)
    }

    func testLocalWorkspaceComparisonReadsCurrentDiskAfterExternalEdit() async throws {
        let url = directory.appendingPathComponent("workspace.json")
        let repository = WorkspaceRepository(storageURL: url)
        let state = WorkspaceState.starter
        try await repository.save(state)
        let expected = try Data(contentsOf: url)
        let externalWriter = WorkspaceRepository(storageURL: url)
        var external = state
        external.activeWorkspaceName = "External edit"
        try await externalWriter.save(external)
        XCTAssertNotEqual(try Data(contentsOf: url), expected)

        try await repository.save(state)

        XCTAssertEqual(try Data(contentsOf: url), expected)
    }

    func testIdenticalSharedSnapshotSaveKeepsBytesAndModificationDate() async throws {
        let repository = SharedCollectionsRepository()
        let state = WorkspaceState.starter
        try await repository.saveWorkspaceSnapshot(state, to: directory)
        let url = directory.appendingPathComponent(SharedCollectionsRepository.workspaceSnapshotFilename)
        let original = try stampAndRead(url)

        try await repository.saveWorkspaceSnapshot(state, to: directory)

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try modificationDate(url), oldModificationDate)
    }

    func testIdenticalManagedDirectoriesDoNotCopyMoveRemoveOrRewrite() async throws {
        let operations = RepositoryEfficiencyOperations()
        let repository = SharedCollectionsRepository(fileManager: RepositoryEfficiencyFileManager(events: operations))
        let collections = [collection("Keep")]
        let environments = [EnvironmentProfile(name: "QA", variables: [VariableValue(key: "base", value: "https://example.test")])]
        let utilities = [WorkspaceScriptUtility(name: "Helper", source: "function helper() { return 1; }")]
        let flows = [WorkspaceFlowDefinition(name: "Flow")]
        try await repository.saveCollections(collections, to: directory)
        try await repository.saveEnvironments(environments, to: directory)
        try await repository.saveUtilityLibraries(utilities, to: directory)
        try await repository.saveFlows(flows, to: directory)
        let files = try regularFiles()
        let original = try Dictionary(uniqueKeysWithValues: files.map { ($0.path, try stampAndRead($0)) })
        operations.reset()

        for _ in 0..<2 {
            try await repository.saveCollections(collections, to: directory)
            try await repository.saveEnvironments(environments, to: directory)
            try await repository.saveUtilityLibraries(utilities, to: directory)
            try await repository.saveFlows(flows, to: directory)
        }

        XCTAssertTrue(operations.copies.isEmpty)
        XCTAssertTrue(operations.moves.isEmpty)
        XCTAssertTrue(operations.removals.isEmpty)
        XCTAssertTrue(operations.creations.isEmpty)
        XCTAssertEqual(try regularFiles().map(\.path).sorted(), files.map(\.path).sorted())
        for file in files {
            XCTAssertEqual(try Data(contentsOf: file), original[file.path])
            XCTAssertEqual(try modificationDate(file), oldModificationDate)
        }
    }

    func testChangingOneCollectionPreservesOtherFilesAndTheirModificationDates() async throws {
        let operations = RepositoryEfficiencyOperations()
        let repository = SharedCollectionsRepository(fileManager: RepositoryEfficiencyFileManager(events: operations))
        let keep = collection("Keep")
        var change = collection("Change")
        try await repository.saveCollections([keep, change], to: directory)
        let collections = directory.appendingPathComponent("collections")
        let keptURL = collections.appendingPathComponent("keep.postman_collection.json")
        let changedURL = collections.appendingPathComponent("change.postman_collection.json")
        let note = collections.appendingPathComponent("notes.txt")
        try Data("Preserve note".utf8).write(to: note)
        let originalKept = try stampAndRead(keptURL)
        let originalNote = try stampAndRead(note)
        let originalChanged = try stampAndRead(changedURL)
        change.items[0].request?.url = "https://example.test/changed"
        operations.reset()

        try await repository.saveCollections([keep, change], to: directory)

        XCTAssertEqual(operations.copies.map(\.lastPathComponent), ["collections"])
        XCTAssertEqual(operations.moves.count, 2)
        XCTAssertEqual(try Data(contentsOf: keptURL), originalKept)
        XCTAssertEqual(try modificationDate(keptURL), oldModificationDate)
        XCTAssertEqual(try Data(contentsOf: note), originalNote)
        XCTAssertEqual(try modificationDate(note), oldModificationDate)
        XCTAssertNotEqual(try Data(contentsOf: changedURL), originalChanged)
        XCTAssertNotEqual(try modificationDate(changedURL), oldModificationDate)
        XCTAssertFalse(operations.removals.contains { $0.lastPathComponent == keptURL.lastPathComponent })
    }

    func testIdenticalIndividualSaveKeepsUnrelatedCollectionsAndAvoidsStaging() async throws {
        let operations = RepositoryEfficiencyOperations()
        let repository = SharedCollectionsRepository(fileManager: RepositoryEfficiencyFileManager(events: operations))
        let keep = collection("Keep")
        try await repository.saveCollections([keep, collection("Other")], to: directory)
        let before = try regularFiles()
        for file in before { _ = try stampAndRead(file) }
        operations.reset()

        try await repository.saveCollection(keep, to: directory)

        XCTAssertTrue(operations.copies.isEmpty)
        XCTAssertTrue(operations.moves.isEmpty)
        XCTAssertTrue(operations.removals.isEmpty)
        XCTAssertEqual(try regularFiles().map(\.path).sorted(), before.map(\.path).sorted())
        for file in before { XCTAssertEqual(try modificationDate(file), oldModificationDate) }
    }

    func testManagedComparisonReadsExternalChangesAndStillValidatesCorruption() async throws {
        let operations = RepositoryEfficiencyOperations()
        let repository = SharedCollectionsRepository(fileManager: RepositoryEfficiencyFileManager(events: operations))
        let keep = collection("Keep")
        try await repository.saveCollections([keep], to: directory)
        let url = directory.appendingPathComponent("collections/keep.postman_collection.json")
        let expected = try Data(contentsOf: url)
        var external = keep
        external.items[0].request?.url = "https://example.test/external"
        try PostmanCollectionCodec().export(external).write(to: url)
        operations.reset()

        try await repository.saveCollections([keep], to: directory)

        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(operations.copies.count, 1)
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: url)
        operations.reset()
        do {
            try await repository.saveCollections([keep], to: directory)
            XCTFail("Corrupt current content must block an otherwise identical save")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(url.lastPathComponent))
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertTrue(operations.copies.isEmpty)
        XCTAssertTrue(operations.moves.isEmpty)
        XCTAssertTrue(operations.removals.isEmpty)
    }

    func testIdenticalSaveRecoversInterruptedDirectoryBeforeSkippingWrites() async throws {
        let operations = RepositoryEfficiencyOperations()
        let repository = SharedCollectionsRepository(fileManager: RepositoryEfficiencyFileManager(events: operations))
        let keep = collection("Keep")
        try await repository.saveCollections([keep], to: directory)
        let collections = directory.appendingPathComponent("collections")
        let url = collections.appendingPathComponent("keep.postman_collection.json")
        let expected = try stampAndRead(url)
        try FileManager.default.moveItem(at: collections, to: directory.appendingPathComponent(".collections.efby-backup"))
        operations.reset()

        try await repository.saveCollections([keep], to: directory)

        XCTAssertEqual(operations.moves.map(\.lastPathComponent), [".collections.efby-backup"])
        XCTAssertTrue(operations.copies.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(try modificationDate(url), oldModificationDate)
    }

    func testIdenticalSaveCleansObsoleteTransactionsOnlyAfterCurrentFilesValidate() async throws {
        let operations = RepositoryEfficiencyOperations()
        let repository = SharedCollectionsRepository(fileManager: RepositoryEfficiencyFileManager(events: operations))
        let keep = collection("Keep")
        try await repository.saveCollections([keep], to: directory)
        let collections = directory.appendingPathComponent("collections")
        let url = collections.appendingPathComponent("keep.postman_collection.json")
        let expected = try stampAndRead(url)
        let backup = directory.appendingPathComponent(".collections.efby-backup")
        let staging = directory.appendingPathComponent(".collections.efby-staging")
        try FileManager.default.copyItem(at: collections, to: backup)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        operations.reset()

        try await repository.saveCollections([keep], to: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(Set(operations.removals.map(\.lastPathComponent)), [backup.lastPathComponent, staging.lastPathComponent])
        XCTAssertTrue(operations.copies.isEmpty)
        XCTAssertTrue(operations.moves.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(try modificationDate(url), oldModificationDate)

        try FileManager.default.copyItem(at: collections, to: backup)
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: url)
        operations.reset()
        do {
            try await repository.saveCollections([keep], to: directory)
            XCTFail("Invalid current files must prevent obsolete-backup cleanup")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(url.lastPathComponent)), expected)
        XCTAssertTrue(operations.removals.isEmpty)
    }

    private func collection(_ name: String) -> CollectionModel {
        CollectionModel(info: CollectionInfoModel(name: name, schemaVersion: .v21), items: [
            CollectionNode(name: "Ping", kind: .request, request: APIRequestModel(name: "Ping", url: "https://example.test")),
        ])
    }

    private func stampAndRead(_ url: URL) throws -> Data {
        try FileManager.default.setAttributes([.modificationDate: oldModificationDate], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }

    private func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func regularFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }
}

private final class RepositoryEfficiencyOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var copyURLs: [URL] = []
    private var moveURLs: [URL] = []
    private var removalURLs: [URL] = []
    private var creationURLs: [URL] = []

    var copies: [URL] { lock.lock(); defer { lock.unlock() }; return copyURLs }
    var moves: [URL] { lock.lock(); defer { lock.unlock() }; return moveURLs }
    var removals: [URL] { lock.lock(); defer { lock.unlock() }; return removalURLs }
    var creations: [URL] { lock.lock(); defer { lock.unlock() }; return creationURLs }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        copyURLs.removeAll(); moveURLs.removeAll(); removalURLs.removeAll(); creationURLs.removeAll()
    }

    func recordCopy(_ url: URL) { lock.lock(); defer { lock.unlock() }; copyURLs.append(url) }
    func recordMove(_ url: URL) { lock.lock(); defer { lock.unlock() }; moveURLs.append(url) }
    func recordRemoval(_ url: URL) { lock.lock(); defer { lock.unlock() }; removalURLs.append(url) }
    func recordCreation(_ url: URL) { lock.lock(); defer { lock.unlock() }; creationURLs.append(url) }
}

private final class RepositoryEfficiencyFileManager: FileManager, @unchecked Sendable {
    private let events: RepositoryEfficiencyOperations

    init(events: RepositoryEfficiencyOperations) {
        self.events = events
        super.init()
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        events.recordCopy(source)
        try super.copyItem(at: source, to: destination)
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        events.recordMove(source)
        try super.moveItem(at: source, to: destination)
    }

    override func removeItem(at url: URL) throws {
        events.recordRemoval(url)
        try super.removeItem(at: url)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        events.recordCreation(url)
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
