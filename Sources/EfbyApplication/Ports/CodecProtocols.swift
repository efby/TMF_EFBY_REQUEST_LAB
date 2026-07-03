import EfbyDomain
import Foundation

public protocol PostmanEnvironmentCodecProtocol: Sendable {
    func importEnvironment(data: Data) throws -> EnvironmentProfile
    func exportEnvironment(_ environment: EnvironmentProfile) throws -> Data
    func isPostmanEnvironment(_ root: [String: Any]) -> Bool
}

public protocol OpenAPIImporterProtocol: Sendable {
    func importDocument(data: Data, fileExtension: String) throws -> CollectionModel
}
