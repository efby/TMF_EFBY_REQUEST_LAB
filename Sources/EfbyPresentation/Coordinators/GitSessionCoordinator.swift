import EfbyApplication
import EfbyDomain
import Foundation

/// Orquesta pull, stash, merge y salida de consola Git sin acoplarse al estado de UI del ViewModel.
@MainActor
public final class GitSessionCoordinator {
    public enum StashPopOutcome: Equatable {
        case succeeded
        case stalledWithConflicts(paths: [String])
    }

    public enum PullOutcome: Equatable {
        case completed(
            extraOutputParts: [String],
            commandOutput: String,
            emptySuccessMessage: String,
            requiresFullRefresh: Bool,
            changedPaths: [String]
        )
        case mergeConflictsPending(paths: [String], output: String)
        case stashPopStalled(message: String, conflictPaths: [String])
    }

    public struct ConflictResolutionOutcome: Equatable {
        public var remainingConflicts: [String]
        public var mergeCommitOutput: String?
        public var shouldRefreshWorkspace: Bool
        public var stashDropOutput: String?
        public var stashPopOutcome: StashPopOutcome?
        public var conflictsResolvedMessage: String?
        public var stalledAfterStashPop: Bool
    }

    public private(set) var pendingStashPopAfterSharedPull = false
    public private(set) var pendingStashDropAfterPopConflict = false

    private let gitCoordinator: GitWorkspaceCoordinator
    private let gitService: any GitRepositoryServiceProtocol

    public init(
        gitCoordinator: GitWorkspaceCoordinator,
        gitService: any GitRepositoryServiceProtocol
    ) {
        self.gitCoordinator = gitCoordinator
        self.gitService = gitService
    }

    public func resetStashFlags() {
        pendingStashPopAfterSharedPull = false
        pendingStashDropAfterPopConflict = false
    }

    public func markPendingStashPopAfterPull(_ pending: Bool) {
        pendingStashPopAfterSharedPull = pending
    }

