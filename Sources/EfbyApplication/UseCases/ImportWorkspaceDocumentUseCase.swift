import EfbyDomain
import Foundation

public enum ImportedWorkspaceDocument: Sendable {
    case collection(CollectionModel)
    case environment(EnvironmentProfile)
}

public struct ImportWorkspaceDocumentUseCase: Sendable {
    private let importPostmanCollection: ImportPostmanCollectionUseCase
    private let importOpenAPI: ImportOpenAPIDocumentUseCase
    private let importPostmanEnvironment: ImportPostmanEnvironmentUseCase

    public init(
        importPostmanCollection: ImportPostmanCollectionUseCase,
        importOpenAPI: ImportOpenAPIDocumentUseCase,
        importPostmanEnvironment: ImportPostmanEnvironmentUseCase
    ) {
        self.importPostmanCollection = importPostmanCollection
        self.importOpenAPI = importOpenAPI
        self.importPostmanEnvironment = importPostmanEnvironment
    }

    public func callAsFunction(data: Data, fileExtension: String) throws -> ImportedWorkspaceDocument {
        if let environment = try importEnvironmentIfPossible(from: data) {
            return .environment(environment)
        }

        if isOpenAPI(data) {
            let collection = try importOpenAPI(data: data, fileExtension: fileExtension)
            return .collection(collection)
        }

        let collection = try importPostmanCollection(data: data)
        return .collection(collection)
    }

    private func importEnvironmentIfPossible(from data: Data) throws -> EnvironmentProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard importPostmanEnvironment.isPostmanEnvironment(root) else {
            return nil
        }
        return try importPostmanEnvironment(data: data)
    }

    private func isOpenAPI(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return root["openapi"] != nil
    }
}
