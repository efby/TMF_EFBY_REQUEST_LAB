import EfbyDomain
import Foundation

public protocol GitRepositoryServiceProtocol: Actor {
    nonisolated func normalizeRemoteInput(_ input: String) throws -> GitRemoteConfiguration
    nonisolated func provider(for remoteURL: String) -> GitProvider
    nonisolated func authenticationKind(for remoteURL: String) -> GitAuthenticationKind

    func status(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func localChangesForPull(at repositoryURL: URL) async throws -> [String]
    func revertLocalChanges(at repositoryURL: URL) async throws -> GitCommandResult
    func restoreDeletedPaths(at repositoryURL: URL, paths: [String]) async throws -> GitCommandResult
    func fetchOrigin(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func commitsBehindUpstream(at repositoryURL: URL) async throws -> Int
    func unmergedPaths(at repositoryURL: URL) async throws -> [String]
    func hasMergeInProgress(at repositoryURL: URL) async -> Bool
    func stashPushIncludingUntracked(
        at repositoryURL: URL,
        message: String,
        onOutput: GitOutputHandler?
    ) async throws -> GitCommandResult
    func stashPop(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func stashDrop(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func checkoutConflictSide(
        at repositoryURL: URL,
        path: String,
        keepOurs: Bool,
        onOutput: GitOutputHandler?
    ) async throws -> GitCommandResult
    func addPaths(_ paths: [String], at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func completeMergeCommit(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func mergeAbort(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func pull(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func fetchAndHardResetToUpstream(at repositoryURL: URL, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func commitAndPush(at repositoryURL: URL, message: String, onOutput: GitOutputHandler?) async throws -> GitCommandResult
    func connectFlow(
        at repositoryURL: URL,
        remoteInput: String,
        credentials: GitCredentialInput?,
        onOutput: GitOutputHandler?
    ) async throws -> GitConnectionFlowResult
    func remoteURL(at repositoryURL: URL) async throws -> String?
}
