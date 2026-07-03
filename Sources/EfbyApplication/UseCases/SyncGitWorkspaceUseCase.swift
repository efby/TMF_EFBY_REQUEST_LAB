import EfbyDomain
import Foundation

public enum GitSyncOperation: Sendable {
    case status
    case pull
    case push
}

public struct GitSyncResult: Sendable {
    public let operation: GitSyncOperation
    public let remoteURL: String
    public let provider: GitProvider

    public init(operation: GitSyncOperation, remoteURL: String, provider: GitProvider) {
        self.operation = operation
        self.remoteURL = remoteURL
        self.provider = provider
    }
}

public struct SyncGitWorkspaceUseCase: Sendable {
    private let gitService: any GitRepositoryServiceProtocol

    public init(gitService: any GitRepositoryServiceProtocol) {
        self.gitService = gitService
    }

    public func resolveRemote(from input: String) throws -> GitSyncResult {
        let configuration = try gitService.normalizeRemoteInput(input)
        let provider = gitService.provider(for: configuration.remoteURL)
        return GitSyncResult(
            operation: .status,
            remoteURL: configuration.remoteURL,
            provider: provider
        )
    }
}