    public func normalizeOutputChunk(_ chunk: String) -> String {
        chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    public func append(chunk: String, to currentOutput: inout String?) {
        let normalizedChunk = normalizeOutputChunk(chunk)
        guard !normalizedChunk.isEmpty else { return }
        if currentOutput?.isEmpty ?? true {
            currentOutput = normalizedChunk
        } else {
            currentOutput?.append(normalizedChunk)
        }
    }

    public func makeOutputHandler(append: @escaping @MainActor (String) -> Void) -> GitOutputHandler {
        { chunk in
            Task { @MainActor in
                append(chunk)
            }
        }
    }

    public func status(
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws -> GitCommandResult {
        try await gitService.status(at: repositoryURL, onOutput: onOutput)
    }

    public func localChangesForPull(at repositoryURL: URL) async throws -> [String] {
        try await gitService.localChangesForPull(at: repositoryURL)
    }

    public func revertLocalChanges(at repositoryURL: URL) async throws -> GitCommandResult {
        try await gitService.revertLocalChanges(at: repositoryURL)
    }

    public func stashPushForUpdate(
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws -> GitCommandResult {
        try await gitService.stashPushIncludingUntracked(
            at: repositoryURL,
            message: "EFBY Shared Storage — pre-update",
            onOutput: onOutput
        )
    }

    public func abortMerge(
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws {
        _ = try await gitService.mergeAbort(at: repositoryURL, onOutput: onOutput)
        pendingStashPopAfterSharedPull = false
        pendingStashDropAfterPopConflict = false
    }

    public func runStashPopSequence(
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws -> StashPopOutcome {
        let pop = try await gitService.stashPop(at: repositoryURL, onOutput: onOutput)
        if pop.exitCode != 0 {
            let unmerged = try await gitService.unmergedPaths(at: repositoryURL)
            if !unmerged.isEmpty {
                pendingStashDropAfterPopConflict = true
                return .stalledWithConflicts(paths: unmerged)
            }
            throw AppError.persistence(pop.output.isEmpty ? "Stash pop failed." : pop.output)
        }
        pendingStashPopAfterSharedPull = false
        return .succeeded
    }

    public func performPull(
        at repositoryURL: URL,
        restoringDeletedPaths: [String]?,
        stashPopWhenDone: Bool,
        onOutput: GitOutputHandler?
    ) async throws -> PullOutcome {
        var outputParts: [String] = []

        if let restoringDeletedPaths, !restoringDeletedPaths.isEmpty {
            let restoreResult = try await gitService.restoreDeletedPaths(at: repositoryURL, paths: restoringDeletedPaths)
            if !restoreResult.output.isEmpty {
                outputParts.append(restoreResult.output)
            }
            outputParts.append("Recovered \(restoringDeletedPaths.count) deleted item(s) from Git before pull.")
        }

        let result = try await gitCoordinator.pull(at: repositoryURL, onOutput: onOutput)

        if !result.mergeConflictsPending.isEmpty {
            return .mergeConflictsPending(paths: result.mergeConflictsPending, output: result.output)
        }

        if stashPopWhenDone {
            let stashPopOutcome = try await runStashPopSequence(at: repositoryURL, onOutput: onOutput)
            if case .stalledWithConflicts(let paths) = stashPopOutcome {
                return .stashPopStalled(
                    message: "Resolve stash conflicts below, then Push will unlock when clean.\n",
                    conflictPaths: paths
                )
            }
        }

        return .completed(
            extraOutputParts: outputParts,
            commandOutput: result.output,
            emptySuccessMessage: "Update completed.\n",
            requiresFullRefresh: result.requiresFullRefresh,
            changedPaths: result.changedPaths
        )
    }

    public func performHardResetPull(
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws -> PullOutcome {
        let result = try await gitService.fetchAndHardResetToUpstream(at: repositoryURL, onOutput: onOutput)
        return .completed(
            extraOutputParts: [],
            commandOutput: result.output,
            emptySuccessMessage: "Actualización completada (árbol local igual al remoto).\n",
            requiresFullRefresh: result.requiresFullRefresh,
            changedPaths: result.changedPaths
        )
    }

    public func resolveMergeConflict(
        path: String,
        keepLocal: Bool,
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws -> ConflictResolutionOutcome {
        _ = try await gitService.checkoutConflictSide(
            at: repositoryURL,
            path: path,
            keepOurs: keepLocal,
            onOutput: onOutput
        )
        _ = try await gitService.addPaths([path], at: repositoryURL, onOutput: onOutput)

        let remaining = try await gitService.unmergedPaths(at: repositoryURL)
        var outcome = ConflictResolutionOutcome(
            remainingConflicts: remaining,
            mergeCommitOutput: nil,
            shouldRefreshWorkspace: false,
            stashDropOutput: nil,
            stashPopOutcome: nil,
            conflictsResolvedMessage: nil,
            stalledAfterStashPop: false
        )

        guard remaining.isEmpty else {
            return outcome
        }

        let mergeInProgress = await gitService.hasMergeInProgress(at: repositoryURL)
        if mergeInProgress {
            let commit = try await gitService.completeMergeCommit(at: repositoryURL, onOutput: onOutput)
            if commit.exitCode != 0 && !commit.output.localizedCaseInsensitiveContains("nothing to commit") {
                throw AppError.persistence(commit.output.isEmpty ? "Unable to complete merge commit." : commit.output)
            }
            if !commit.output.isEmpty {
                outcome.mergeCommitOutput = commit.output
            }
            outcome.shouldRefreshWorkspace = true
        }

        if pendingStashDropAfterPopConflict {
            let drop = try await gitService.stashDrop(at: repositoryURL, onOutput: onOutput)
            if !drop.output.isEmpty {
                outcome.stashDropOutput = drop.output
            }
            pendingStashDropAfterPopConflict = false
            pendingStashPopAfterSharedPull = false
        }

        if pendingStashPopAfterSharedPull {
            let stashPopOutcome = try await runStashPopSequence(at: repositoryURL, onOutput: onOutput)
            outcome.stashPopOutcome = stashPopOutcome
            if case .stalledWithConflicts(let paths) = stashPopOutcome {
                outcome.remainingConflicts = paths
                outcome.stalledAfterStashPop = true
                return outcome
            }
        }

        outcome.conflictsResolvedMessage = "Conflicts resolved.\n"
        return outcome
    }

    public func evaluatePushGate(
        at repositoryURL: URL,
        isReadOnlyMirror: Bool
    ) async -> GitWorkspaceCoordinator.SharedGitPushGate {
        await gitCoordinator.evaluatePushGate(at: repositoryURL, isReadOnlyMirror: isReadOnlyMirror)
    }

    public func commitAndPush(
        at repositoryURL: URL,
        message: String,
        onOutput: GitOutputHandler?
    ) async throws -> GitCommandResult {
        try await gitCoordinator.commitAndPush(at: repositoryURL, message: message, onOutput: onOutput)
    }

    public func pull(
        at repositoryURL: URL,
        onOutput: GitOutputHandler?
    ) async throws -> GitCommandResult {
        try await gitCoordinator.pull(at: repositoryURL, onOutput: onOutput)
    }

    public func remoteURL(at repositoryURL: URL) async throws -> String? {
        try await gitService.remoteURL(at: repositoryURL)
    }

    public func connectFlow(
        at repositoryURL: URL,
        remoteInput: String,
        credentials: GitCredentialInput? = nil,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitConnectionFlowResult {
        try await gitService.connectFlow(
            at: repositoryURL,
            remoteInput: remoteInput,
            credentials: credentials,
            onOutput: onOutput
        )
    }

    public func resolveRemoteConfiguration(from input: String) throws -> GitRemoteConfiguration {
        try gitCoordinator.resolveRemoteConfiguration(from: input)
    }

    public func describeRemote(_ remoteURL: String) -> (provider: GitProvider, authKind: GitAuthenticationKind) {
        gitCoordinator.describeRemote(remoteURL)
    }
}
