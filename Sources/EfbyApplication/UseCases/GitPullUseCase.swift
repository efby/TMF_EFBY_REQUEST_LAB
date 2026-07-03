import EfbyDomain
import Foundation

public struct GitPullUseCase: Sendable {
    private let gitService: any GitRepositoryServiceProtocol

    public init(gitService: any GitRepositoryServiceProtocol) {
        self.gitService = gitService
    }

    public func callAsFunction(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        try await gitService.pull(at: repositoryURL, onOutput: onOutput)
    }
}
