import EfbyApplication
import Foundation

/// Coordina operaciones Git desacopladas del ViewModel principal.
@MainActor
public final class GitWorkspaceCoordinator {
    private let syncGitWorkspace: SyncGitWorkspaceUseCase
    private let gitPull: GitPullUseCase
    private let gitCommitAndPush: GitCommitAndPushUseCase
    private let gitService: any GitRepositoryServiceProtocol

    public init(
        syncGitWorkspace: SyncGitWorkspaceUseCase,
        gitPull: GitPullUseCase,
        gitCommitAndPush: GitCommitAndPushUseCase,
        gitService: any GitRepositoryServiceProtocol
    ) {
        self.syncGitWorkspace = syncGitWorkspace
        self.gitPull = gitPull
        self.gitCommitAndPush = gitCommitAndPush
        self.gitService = gitService
    }

    public func resolveRemoteConfiguration(from input: String) throws -> GitRemoteConfiguration {
        try gitService.normalizeRemoteInput(input)
    }

    public func describeRemote(_ remoteURL: String) -> (provider: GitProvider, authKind: GitAuthenticationKind) {
        (gitService.provider(for: remoteURL), gitService.authenticationKind(for: remoteURL))
    }

    public struct SharedGitPushGate {
        public var canPush: Bool
        public var reason: String?
        public var mergeInProgress: Bool
    }

    public func evaluatePushGate(
        at repositoryURL: URL,
        isReadOnlyMirror: Bool
    ) async -> SharedGitPushGate {
        if isReadOnlyMirror {
            return SharedGitPushGate(
                canPush: false,
                reason: "Este workspace está vinculado a Bitbucket en solo lectura: no se suben cambios al remoto.",
                mergeInProgress: false
            )
        }

        do {
            _ = try await gitService.fetchOrigin(at: repositoryURL, onOutput: nil)
            let behind = try await gitService.commitsBehindUpstream(at: repositoryURL)
            let unmerged = try await gitService.unmergedPaths(at: repositoryURL)
            let mergeInProgress = await gitService.hasMergeInProgress(at: repositoryURL)
            if !unmerged.isEmpty {
                return SharedGitPushGate(
                    canPush: false,
                    reason: "Resolve merge conflicts before pushing.",
                    mergeInProgress: mergeInProgress
                )
            }
            if mergeInProgress {
                return SharedGitPushGate(
                    canPush: false,
                    reason: "Complete or abort the in-progress merge before pushing.",
                    mergeInProgress: true
                )
            }
            if behind > 0 {
                return SharedGitPushGate(
                    canPush: false,
                    reason: "Run Update: \(behind) commit(s) on the remote are not merged into this branch yet.",
                    mergeInProgress: false
                )
            }
            return SharedGitPushGate(canPush: true, reason: nil, mergeInProgress: false)
        } catch {
            return SharedGitPushGate(canPush: false, reason: error.localizedDescription, mergeInProgress: false)
        }
    }

    public func pull(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        try await gitPull(at: repositoryURL, onOutput: onOutput)
    }

    public func commitAndPush(
        at repositoryURL: URL,
        message: String,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        try await gitCommitAndPush(at: repositoryURL, message: message, onOutput: onOutput)
    }
}
