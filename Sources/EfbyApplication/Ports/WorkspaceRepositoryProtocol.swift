import EfbyDomain
import Foundation

public protocol WorkspaceRepositoryProtocol: Actor {
    func load() throws -> WorkspaceState
    func save(_ state: WorkspaceState) throws
}
