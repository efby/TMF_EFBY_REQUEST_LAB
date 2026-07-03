import EfbyDomain
import Foundation

public struct GitCommitAndPushUseCase: Sendable {
    private let gitService: any GitRepositoryServiceProtocol

    public init(gitService: any GitRepositoryServiceProtocol) {
        self.gitService = gitService
    }

    public func callAsFunction(
        at repositoryURL: URL,
        message: String,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        try await gitService.commitAndPush(at: repositoryURL, message: message, onOutput: onOutput)
    }
}
