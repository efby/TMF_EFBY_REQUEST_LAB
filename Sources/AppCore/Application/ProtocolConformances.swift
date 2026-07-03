import Foundation

extension RequestExecutionService: HTTPExecutionServiceProtocol {}

extension PostmanCollectionCodec: PostmanCollectionCodecProtocol {}

extension PostmanEnvironmentCodec: PostmanEnvironmentCodecProtocol {}

extension OpenAPIImporter: OpenAPIImporterProtocol {}

extension GitRepositoryService: GitRepositoryServiceProtocol {}

extension WorkspaceRepository: WorkspaceRepositoryProtocol {}

extension SharedCollectionsRepository: SharedCollectionsRepositoryProtocol {}

extension WebSocketExecutionService: WebSocketExecutionServiceProtocol {}

extension WebSocketConnection: WebSocketConnectionProtocol {}
