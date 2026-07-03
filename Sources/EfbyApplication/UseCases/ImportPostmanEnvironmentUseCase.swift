import EfbyDomain
import Foundation

public struct ImportPostmanEnvironmentUseCase: Sendable {
    private let codec: any PostmanEnvironmentCodecProtocol

    public init(codec: any PostmanEnvironmentCodecProtocol) {
        self.codec = codec
    }

    public func isPostmanEnvironment(_ root: [String: Any]) -> Bool {
        codec.isPostmanEnvironment(root)
    }

    public func callAsFunction(data: Data) throws -> EnvironmentProfile {
        try codec.importEnvironment(data: data)
    }
}
