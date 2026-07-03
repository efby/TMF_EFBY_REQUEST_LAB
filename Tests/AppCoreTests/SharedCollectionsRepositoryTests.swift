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
}
