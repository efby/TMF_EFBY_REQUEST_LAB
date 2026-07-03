import EfbyDomain
import Foundation

public struct ImportOpenAPIDocumentUseCase: Sendable {
    private let importer: any OpenAPIImporterProtocol

    public init(importer: any OpenAPIImporterProtocol) {
        self.importer = importer
    }

    public func callAsFunction(data: Data, fileExtension: String) throws -> CollectionModel {
        try importer.importDocument(data: data, fileExtension: fileExtension)
    }
}
