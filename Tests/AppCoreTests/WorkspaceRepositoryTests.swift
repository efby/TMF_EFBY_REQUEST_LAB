import EfbyPresentation
import XCTest

final class WorkspaceRepositoryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("efby-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testLoadMissingFileReturnsStarterState() async throws {
        let storageURL = tempDirectory.appendingPathComponent("workspace.json")
        let repository = WorkspaceRepository(storageURL: storageURL)

        let state = try await repository.load()

        XCTAssertEqual(state.schemaVersion, WorkspaceState.currentSchemaVersion)
        XCTAssertFalse(state.collections.isEmpty)
        XCTAssertEqual(state.collections.first?.info.name, "Scratchpad")
    }

    func testSaveAndLoadRoundTripPreservesCollections() async throws {
        let storageURL = tempDirectory.appendingPathComponent("workspace.json")
        let repository = WorkspaceRepository(storageURL: storageURL)

        var state = WorkspaceState.starter
        state.collections = [
            CollectionModel(
                info: CollectionInfoModel(name: "Sample Collection", schemaVersion: .v21),
                items: [
                    CollectionNode(
                        name: "Ping",
                        kind: .request,
                        request: APIRequestModel(name: "Ping", method: .get, url: "https://example.com/ping")
                    ),
                ]
            ),
        ]

        try await repository.save(state)
        let loaded = try await repository.load()

        XCTAssertEqual(loaded.collections.count, 1)
        XCTAssertEqual(loaded.collections.first?.info.name, "Sample Collection")
        XCTAssertEqual(loaded.collections.first?.items.first?.request?.url, "https://example.com/ping")
    }

    func testMigratesLegacySchemaToCurrent() async throws {
        let storageURL = tempDirectory.appendingPathComponent("workspace.json")

        var legacyState = WorkspaceState.starter
        legacyState.schemaVersion = 2
        legacyState.sharedCollectionsDirectoryPath = "/tmp/shared"
        legacyState.activeWorkspaceName = nil
        legacyState.requestDrafts = [
            RequestDraftState(
                workspaceName: "",
                request: APIRequestModel(name: "Draft", method: .get, url: "https://example.com")
            ),
            RequestDraftState(
                workspaceName: "default",
                request: APIRequestModel(name: "Keep", method: .get, url: "https://example.com/keep")
            ),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(legacyState).write(to: storageURL)

        let repository = WorkspaceRepository(storageURL: storageURL)
        let migrated = try await repository.load()

        XCTAssertEqual(migrated.schemaVersion, WorkspaceState.currentSchemaVersion)
        XCTAssertEqual(migrated.activeWorkspaceName, "default")
        XCTAssertEqual(migrated.requestDrafts.count, 1)
        XCTAssertEqual(migrated.requestDrafts.first?.workspaceName, "default")
    }

    func testRejectsFutureSchemaVersion() async throws {
        let storageURL = tempDirectory.appendingPathComponent("workspace.json")
        let futureJSON = """
        {
          "schemaVersion": 999,
          "globalVariables": [],
          "collections": [],
          "flows": [],
          "utilityLibraries": [],
          "environments": [],
          "history": [],
          "requestDrafts": []
        }
        """
        try Data(futureJSON.utf8).write(to: storageURL)

        let repository = WorkspaceRepository(storageURL: storageURL)

        do {
            _ = try await repository.load()
            XCTFail("Expected persistence error for future schema")
        } catch let error as AppError {
            if case .persistence = error {
                // expected
            } else {
                XCTFail("Expected persistence error, got \(error)")
            }
        }
    }
}
