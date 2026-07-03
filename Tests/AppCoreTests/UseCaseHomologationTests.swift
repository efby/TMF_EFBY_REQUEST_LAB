import EfbyApplication
import EfbyDomain
import EfbyInfrastructure
import XCTest

final class UseCaseHomologationTests: XCTestCase {
    func testImportPostmanCollectionUseCaseRoundTrip() throws {
        let codec = PostmanCollectionCodec()
        let useCase = ImportPostmanCollectionUseCase(codec: codec)
        let collection = CollectionModel(
            info: CollectionInfoModel(name: "Imported"),
            items: [
                CollectionNode(
                    name: "Ping",
                    kind: .request,
                    request: APIRequestModel(name: "Ping", method: .get, url: "https://example.com")
                ),
            ]
        )
        let data = try codec.export(collection, targetVersion: nil)
        let imported = try useCase(data: data)
        XCTAssertEqual(imported.info.name, "Imported")
        XCTAssertEqual(imported.items.count, 1)
    }

    func testExportPostmanCollectionUseCaseProducesData() throws {
        let useCase = ExportPostmanCollectionUseCase(codec: PostmanCollectionCodec())
        let data = try useCase(CollectionModel(info: CollectionInfoModel(name: "Out")))
        XCTAssertFalse(data.isEmpty)
    }

    func testLoadAndSaveWorkspaceUseCases() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("UseCaseHomologation-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: storage) }

        let repository = WorkspaceRepository(storageURL: storage)
        let save = SaveWorkspaceUseCase(repository: repository)
        let load = LoadWorkspaceUseCase(repository: repository)

        var state = WorkspaceState.starter
        state.globalVariables = [VariableValue(key: "g", value: "1")]
        try await save(state)

        let loaded = try await load()
        XCTAssertEqual(loaded.globalVariables.map(\.key), ["g"])
    }

    func testImportWorkspaceDocumentUseCaseRoutesEnvironment() throws {
        let environment = EnvironmentProfile(name: "Staging", variables: [VariableValue(key: "host", value: "x")])
        let data = try PostmanEnvironmentCodec().exportEnvironment(environment)
        let useCase = ImportWorkspaceDocumentUseCase(
            importPostmanCollection: ImportPostmanCollectionUseCase(codec: PostmanCollectionCodec()),
            importOpenAPI: ImportOpenAPIDocumentUseCase(importer: OpenAPIImporter()),
            importPostmanEnvironment: ImportPostmanEnvironmentUseCase(codec: PostmanEnvironmentCodec())
        )

        let result = try useCase(data: data, fileExtension: "json")
        guard case .environment(let imported) = result else {
            return XCTFail("Expected environment import")
        }
        XCTAssertEqual(imported.name, "Staging")
    }
}
