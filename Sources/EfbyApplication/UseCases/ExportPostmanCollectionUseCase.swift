import EfbyDomain
import Foundation

public struct ExportPostmanCollectionUseCase: Sendable {
    private let codec: any PostmanCollectionCodecProtocol

    public init(codec: any PostmanCollectionCodecProtocol) {
        self.codec = codec
    }

    public func callAsFunction(
        _ collection: CollectionModel,
        targetVersion: PostmanSchemaVersion? = nil
    ) throws -> Data {
        try codec.export(collection, targetVersion: targetVersion)
    }
}
