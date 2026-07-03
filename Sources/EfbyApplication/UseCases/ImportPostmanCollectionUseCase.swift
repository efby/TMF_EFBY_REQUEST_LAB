import EfbyDomain
import Foundation

public struct ImportPostmanCollectionUseCase: Sendable {
    private let codec: any PostmanCollectionCodecProtocol

    public init(codec: any PostmanCollectionCodecProtocol) {
        self.codec = codec
    }

    public func callAsFunction(data: Data) throws -> CollectionModel {
        try codec.importCollection(data: data)
    }
}
