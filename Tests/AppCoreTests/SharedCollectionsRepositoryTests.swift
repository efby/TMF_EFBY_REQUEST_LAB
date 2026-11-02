import EfbyPresentation
import XCTest

final class SharedCollectionsRepositoryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("efby-shared-collections-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testLoadsCollectionsFromManagedDirectory() async throws {
        let collectionsDir = tempDirectory.appendingPathComponent("collections", isDirectory: true)
        try FileManager.default.createDirectory(at: collectionsDir, withIntermediateDirectories: true)

        let collectionJSON = """
        {
          "info": {
            "name": "Shared Sample",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
          },
          "item": [
            {
              "name": "Health",
              "request": {
                "method": "GET",
                "url": "https://api.example.com/health"
              }
            }
          ]
        }
        """
        try Data(collectionJSON.utf8).write(
            to: collectionsDir.appendingPathComponent("shared-sample.json")
        )

        let repository = SharedCollectionsRepository()
        let collections = try await repository.loadCollections(from: tempDirectory)

        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.first?.info.name, "Shared Sample")
        XCTAssertEqual(collections.first?.items.first?.request?.method, .get)
    }

    func testReturnsEmptyWhenCollectionsDirectoryMissing() async throws {
        let repository = SharedCollectionsRepository()
        let collections = try await repository.loadCollections(from: tempDirectory)
        XCTAssertTrue(collections.isEmpty)
    }

    func testSaveCollectionsWritesToManagedDirectory() async throws {
        let repository = SharedCollectionsRepository()
        let collection = CollectionModel(
            info: CollectionInfoModel(name: "Export Test", schemaVersion: .v21),
            items: [
                CollectionNode(
                    name: "Ping",
                    kind: .request,
                    request: APIRequestModel(name: "Ping", method: .get, url: "https://example.com")
                ),
            ]
        )

        try await repository.saveCollections([collection], to: tempDirectory)

        let collectionsDir = tempDirectory.appendingPathComponent("collections", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: collectionsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertEqual(files.count, 1)
        let reloaded = try await repository.loadCollections(from: tempDirectory)
        XCTAssertEqual(reloaded.first?.info.name, "Export Test")
    }

    func testManagedCollectionsDirectoryPath() async {
        let repository = SharedCollectionsRepository()
        let root = URL(fileURLWithPath: "/tmp/repo")
        let managed = await repository.managedCollectionsDirectory(in: root)
        XCTAssertEqual(managed.lastPathComponent, "collections")
        XCTAssertEqual(managed.deletingLastPathComponent().path, root.path)
    }

    func testCorruptCollectionReportsFilenameAndBlocksReplacement() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveCollections([collection(named: "Keep")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("collections")
        let corruptURL = directory.appendingPathComponent("broken.json")
        let corruptData = Data("{invalid-json".utf8)
        try corruptData.write(to: corruptURL)
        let original = try directoryContents(directory)

        do {
            _ = try await repository.loadCollections(from: tempDirectory)
            XCTFail("Expected the corrupt file to be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("broken.json"))
        }
        do {
            try await repository.saveCollections([], to: tempDirectory)
            XCTFail("A corrupt collection must block replacement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("broken.json"))
        }
        XCTAssertEqual(try directoryContents(directory), original)

        do {
            try await repository.saveCollection(collection(named: "Other"), to: tempDirectory)
            XCTFail("A corrupt collection must also block individual writes")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("broken.json"))
        }
        XCTAssertEqual(try directoryContents(directory), original)
    }

    func testCorruptEnvironmentReportsFilenameAndBlocksReplacement() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveEnvironments([EnvironmentProfile(name: "Keep")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("environments")
        let badURL = directory.appendingPathComponent("broken.json")
        try Data("{}".utf8).write(to: badURL)
        let original = try directoryContents(directory)

        do {
            _ = try await repository.loadEnvironments(from: tempDirectory)
            XCTFail("Expected the corrupt environment to be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("broken.json"))
        }
        do {
            try await repository.saveEnvironments([], to: tempDirectory)
            XCTFail("A corrupt environment must block replacement")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("broken.json"))
        }
        XCTAssertEqual(try directoryContents(directory), original)
    }

    func testCorruptUtilityAndFlowFilesBlockReplacement() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveUtilityLibraries([WorkspaceScriptUtility(name: "Keep")], to: tempDirectory)
        try await repository.saveFlows([WorkspaceFlowDefinition(name: "Keep")], to: tempDirectory)
        for name in ["utilities", "flows"] {
            let directory = tempDirectory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("broken.json"))
            let original = try directoryContents(directory)
            do {
                if name == "utilities" {
                    _ = try await repository.loadUtilityLibraries(from: tempDirectory)
                } else {
                    _ = try await repository.loadFlows(from: tempDirectory)
                }
                XCTFail("Expected the corrupt file to be reported")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("broken.json"))
            }
            do {
                if name == "utilities" {
                    try await repository.saveUtilityLibraries([], to: tempDirectory)
                } else {
                    try await repository.saveFlows([], to: tempDirectory)
                }
                XCTFail("A corrupt file must block replacement")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("broken.json"))
            }
            XCTAssertEqual(try directoryContents(directory), original)
        }
    }

    func testFailedPreparationLeavesPreviousCollectionsIntact() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveCollections([collection(named: "Keep")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("collections")
        let original = try directoryContents(directory)
        let failingRepository = SharedCollectionsRepository(fileManager: FailingSharedStorageFileManager(failure: .preparation))

        do {
            try await failingRepository.saveCollections([collection(named: "Replacement")], to: tempDirectory)
            XCTFail("Expected preparation failure")
        } catch {}

        XCTAssertEqual(try directoryContents(directory), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent(".collections.efby-staging").path))
    }

    func testFailedInstallationRollsBackPreviousCollections() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveCollections([collection(named: "Keep")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("collections")
        let original = try directoryContents(directory)
        let failingRepository = SharedCollectionsRepository(fileManager: FailingSharedStorageFileManager(failure: .installation))

        do {
            try await failingRepository.saveCollections([collection(named: "Replacement")], to: tempDirectory)
            XCTFail("Expected installation failure")
        } catch {}

        XCTAssertEqual(try directoryContents(directory), original)
        let loaded = try await repository.loadCollections(from: tempDirectory)
        XCTAssertEqual(loaded.map { $0.info.name }, ["Keep"])
    }

    func testFailedRollbackKeepsBackupAndNextLoadRecoversIt() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveCollections([collection(named: "Keep")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("collections")
        let original = try directoryContents(directory)
        let backup = tempDirectory.appendingPathComponent(".collections.efby-backup")
        let failingRepository = SharedCollectionsRepository(fileManager: FailingSharedStorageFileManager(failure: .installationAndRollback))

        do {
            try await failingRepository.saveCollections([collection(named: "Replacement")], to: tempDirectory)
            XCTFail("Expected installation and rollback failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(backup.path))
        }
        XCTAssertEqual(try directoryContents(backup), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let restartedRepository = SharedCollectionsRepository()
        let recovered = try await restartedRepository.loadCollections(from: tempDirectory)
        XCTAssertEqual(recovered.map { $0.info.name }, ["Keep"])
        XCTAssertEqual(try directoryContents(directory), original)
    }

    func testManagedContentDetectionRecoversInterruptedReplacement() async throws {
        let repository = SharedCollectionsRepository()
        let workspaceRoot = tempDirectory.appendingPathComponent("demo")
        try await repository.saveCollections([collection(named: "Keep")], to: workspaceRoot)
        let directory = workspaceRoot.appendingPathComponent("collections")
        let backup = workspaceRoot.appendingPathComponent(".collections.efby-backup")
        try FileManager.default.moveItem(at: directory, to: backup)

        let hasContent = try await repository.workspaceHasManagedContent(named: "demo", in: tempDirectory)

        XCTAssertTrue(hasContent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let loaded = try await repository.loadCollections(from: workspaceRoot)
        XCTAssertEqual(loaded.map { $0.info.name }, ["Keep"])
    }

    func testEncodingFailurePreservesAllPreviousFlows() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveFlows([WorkspaceFlowDefinition(name: "Keep")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("flows")
        let original = try directoryContents(directory)
        let invalid = WorkspaceFlowDefinition(
            name: "Invalid",
            diagramViewport: WorkspaceFlowDiagramViewport(
                zoomPercent: .nan, viewboxX: 0, viewboxY: 0, viewboxWidth: 100, viewboxHeight: 100
            )
        )

        do {
            try await repository.saveFlows([WorkspaceFlowDefinition(name: "Valid first"), invalid], to: tempDirectory)
            XCTFail("Expected non-finite viewport to fail encoding")
        } catch {}
        XCTAssertEqual(try directoryContents(directory), original)
    }

    func testReplacementAndEmptySavePreserveUnmanagedFiles() async throws {
        let repository = SharedCollectionsRepository()
        try await repository.saveCollections([collection(named: "Old")], to: tempDirectory)
        let directory = tempDirectory.appendingPathComponent("collections")
        let note = directory.appendingPathComponent("notes.txt")
        let nested = directory.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let attachment = nested.appendingPathComponent("sample.json")
        let noteData = Data("Keep this note".utf8)
        let attachmentData = Data("{\"attached\":true}".utf8)
        try noteData.write(to: note)
        try attachmentData.write(to: attachment)

        try await repository.saveCollections([collection(named: "New"), collection(named: "New")], to: tempDirectory)
        let loaded = try await repository.loadCollections(from: tempDirectory)
        XCTAssertEqual(loaded.map { $0.info.name }, ["New", "New"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.postman_collection.json").path))
        XCTAssertEqual(try Data(contentsOf: note), noteData)
        XCTAssertEqual(try Data(contentsOf: attachment), attachmentData)

        try await repository.saveCollections([], to: tempDirectory)
        let empty = try await repository.loadCollections(from: tempDirectory)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try Data(contentsOf: note), noteData)
        XCTAssertEqual(try Data(contentsOf: attachment), attachmentData)
    }

    func testEnvironmentUtilityAndFlowReplacementRoundTrips() async throws {
        let repository = SharedCollectionsRepository()
        for name in ["Before", "After"] {
            try await repository.saveEnvironments([EnvironmentProfile(name: name)], to: tempDirectory)
            try await repository.saveUtilityLibraries([WorkspaceScriptUtility(name: name, source: "return 1;")], to: tempDirectory)
            try await repository.saveFlows([WorkspaceFlowDefinition(name: name)], to: tempDirectory)
        }
        let environments = try await repository.loadEnvironments(from: tempDirectory)
        let utilities = try await repository.loadUtilityLibraries(from: tempDirectory)
        let flows = try await repository.loadFlows(from: tempDirectory)
        XCTAssertEqual(environments.map(\.name), ["After"])
        XCTAssertEqual(utilities.map(\.name), ["After"])
        XCTAssertEqual(flows.map(\.name), ["After"])
    }

    private func collection(named name: String) -> CollectionModel {
        CollectionModel(
            info: CollectionInfoModel(name: name, schemaVersion: .v21),
            items: [CollectionNode(name: "Ping", kind: .request, request: APIRequestModel(name: "Ping", url: "https://example.com"))]
        )
    }

    private func directoryContents(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

}


private final class FailingSharedStorageFileManager: FileManager, @unchecked Sendable {
    enum Failure {
        case preparation
        case installation
        case installationAndRollback
    }

    private let failure: Failure

    init(failure: Failure) {
        self.failure = failure
        super.init()
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        try super.copyItem(at: source, to: destination)
        if failure == .preparation, destination.lastPathComponent == ".collections.efby-staging" {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        if destination.lastPathComponent == "collections" {
            if source.lastPathComponent == ".collections.efby-staging", failure != .preparation {
                throw CocoaError(.fileWriteUnknown)
            }
            if source.lastPathComponent == ".collections.efby-backup", failure == .installationAndRollback {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try super.moveItem(at: source, to: destination)
    }
}
