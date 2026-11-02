import EfbyPresentation
import Foundation
import XCTest

final class MainViewModelRequestIntegrityTests: XCTestCase {
    @MainActor
    func testEditingImportedRequestPreservesExamplesAndDescriptionThroughPersistenceAndExport() async throws {
        try await assertImportedRequestMetadataSurvivesEditing(nested: false)
    }

    @MainActor
    func testEditingNestedImportedRequestPreservesExamplesAndDescriptionThroughPersistenceAndExport() async throws {
        try await assertImportedRequestMetadataSurvivesEditing(nested: true)
    }

    @MainActor
    func testSavingNewRequestStillCreatesCollectionNode() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceRepository(storageURL: directory.appendingPathComponent("workspace.json"))
        let collection = CollectionModel(info: CollectionInfoModel(name: "New requests"))
        let viewModel = MainViewModel(repository: repository, autoloadWorkspace: false)
        viewModel.workspace = WorkspaceState(activeWorkspaceName: "default", collections: [collection])

        viewModel.newRequest()
        let tab = try XCTUnwrap(viewModel.currentTab)
        tab.request.name = "New request"
        tab.request.url = "https://api.example.com/new"
        viewModel.saveCurrentRequest()
        await viewModel.flushStateForApplicationTermination()

        let savedWorkspace = try await repository.load()
        let savedNode = try XCTUnwrap(savedWorkspace.collections.first?.items.first)
        XCTAssertEqual(savedNode.id, tab.sourceNodeID)
        XCTAssertEqual(tab.sourceCollectionID, collection.id)
        XCTAssertEqual(savedNode.request, tab.request)
        XCTAssertEqual(savedNode.kind, .request)
        XCTAssertTrue(savedNode.responses.isEmpty)
        XCTAssertEqual(savedNode.nodeDescription, "")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    private func assertImportedRequestMetadataSurvivesEditing(nested: Bool) async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceRepository(storageURL: directory.appendingPathComponent("workspace.json"))
        let viewModel = MainViewModel(repository: repository, autoloadWorkspace: false)
        viewModel.workspace = WorkspaceState(activeWorkspaceName: "default")
        let importURL = directory.appendingPathComponent("collection.json")
        let fixture = nested
            ? Self.collectionFixture(replacingItemsWith: """
                [{"name":"Folder","description":"Folder documentation","item":[\(Self.requestFixture)]}]
                """)
            : Self.collectionFixture(replacingItemsWith: "[\(Self.requestFixture)]")
        try Data(fixture.utf8).write(to: importURL)

        await viewModel.importDocument(from: importURL)
        let collection = try XCTUnwrap(viewModel.workspace.collections.first)
        let originalNode = try XCTUnwrap(nested ? collection.items.first?.children.first : collection.items.first)
        XCTAssertEqual(originalNode.responses.count, 2)
        XCTAssertEqual(originalNode.nodeDescription, "Request documentation")

        await viewModel.open(request: originalNode, in: collection)
        let tab = try XCTUnwrap(viewModel.currentTab)
        tab.request.url = "https://api.example.com/edited"
        tab.request.name = "Edited request"
        viewModel.persistPendingChanges(for: tab)
        await viewModel.flushStateForApplicationTermination()

        let savedWorkspace = try await repository.load()
        let savedCollection = try XCTUnwrap(savedWorkspace.collections.first)
        let savedNode = try XCTUnwrap(nested ? savedCollection.items.first?.children.first : savedCollection.items.first)
        XCTAssertEqual(savedNode.id, originalNode.id)
        XCTAssertEqual(savedNode.responses, originalNode.responses)
        XCTAssertEqual(savedNode.nodeDescription, originalNode.nodeDescription)
        XCTAssertEqual(savedNode.children, originalNode.children)
        XCTAssertEqual(savedNode.request?.url, "https://api.example.com/edited")
        XCTAssertEqual(savedNode.name, "Edited request")
        XCTAssertEqual(savedNode.request?.id, originalNode.request?.id)
        XCTAssertEqual(savedCollection.info, collection.info)
        if nested {
            XCTAssertEqual(savedCollection.items.first?.id, collection.items.first?.id)
            XCTAssertEqual(savedCollection.items.first?.nodeDescription, "Folder documentation")
        }

        let codec = PostmanCollectionCodec()
        let exported = try codec.export(savedCollection)
        let roundTrip = try codec.importCollection(data: exported)
        let roundTripNode = try XCTUnwrap(nested ? roundTrip.items.first?.children.first : roundTrip.items.first)
        XCTAssertEqual(roundTripNode.nodeDescription, originalNode.nodeDescription)
        XCTAssertEqual(roundTripNode.request?.url, "https://api.example.com/edited")
        XCTAssertEqual(roundTripNode.responses.map(\.name), originalNode.responses.map(\.name))
        XCTAssertEqual(roundTripNode.responses.map(\.statusCode), originalNode.responses.map(\.statusCode))
        XCTAssertEqual(roundTripNode.responses.map(\.body), originalNode.responses.map(\.body))
        XCTAssertEqual(
            roundTripNode.responses.map { $0.headers.map { "\($0.key):\($0.value)" } },
            originalNode.responses.map { $0.headers.map { "\($0.key):\($0.value)" } }
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainViewModelRequestIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func collectionFixture(replacingItemsWith items: String) -> String {
        """
        {
          "info": {
            "name": "Imported examples",
            "description": "Collection documentation",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
          },
          "item": \(items)
        }
        """
    }

    private static let requestFixture = #"""
    {
      "name": "Read example",
      "description": "Request documentation",
      "request": {
        "method": "GET",
        "url": "https://api.example.com/original"
      },
      "response": [
        {
          "name": "Success",
          "code": 200,
          "header": [{"key":"Content-Type","value":"application/json"}],
          "body": "{\"ok\":true}"
        },
        {
          "name": "Unavailable",
          "code": 503,
          "header": [{"key":"Retry-After","value":"60"}],
          "body": "Try later"
        }
      ]
    }
    """#
}
