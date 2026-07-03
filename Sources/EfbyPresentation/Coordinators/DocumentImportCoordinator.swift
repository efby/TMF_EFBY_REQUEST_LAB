import EfbyApplication
import EfbyDomain
import Foundation

/// Coordina importación y exportación de documentos Postman, OpenAPI y entornos.
@MainActor
public final class DocumentImportCoordinator {
    private let importWorkspaceDocument: ImportWorkspaceDocumentUseCase
    private let exportPostmanCollection: ExportPostmanCollectionUseCase

    public init(
        importWorkspaceDocument: ImportWorkspaceDocumentUseCase,
        exportPostmanCollection: ExportPostmanCollectionUseCase
    ) {
        self.importWorkspaceDocument = importWorkspaceDocument
        self.exportPostmanCollection = exportPostmanCollection
    }

    public func importData(_ data: Data, fileExtension: String) throws -> ImportedWorkspaceDocument {
        try importWorkspaceDocument(data: data, fileExtension: fileExtension)
    }

    public func exportCollection(_ collection: CollectionModel) throws -> (name: String, data: Data) {
        (collection.info.name, try exportPostmanCollection(collection))
    }
}
