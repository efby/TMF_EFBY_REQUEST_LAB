import EfbyDomain
import Foundation

public struct SaveWorkspaceUseCase: Sendable {
    private let repository: any WorkspaceRepositoryProtocol

    public init(repository: any WorkspaceRepositoryProtocol) {
        self.repository = repository
    }

    public func callAsFunction(_ state: WorkspaceState) async throws {
        try await repository.save(state)
    }
}
