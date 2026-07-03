import EfbyDomain
import Foundation

public struct LoadWorkspaceUseCase: Sendable {
    private let repository: any WorkspaceRepositoryProtocol

    public init(repository: any WorkspaceRepositoryProtocol) {
        self.repository = repository
    }

    public func callAsFunction() async throws -> WorkspaceState {
        try await repository.load()
    }
}
