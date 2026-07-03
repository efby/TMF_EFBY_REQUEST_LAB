import EfbyPresentation
import XCTest

private func repoRootFromTestFile() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

final class OpenAPIImporterTests: XCTestCase {
    func testImportsOpenAPI30Document() throws {
        let importer = OpenAPIImporter()
        let url = repoRootFromTestFile().appendingPathComponent("Examples/openapi-sample.json")
        let data = try Data(contentsOf: url)
        let collection = try importer.importDocument(data: data, fileExtension: "json")

        XCTAssertEqual(collection.info.name, "Echo API")
        XCTAssertEqual(collection.items.count, 1)
        XCTAssertEqual(collection.items.first?.request?.method, .get)
        XCTAssertTrue(collection.items.first?.request?.url.contains("/get") == true)
        XCTAssertEqual(collection.items.first?.request?.queryItems.first?.key, "foo")
        XCTAssertEqual(collection.items.first?.request?.queryItems.first?.value, "bar")
    }

    func testImportsOpenAPIFromInlineJSON() throws {
        let importer = OpenAPIImporter()
        let json = """
        {
          "openapi": "3.0.3",
          "info": { "title": "Pet API" },
          "paths": {
            "/pets": {
              "post": {
                "operationId": "createPet",
                "responses": { "201": { "description": "Created" } }
              }
            }
          }
        }
        """
        let collection = try importer.importDocument(data: Data(json.utf8), fileExtension: "json")

        XCTAssertEqual(collection.info.name, "Pet API")
        XCTAssertEqual(collection.items.first?.name, "createPet")
        XCTAssertEqual(collection.items.first?.request?.method, .post)
    }

    func testRejectsNonJSONExtension() {
        let importer = OpenAPIImporter()
        XCTAssertThrowsError(
            try importer.importDocument(data: Data("{}".utf8), fileExtension: "yaml")
        ) { error in
            guard case AppError.unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testRejectsOpenAPI2Document() {
        let importer = OpenAPIImporter()
        let json = """
        { "swagger": "2.0", "info": { "title": "Legacy" }, "paths": {} }
        """
        XCTAssertThrowsError(
            try importer.importDocument(data: Data(json.utf8), fileExtension: "json")
        ) { error in
            guard case AppError.invalidDocument = error else {
                return XCTFail("Expected invalidDocument, got \(error)")
            }
        }
    }

    func testExportImportRoundTripPreservesSemantics() throws {
        let importer = OpenAPIImporter()
        let url = repoRootFromTestFile().appendingPathComponent("Examples/openapi-sample.json")
        let data = try Data(contentsOf: url)
        let imported = try importer.importDocument(data: data, fileExtension: "json")

        XCTAssertFalse(imported.items.isEmpty)
        XCTAssertEqual(imported.items.first?.kind, .request)
    }
}
