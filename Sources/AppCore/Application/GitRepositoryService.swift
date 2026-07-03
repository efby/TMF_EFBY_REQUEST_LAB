import Foundation

public actor GitRepositoryService {
    private static let protectedWorkdirMarkerNames: Set<String> = ["_directoritrabajo", ".directoritrabajo"]

    #if os(macOS)
    private final class GitProcessOutputState: @unchecked Sendable {
        private let lock = NSLock()
        private var combinedOutput = ""
        private var didResume = false

        func append(_ chunk: String) {
            lock.lock()
            combinedOutput.append(chunk)
            lock.unlock()
        }

        func trimmedOutput() -> String {
            lock.lock()
            defer { lock.unlock() }
            return combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func markResumed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }
    #endif

    public init() {}

    public func status(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        emit("Checking repository status...\n", to: onOutput)
        return try await runGit(arguments: ["status", "--short"], at: repositoryURL, onOutput: onOutput)
    }

    public func locallyDeletedPaths(at repositoryURL: URL) async throws -> [String] {
        let workingTree = try await runGit(
            arguments: ["diff", "--name-only", "--diff-filter=D"],
            at: repositoryURL,
            allowFailure: true
        )
        guard workingTree.exitCode == 0 else {
            throw AppError.persistence(workingTree.output.isEmpty ? "Unable to inspect deleted files in the working tree." : workingTree.output)
        }

        let staged = try await runGit(
            arguments: ["diff", "--cached", "--name-only", "--diff-filter=D"],
            at: repositoryURL,
            allowFailure: true
        )
        guard staged.exitCode == 0 else {
            throw AppError.persistence(staged.output.isEmpty ? "Unable to inspect staged deleted files." : staged.output)
        }

        let deletedPaths = parseGitPathList(workingTree.output) + parseGitPathList(staged.output)
        var seen = Set<String>()
        return deletedPaths.filter { seen.insert($0).inserted }
    }

    public func localChangesForPull(at repositoryURL: URL) async throws -> [String] {
        let unstaged = try await gitPathList(
            arguments: ["diff", "--name-only"],
            at: repositoryURL,
            failureMessage: "Unable to inspect local unstaged changes."
        )
        let staged = try await gitPathList(
            arguments: ["diff", "--cached", "--name-only"],
            at: repositoryURL,
            failureMessage: "Unable to inspect staged local changes."
        )
        let untracked = try await gitPathList(
            arguments: ["ls-files", "--others", "--exclude-standard"],
            at: repositoryURL,
            failureMessage: "Unable to inspect untracked local files."
        )

        let combined = unstaged + staged + untracked
        var seen = Set<String>()
        return combined
            .filter { !Self.protectedWorkdirMarkerNames.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    public func revertLocalChanges(at repositoryURL: URL) async throws -> GitCommandResult {
        var outputs: [String] = []

        let resetResult = try await runGit(arguments: ["reset", "--hard", "HEAD"], at: repositoryURL, allowFailure: true)
        if resetResult.exitCode != 0 &&
            !resetResult.output.localizedCaseInsensitiveContains("unknown revision") &&
            !resetResult.output.localizedCaseInsensitiveContains("ambiguous argument 'head'") {
            throw AppError.persistence(resetResult.output.isEmpty ? "Unable to revert tracked local changes." : resetResult.output)
        }
        if !resetResult.output.isEmpty {
            outputs.append(resetResult.output)
        }

        let untracked = try await gitPathList(
            arguments: ["ls-files", "--others", "--exclude-standard"],
            at: repositoryURL,
            failureMessage: "Unable to inspect untracked local files."
        )
        .filter { !Self.protectedWorkdirMarkerNames.contains($0) }

        if !untracked.isEmpty {
            var cleanArguments = ["clean", "-fd", "--"]
            cleanArguments.append(contentsOf: untracked)
            let cleanResult = try await runGit(arguments: cleanArguments, at: repositoryURL)
            if !cleanResult.output.isEmpty {
                outputs.append(cleanResult.output)
            }
        }

        let output = outputs.isEmpty ? "Local changes reverted." : outputs.joined(separator: "\n")
        return GitCommandResult(output: output, exitCode: 0)
    }

    public func restoreDeletedPaths(at repositoryURL: URL, paths: [String]) async throws -> GitCommandResult {
        guard !paths.isEmpty else {
            return GitCommandResult(output: "No deleted files to restore.", exitCode: 0)
        }

        var arguments = ["restore", "--source=HEAD", "--staged", "--worktree", "--"]
        arguments.append(contentsOf: paths)
        return try await runGit(arguments: arguments, at: repositoryURL)
    }

    public nonisolated func parseGitPathList(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func fetchOrigin(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        emit("Fetching remote changes from origin...\n", to: onOutput)
        let fetchResult = try await runGit(
            arguments: ["fetch", "origin"],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
        guard fetchResult.exitCode == 0 else {
            throw AppError.persistence(fetchResult.output.isEmpty ? "Git fetch failed." : fetchResult.output)
        }
        return fetchResult
    }

    /// Commits on the upstream branch not in `HEAD` (how far behind). Requires a recent `fetch`.
    public func commitsBehindUpstream(at repositoryURL: URL) async throws -> Int {
        let result = try await runGit(
            arguments: ["rev-list", "--count", "HEAD..@{u}"],
            at: repositoryURL,
            allowFailure: true
        )
        guard result.exitCode == 0,
              let n = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
              n >= 0 else {
            let fallbackRef = try await pullUpstreamReference(at: repositoryURL)
            let fb = try await runGit(
                arguments: ["rev-list", "--count", "HEAD..\(fallbackRef)"],
                at: repositoryURL,
                allowFailure: true
            )
            guard fb.exitCode == 0,
                  let m = Int(fb.output.trimmingCharacters(in: .whitespacesAndNewlines)),
                  m >= 0 else {
                return 0
            }
            return m
        }
        return n
    }

    public func unmergedPaths(at repositoryURL: URL) async throws -> [String] {
        let result = try await runGit(
            arguments: ["diff", "--name-only", "--diff-filter=U"],
            at: repositoryURL,
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            throw AppError.persistence(result.output.isEmpty ? "Unable to list unmerged paths." : result.output)
        }
        return parseGitPathList(result.output)
    }

    public func hasMergeInProgress(at repositoryURL: URL) async -> Bool {
        let mergeHead = try? await runGit(
            arguments: ["rev-parse", "-q", "--verify", "MERGE_HEAD"],
            at: repositoryURL,
            allowFailure: true
        )
        return mergeHead?.exitCode == 0
    }

    public func stashPushIncludingUntracked(
        at repositoryURL: URL,
        message: String = "EFBY Shared Storage — pre-update",
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        emit("Stashing local changes (including untracked)...\n", to: onOutput)
        return try await runGit(
            arguments: ["stash", "push", "-u", "-m", message],
            at: repositoryURL,
            onOutput: onOutput
        )
    }

    public func stashPop(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        emit("Restoring stashed local changes...\n", to: onOutput)
        return try await runGit(arguments: ["stash", "pop"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
    }

    public func stashDrop(at repositoryURL: URL, onOutput: GitOutputHandler? = nil) async throws -> GitCommandResult {
        emit("Dropping applied stash entry...\n", to: onOutput)
        return try await runGit(arguments: ["stash", "drop"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
    }

    public func checkoutConflictSide(
        at repositoryURL: URL,
        path: String,
        keepOurs: Bool,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        let side = keepOurs ? "ours" : "theirs"
        emit("Resolving \(path) using --\(side)...\n", to: onOutput)
        return try await runGit(
            arguments: ["checkout", "--\(side)", "--", path],
            at: repositoryURL,
            onOutput: onOutput
        )
    }

    public func addPaths(_ paths: [String], at repositoryURL: URL, onOutput: GitOutputHandler? = nil) async throws -> GitCommandResult {
        guard !paths.isEmpty else {
            return GitCommandResult(output: "", exitCode: 0)
        }
        var args = ["add", "--"]
        args.append(contentsOf: paths)
        return try await runGit(arguments: args, at: repositoryURL, onOutput: onOutput)
    }

    public func completeMergeCommit(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        emit("Completing merge commit...\n", to: onOutput)
        return try await runGit(
            arguments: ["commit", "--no-edit"],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
    }

    public func mergeAbort(at repositoryURL: URL, onOutput: GitOutputHandler? = nil) async throws -> GitCommandResult {
        emit("Aborting merge...\n", to: onOutput)
        return try await runGit(arguments: ["merge", "--abort"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
    }

    public func pull(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        var outputParts: [String] = []
        let previousHead = try await currentHeadReference(at: repositoryURL)

        let fetchResult = try await fetchOrigin(at: repositoryURL, onOutput: onOutput)
        if !fetchResult.output.isEmpty {
            outputParts.append(fetchResult.output)
        }

        let upstreamReference = try await pullUpstreamReference(at: repositoryURL)
        emit("Merging remote updates (no automatic remote preference on conflicts)...\n", to: onOutput)
        let primaryMerge = try await runGit(
            arguments: ["merge", "--no-edit", upstreamReference],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
        if primaryMerge.exitCode == 0 {
            if !primaryMerge.output.isEmpty {
                outputParts.append(primaryMerge.output)
            }
            let combined = outputParts.isEmpty ? "Git pull completed." : outputParts.joined(separator: "\n")
            let currentHead = try await currentHeadReference(at: repositoryURL)
            let changedPaths = try await changedPathsBetween(
                oldReference: previousHead,
                newReference: currentHead,
                at: repositoryURL
            )
            return GitCommandResult(output: combined, exitCode: 0, changedPaths: changedPaths)
        }

        if primaryMerge.output.localizedCaseInsensitiveContains("refusing to merge unrelated histories") {
            let unrelatedMerge = try await runGit(
                arguments: ["merge", "--no-edit", "--allow-unrelated-histories", upstreamReference],
                at: repositoryURL,
                allowFailure: true,
                onOutput: onOutput
            )
            if unrelatedMerge.exitCode == 0 {
                if !unrelatedMerge.output.isEmpty {
                    outputParts.append(unrelatedMerge.output)
                }
                let combined = outputParts.isEmpty ? "Git pull completed." : outputParts.joined(separator: "\n")
                let currentHead = try await currentHeadReference(at: repositoryURL)
                let changedPaths = try await changedPathsBetween(
                    oldReference: previousHead,
                    newReference: currentHead,
                    at: repositoryURL
                )
                return GitCommandResult(output: combined, exitCode: 0, changedPaths: changedPaths)
            }

            if shouldResolvePullFailureWithRemoteVersion(unrelatedMerge.output) {
                return try await mergeConflictResult(
                    repositoryURL: repositoryURL,
                    outputParts: outputParts + [unrelatedMerge.output]
                )
            }

            throw AppError.persistence(unrelatedMerge.output.isEmpty ? primaryMerge.output : unrelatedMerge.output)
        }

        if shouldResolvePullFailureWithRemoteVersion(primaryMerge.output) {
            if !primaryMerge.output.isEmpty {
                outputParts.append(primaryMerge.output)
            }
            return try await mergeConflictResult(
                repositoryURL: repositoryURL,
                outputParts: outputParts
            )
        }

        throw AppError.persistence(primaryMerge.output)
    }

    /// Fetches `origin` and moves `HEAD` to the upstream ref (same resolution as ``pull``), discarding local commits and tracked changes vs that ref; then removes listed untracked files (protected workdir markers are kept).
    ///
    /// Use for read-only Bitbucket mirror workspaces where the remote must always win over the working tree.
    public func fetchAndHardResetToUpstream(
        at repositoryURL: URL,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        var outputParts: [String] = []
        let previousHead = try await currentHeadReference(at: repositoryURL)

        let fetchResult = try await fetchOrigin(at: repositoryURL, onOutput: onOutput)
        if !fetchResult.output.isEmpty {
            outputParts.append(fetchResult.output)
        }

        let upstreamReference = try await pullUpstreamReference(at: repositoryURL)
        emit("Resetting branch to match \(upstreamReference) (remote overwrites local)...\n", to: onOutput)
        let hard = try await runGit(
            arguments: ["reset", "--hard", upstreamReference],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
        guard hard.exitCode == 0 else {
            throw AppError.persistence(hard.output.isEmpty ? "git reset --hard failed." : hard.output)
        }
        if !hard.output.isEmpty {
            outputParts.append(hard.output)
        }

        let untracked = try await gitPathList(
            arguments: ["ls-files", "--others", "--exclude-standard"],
            at: repositoryURL,
            failureMessage: "Unable to inspect untracked local files."
        )
        .filter { !Self.protectedWorkdirMarkerNames.contains($0) }

        if !untracked.isEmpty {
            var cleanArguments = ["clean", "-fd", "--"]
            cleanArguments.append(contentsOf: untracked)
            let cleanResult = try await runGit(arguments: cleanArguments, at: repositoryURL, onOutput: onOutput)
            if !cleanResult.output.isEmpty {
                outputParts.append(cleanResult.output)
            }
        }

        let currentHead = try await currentHeadReference(at: repositoryURL)
        let changedPaths = try await changedPathsBetween(
            oldReference: previousHead,
            newReference: currentHead,
            at: repositoryURL
        )
        let combined = outputParts.isEmpty ? "Repository reset to match remote." : outputParts.joined(separator: "\n")
        return GitCommandResult(output: combined, exitCode: 0, changedPaths: changedPaths)
    }

    private func mergeConflictResult(
        repositoryURL: URL,
        outputParts: [String]
    ) async throws -> GitCommandResult {
        let pending = try await unmergedPaths(at: repositoryURL)
        let combined = outputParts.joined(separator: "\n\n")
        if pending.isEmpty {
            throw AppError.persistence(combined.isEmpty ? "Merge failed." : combined)
        }
        let message = combined + "\n\nResolve each conflict below (keep local or keep remote), then complete the merge."
        return GitCommandResult(
            output: message,
            exitCode: 1,
            changedPaths: [],
            requiresFullRefresh: false,
            mergeConflictsPending: pending
        )
    }

    public func commitAndPush(
        at repositoryURL: URL,
        message: String,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
#if !os(macOS)
        throw AppError.persistence(
            "Git commit/push no está disponible en iPhone o iPad. Usa la app para Mac para subir cambios al remoto."
        )
#else
        emit("Staging repository changes...\n", to: onOutput)
        _ = try await runGit(arguments: ["add", "."], at: repositoryURL, onOutput: onOutput)

        emit("Creating commit...\n", to: onOutput)
        let commit = try await runGit(
            arguments: ["commit", "-m", message],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
        if commit.exitCode != 0 && !commit.output.localizedCaseInsensitiveContains("nothing to commit") {
            return commit
        }

        emit("Pushing changes to origin...\n", to: onOutput)
        let push = try await runGit(arguments: ["push", "-u", "origin", "HEAD"], at: repositoryURL, onOutput: onOutput)
        let combinedOutput = [commit.output, push.output]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return GitCommandResult(output: combinedOutput, exitCode: push.exitCode)
#endif
    }

    public func configureRepository(at repositoryURL: URL, remoteInput: String) async throws -> GitCommandResult {
        let configuration = try normalizeRemoteInput(remoteInput)
        var messages: [String] = []

        if !FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent(".git").path) {
            let initResult = try await runGit(arguments: ["init", "-b", "main"], at: repositoryURL, allowFailure: true)
            if initResult.exitCode != 0 {
                _ = try await runGit(arguments: ["init"], at: repositoryURL)
                _ = try await runGit(arguments: ["branch", "-M", "main"], at: repositoryURL, allowFailure: true)
            }
            if !initResult.output.isEmpty {
                messages.append(initResult.output)
            }
        }

        let existingRemote = try await runGit(arguments: ["remote", "get-url", "origin"], at: repositoryURL, allowFailure: true)
        if existingRemote.exitCode == 0 {
            let update = try await runGit(arguments: ["remote", "set-url", "origin", configuration.remoteURL], at: repositoryURL)
            if !update.output.isEmpty {
                messages.append(update.output)
            }
        } else {
            let add = try await runGit(arguments: ["remote", "add", "origin", configuration.remoteURL], at: repositoryURL)
            if !add.output.isEmpty {
                messages.append(add.output)
            }
        }

        let fetch = try await runGit(arguments: ["fetch", "origin"], at: repositoryURL, allowFailure: true)
        if !fetch.output.isEmpty {
            messages.append(fetch.output)
        }

        messages.append("Configured Git remote origin -> \(configuration.remoteURL)")
        return GitCommandResult(output: messages.joined(separator: "\n"), exitCode: 0)
    }

    public func connectFlow(
        at repositoryURL: URL,
        remoteInput: String,
        credentials: GitCredentialInput? = nil,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitConnectionFlowResult {
        let gitAvailability = await checkGitAvailability(at: repositoryURL)
        guard gitAvailability.exitCode == 0 else {
            let installURL = URL(string: "https://git-scm.com/download/mac")
            let message = [
                "Git is not installed or is not available in PATH.",
                "Install Git for macOS from \(installURL?.absoluteString ?? "https://git-scm.com/download/mac").",
                gitAvailability.output
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

            return GitConnectionFlowResult(
                state: .gitMissing,
                output: message,
                remoteURL: nil,
                provider: .unknown,
                authKind: .unknown,
                helpURL: installURL
            )
        }

        let configuration = try normalizeRemoteInput(remoteInput)
        let provider = provider(for: configuration.remoteURL)
        let authKind = authenticationKind(for: configuration.remoteURL)
        var messages: [String] = []
        let effectiveRemoteURL = try credentials.map { try applyCredentials($0, to: configuration.remoteURL, provider: provider) } ?? configuration.remoteURL
        let didInitializeRepository = !FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent(".git").path)

        emit("Preparing local repository...\n", to: onOutput)
        if didInitializeRepository {
            emit("Initializing Git repository...\n", to: onOutput)
            let initResult = try await runGit(
                arguments: ["init", "-b", "main"],
                at: repositoryURL,
                allowFailure: true,
                onOutput: onOutput
            )
            if initResult.exitCode != 0 {
                _ = try await runGit(arguments: ["init"], at: repositoryURL, onOutput: onOutput)
                _ = try await runGit(arguments: ["branch", "-M", "main"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
            }
            messages.append("Initialized local Git repository.")
            if !initResult.output.isEmpty {
                messages.append(initResult.output)
            }
        }

        emit("Configuring remote origin...\n", to: onOutput)
        let existingRemote = try await runGit(arguments: ["remote", "get-url", "origin"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
        if existingRemote.exitCode == 0 {
            if existingRemote.output != effectiveRemoteURL {
                _ = try await runGit(arguments: ["remote", "set-url", "origin", effectiveRemoteURL], at: repositoryURL, onOutput: onOutput)
                messages.append("Updated remote origin to \(displayRemoteURL(configuration.remoteURL)).")
            } else {
                messages.append("Remote origin already points to \(displayRemoteURL(configuration.remoteURL)).")
            }
        } else {
            _ = try await runGit(arguments: ["remote", "add", "origin", effectiveRemoteURL], at: repositoryURL, onOutput: onOutput)
            messages.append("Added remote origin -> \(displayRemoteURL(configuration.remoteURL)).")
        }

        emit("Validating remote access...\n", to: onOutput)
        let authProbe = try await runGit(arguments: ["ls-remote", "--heads", "origin"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
        if authProbe.exitCode == 0 {
            messages.append("Remote authentication succeeded.")

            let synchronizationOutput = try await synchronizeRepositoryAfterConnection(
                at: repositoryURL,
                didInitializeRepository: didInitializeRepository,
                onOutput: onOutput
            )
            if !synchronizationOutput.isEmpty {
                messages.append(synchronizationOutput)
            }

            return GitConnectionFlowResult(
                state: .connected,
                output: messages.joined(separator: "\n"),
                remoteURL: displayRemoteURL(configuration.remoteURL),
                provider: provider,
                authKind: authKind,
                helpURL: nil
            )
        }

        if requiresAuthentication(authProbe.output) {
            let helpURL = authenticationHelpURL(for: provider, kind: authKind)
            let credentialInstructions = authKind == .https
                ? credentialInstructions(for: provider, kind: authKind)
                : nil
            messages.append("Authentication is required for \(provider.displayName).")
            if let helpURL {
                messages.append("Open \(helpURL.absoluteString) to complete authentication.")
            }
            if let credentialInstructions {
                messages.append(credentialInstructions)
            }
            if !authProbe.output.isEmpty {
                messages.append(authProbe.output)
            }

            return GitConnectionFlowResult(
                state: .authenticationRequired,
                output: messages.joined(separator: "\n"),
                remoteURL: displayRemoteURL(configuration.remoteURL),
                provider: provider,
                authKind: authKind,
                helpURL: helpURL,
                credentialInstructions: credentialInstructions,
                preferredCredentialMode: preferredCredentialMode(for: provider, kind: authKind)
            )
        }

        throw AppError.persistence(authProbe.output.isEmpty ? "Git remote validation failed." : authProbe.output)
    }

    private func synchronizeRepositoryAfterConnection(
        at repositoryURL: URL,
        didInitializeRepository: Bool,
        onOutput: GitOutputHandler? = nil
    ) async throws -> String {
        let hasLocalHead = try await runGit(arguments: ["rev-parse", "--verify", "HEAD"], at: repositoryURL, allowFailure: true).exitCode == 0
        let needsInitialCheckout = didInitializeRepository || !hasLocalHead

        guard needsInitialCheckout else {
            return ""
        }

        var outputParts: [String] = []
        let deferredMarkerRestore = try await temporarilyRemoveWorkdirMarkersIfNeeded(at: repositoryURL)
        defer {
            deferredMarkerRestore()
        }

        emit("Downloading remote repository contents...\n", to: onOutput)
        let fetchResult = try await runGit(arguments: ["fetch", "origin"], at: repositoryURL, allowFailure: true, onOutput: onOutput)
        if fetchResult.exitCode != 0 {
            throw AppError.persistence(fetchResult.output.isEmpty ? "Git fetch failed while downloading the remote repository contents." : fetchResult.output)
        }
        if !fetchResult.output.isEmpty {
            outputParts.append(fetchResult.output)
        }

        guard let defaultBranch = try await remoteDefaultBranch(at: repositoryURL) else {
            outputParts.append("Remote authenticated successfully, but no default branch was detected for the initial checkout.")
            return outputParts.joined(separator: "\n")
        }

        emit("Checking out remote default branch \(defaultBranch)...\n", to: onOutput)
        let switchResult = try await runGit(
            arguments: ["switch", "-C", defaultBranch, "--track", "origin/\(defaultBranch)"],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
        if switchResult.exitCode == 0 {
            if !switchResult.output.isEmpty {
                outputParts.append(switchResult.output)
            }
            outputParts.append("Downloaded remote contents from origin/\(defaultBranch).")
            return outputParts.joined(separator: "\n")
        }

        let checkoutResult = try await runGit(
            arguments: ["checkout", "-B", defaultBranch, "--track", "origin/\(defaultBranch)"],
            at: repositoryURL,
            allowFailure: true,
            onOutput: onOutput
        )
        if checkoutResult.exitCode == 0 {
            if !checkoutResult.output.isEmpty {
                outputParts.append(checkoutResult.output)
            }
            outputParts.append("Downloaded remote contents from origin/\(defaultBranch).")
            return outputParts.joined(separator: "\n")
        }

        throw AppError.persistence(
            checkoutResult.output.isEmpty
                ? (switchResult.output.isEmpty ? "Unable to check out the remote default branch." : switchResult.output)
                : checkoutResult.output
        )
    }

    private func temporarilyRemoveWorkdirMarkersIfNeeded(
        at repositoryURL: URL
    ) async throws -> @Sendable () -> Void {
        let markerFilenames = ["_directoritrabajo", ".directoritrabajo"]
        let fileManager = FileManager.default
        var pendingRestores: [(originalURL: URL, backupURL: URL)] = []

        for filename in markerFilenames {
            let markerURL = repositoryURL.appendingPathComponent(filename, isDirectory: false)
            guard fileManager.fileExists(atPath: markerURL.path) else {
                continue
            }

            let trackedResult = try await runGit(
                arguments: ["ls-files", "--error-unmatch", "--", filename],
                at: repositoryURL,
                allowFailure: true
            )
            if trackedResult.exitCode == 0 {
                continue
            }

            let backupURL = repositoryURL.appendingPathComponent(".\(filename).pending-checkout", isDirectory: false)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: markerURL, to: backupURL)
            pendingRestores.append((markerURL, backupURL))
        }

        let restoreItems = pendingRestores

        return {
            let restoreFileManager = FileManager.default
            for item in restoreItems {
                guard restoreFileManager.fileExists(atPath: item.backupURL.path) else {
                    continue
                }
                if restoreFileManager.fileExists(atPath: item.originalURL.path) {
                    try? restoreFileManager.removeItem(at: item.backupURL)
                } else {
                    try? restoreFileManager.moveItem(at: item.backupURL, to: item.originalURL)
                }
            }
        }
    }

    private func remoteDefaultBranch(at repositoryURL: URL) async throws -> String? {
        let symrefResult = try await runGit(
            arguments: ["ls-remote", "--symref", "origin", "HEAD"],
            at: repositoryURL,
            allowFailure: true
        )
        if symrefResult.exitCode == 0,
           let branch = parseRemoteDefaultBranch(from: symrefResult.output) {
            return branch
        }

        let remoteShow = try await runGit(arguments: ["remote", "show", "origin"], at: repositoryURL, allowFailure: true)
        if remoteShow.exitCode == 0,
           let branch = parseRemoteDefaultBranch(fromRemoteShow: remoteShow.output) {
            return branch
        }

        let mainHead = try await runGit(arguments: ["ls-remote", "--heads", "origin", "main"], at: repositoryURL, allowFailure: true)
        if mainHead.exitCode == 0, !mainHead.output.isEmpty {
            return "main"
        }

        let masterHead = try await runGit(arguments: ["ls-remote", "--heads", "origin", "master"], at: repositoryURL, allowFailure: true)
        if masterHead.exitCode == 0, !masterHead.output.isEmpty {
            return "master"
        }

        return nil
    }

    public nonisolated func parseRemoteDefaultBranch(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("ref: refs/heads/") else { continue }
            let branchPortion = value.replacingOccurrences(of: "ref: refs/heads/", with: "")
            return branchPortion.components(separatedBy: .whitespaces).first
        }
        return nil
    }

    public nonisolated func parseRemoteDefaultBranch(fromRemoteShow output: String) -> String? {
        for line in output.split(separator: "\n") {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.lowercased().hasPrefix("head branch:") else { continue }
            return value
                .components(separatedBy: ":")
                .dropFirst()
                .joined(separator: ":")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public nonisolated func parseTrackingBranchReference(from output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
    }

    public nonisolated func shouldResolvePullFailureWithRemoteVersion(_ output: String) -> Bool {
        let value = output.lowercased()
        return value.contains("conflict") ||
            value.contains("automatic merge failed") ||
            value.contains("could not apply") ||
            value.contains("overwritten by merge")
    }

    public func remoteURL(at repositoryURL: URL) async throws -> String? {
        let result = try await runGit(arguments: ["remote", "get-url", "origin"], at: repositoryURL, allowFailure: true)
        guard result.exitCode == 0 else {
            return nil
        }
        return result.output.isEmpty ? nil : result.output
    }

    public nonisolated func normalizeRemoteInput(_ input: String) throws -> GitRemoteConfiguration {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.persistence("Enter a Git URL or a git clone command.")
        }

        let candidate = extractRemoteCandidate(from: trimmed)
        let normalized = canonicalizeRemoteURL(candidate)
        return GitRemoteConfiguration(remoteURL: normalized)
    }

    private nonisolated func extractRemoteCandidate(from input: String) -> String {
        let components = input.split(whereSeparator: \.isWhitespace).map(String.init)

        if components.count >= 3, components[0] == "git", components[1] == "clone" {
            if let remote = components.dropFirst(2).first(where: { token in
                token.hasPrefix("git@") || token.hasPrefix("https://") || token.hasPrefix("http://") || token.hasPrefix("ssh://")
            }) {
                return remote
            }
        }

        return input
    }

    private nonisolated func canonicalizeRemoteURL(_ value: String) -> String {
        if value.hasPrefix("git@") || value.hasPrefix("ssh://") {
            return value
        }

        guard var components = URLComponents(string: value), let host = components.host else {
            return value
        }

        if isKnownHostedGitProvider(host) {
            let pathParts = components.path
                .split(separator: "/")
                .map(String.init)

            if pathParts.count >= 2 {
                let owner = pathParts[0]
                let repository = normalizedRepositoryName(pathParts[1])
                components.path = "/\(owner)/\(repository).git"
                components.query = nil
                components.fragment = nil
                return components.string ?? value
            }
        }

        let originalPath = components.path
        let sanitizedPath = normalizedRepositoryPath(originalPath)
        components.path = sanitizedPath
        components.query = nil
        components.fragment = nil

        if sanitizedPath.caseInsensitiveCompare(originalPath) != .orderedSame {
            return components.string ?? value
        }

        if !sanitizedPath.lowercased().hasSuffix(".git") {
            components.path = sanitizedPath + ".git"
            return components.string ?? value
        }

        return components.string ?? value
    }

    public nonisolated func provider(for remoteURL: String) -> GitProvider {
        let lowercased = remoteURL.lowercased()
        if lowercased.contains("bitbucket.org") {
            return .bitbucket
        }
        if lowercased.contains("github.com") {
            return .github
        }
        if lowercased.contains("gitlab.com") {
            return .gitlab
        }
        return .unknown
    }

    public nonisolated func authenticationKind(for remoteURL: String) -> GitAuthenticationKind {
        if remoteURL.hasPrefix("git@") || remoteURL.hasPrefix("ssh://") {
            return .ssh
        }
        if remoteURL.hasPrefix("https://") || remoteURL.hasPrefix("http://") {
            return .https
        }
        return .unknown
    }

    public nonisolated func authenticationHelpURL(for provider: GitProvider, kind: GitAuthenticationKind) -> URL? {
        switch (provider, kind) {
        case (.bitbucket, .ssh):
            return URL(string: "https://bitbucket.org/account/settings/ssh-keys/")
        case (.bitbucket, .https):
            return URL(string: "https://bitbucket.org/account/settings/app-passwords/")
        case (.github, .ssh):
            return URL(string: "https://github.com/settings/keys")
        case (.github, .https):
            return URL(string: "https://github.com/settings/tokens")
        case (.gitlab, .ssh):
            return URL(string: "https://gitlab.com/-/user_settings/ssh_keys")
        case (.gitlab, .https):
            return URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")
        case (.unknown, _), (_, .unknown):
            return nil
        }
    }

    public nonisolated func preferredCredentialMode(
        for provider: GitProvider,
        kind: GitAuthenticationKind
    ) -> GitCredentialMode? {
        guard kind == .https else {
            return nil
        }

        switch provider {
        case .bitbucket, .github, .gitlab, .unknown:
            return .token
        }
    }

    public nonisolated func credentialInstructions(
        for provider: GitProvider,
        kind: GitAuthenticationKind
    ) -> String {
        guard kind == .https else {
            return "This remote requires SSH access. Configure your SSH key or use the repository HTTPS URL if you want to authenticate with a token or password."
        }

        switch provider {
        case .bitbucket:
            return "Bitbucket Cloud works with your Bitbucket username plus an API token or App Password over HTTPS. Use Token / API Key mode in this form."
        case .github:
            return "GitHub no longer accepts account passwords over HTTPS. Use a Personal Access Token, or use Username & Password mode only if your password field contains a valid token."
        case .gitlab:
            return "GitLab works best with a Personal Access Token. Username & Password is available if your GitLab server still accepts it."
        case .unknown:
            return "Use Token / API Key if your Git server provides one. If it expects classic credentials, switch to Username & Password."
        }
    }

    public nonisolated func displayRemoteURL(_ remoteURL: String) -> String {
        guard var components = URLComponents(string: remoteURL), components.scheme?.hasPrefix("http") == true else {
            return remoteURL
        }
        components.user = nil
        components.password = nil
        return components.string ?? remoteURL
    }

    private nonisolated func isKnownHostedGitProvider(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        return lowercased.contains("bitbucket.org") ||
            lowercased.contains("github.com") ||
            lowercased.contains("gitlab.com")
    }

    private nonisolated func normalizedRepositoryName(_ rawValue: String) -> String {
        var value = rawValue
        while value.lowercased().hasSuffix(".git") {
            value.removeLast(4)
        }
        return value
    }

    private nonisolated func normalizedRepositoryPath(_ rawPath: String) -> String {
        let parts = rawPath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            return rawPath
        }

        let owner = parts[0]
        let repository = normalizedRepositoryName(parts[1])
        return "/\(owner)/\(repository)"
    }

    private nonisolated func requiresAuthentication(_ output: String) -> Bool {
        let value = output.lowercased()
        return value.contains("authentication failed") ||
            value.contains("permission denied") ||
            value.contains("could not read from remote repository") ||
            value.contains("repository not found") ||
            value.contains("access denied") ||
            value.contains("403") ||
            value.contains("401") ||
            value.contains("fatal: could not read username")
    }

    private func checkGitAvailability(at repositoryURL: URL) async -> GitCommandResult {
        do {
            return try await runGit(arguments: ["--version"], at: repositoryURL, allowFailure: true)
        } catch {
            return GitCommandResult(output: error.localizedDescription, exitCode: 1)
        }
    }

    private func gitPathList(
        arguments: [String],
        at repositoryURL: URL,
        failureMessage: String
    ) async throws -> [String] {
        let result = try await runGit(arguments: arguments, at: repositoryURL, allowFailure: true)
        guard result.exitCode == 0 else {
            throw AppError.persistence(result.output.isEmpty ? failureMessage : result.output)
        }
        return parseGitPathList(result.output)
    }

    private func pullUpstreamReference(at repositoryURL: URL) async throws -> String {
        let trackingResult = try await runGit(
            arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            at: repositoryURL,
            allowFailure: true
        )
        if trackingResult.exitCode == 0,
           let trackingReference = parseTrackingBranchReference(from: trackingResult.output) {
            return trackingReference
        }

        if let defaultBranch = try await remoteDefaultBranch(at: repositoryURL) {
            return "origin/\(defaultBranch)"
        }

        return "origin/main"
    }

    private func currentHeadReference(at repositoryURL: URL) async throws -> String? {
        let result = try await runGit(
            arguments: ["rev-parse", "--verify", "HEAD"],
            at: repositoryURL,
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            return nil
        }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func changedPathsBetween(
        oldReference: String?,
        newReference: String?,
        at repositoryURL: URL
    ) async throws -> [String] {
        guard let newReference else {
            return []
        }

        let arguments: [String]
        if let oldReference, oldReference != newReference {
            arguments = ["diff", "--name-only", oldReference, newReference]
        } else if oldReference == newReference {
            return []
        } else {
            arguments = ["diff-tree", "--no-commit-id", "--name-only", "-r", newReference]
        }

        let result = try await runGit(arguments: arguments, at: repositoryURL, allowFailure: true)
        guard result.exitCode == 0 else {
            return []
        }
        return parseGitPathList(result.output)
    }

    private nonisolated func applyCredentials(
        _ credentials: GitCredentialInput,
        to remoteURL: String,
        provider: GitProvider
    ) throws -> String {
        guard var components = URLComponents(string: remoteURL),
              components.scheme?.hasPrefix("http") == true else {
            throw AppError.persistence("Credential form is only available for HTTPS Git remotes. Use the web URL of the repository if you want token or password authentication.")
        }

        let trimmedSecret = credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            throw AppError.persistence("Enter the token, API key, or password to continue.")
        }

        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)

        switch credentials.mode {
        case .token:
            let defaultUsername = defaultCredentialUsername(for: provider)
            let effectiveUsername = username.isEmpty ? defaultUsername : username
            guard !effectiveUsername.isEmpty else {
                throw AppError.persistence(tokenUsernameRequirementMessage(for: provider))
            }
            components.user = effectiveUsername
            components.password = trimmedSecret
        case .usernamePassword:
            guard !username.isEmpty else {
                throw AppError.persistence("Enter the Git username to continue.")
            }
            components.user = username
            components.password = trimmedSecret
        }

        guard let configured = components.string else {
            throw AppError.persistence("Unable to apply credentials to the Git remote URL.")
        }
        return configured
    }

    private nonisolated func defaultCredentialUsername(for provider: GitProvider) -> String {
        switch provider {
        case .bitbucket:
            return ""
        case .github:
            return "x-access-token"
        case .gitlab:
            return "oauth2"
        case .unknown:
            return "git"
        }
    }

    private nonisolated func tokenUsernameRequirementMessage(for provider: GitProvider) -> String {
        switch provider {
        case .bitbucket:
            return "Bitbucket needs your username together with the API token or App Password. Enter the username and try again."
        case .github:
            return "Enter a GitHub token, or provide a username if your organization requires one."
        case .gitlab:
            return "Enter a GitLab token, or provide a username if your server requires one."
        case .unknown:
            return "Enter a username together with the token or API key to continue."
        }
    }

    private nonisolated func emit(_ chunk: String, to onOutput: GitOutputHandler?) {
        guard !chunk.isEmpty else { return }
        onOutput?(chunk)
    }

    private func runGit(
        arguments: [String],
        at repositoryURL: URL,
        allowFailure: Bool = false,
        onOutput: GitOutputHandler? = nil
    ) async throws -> GitCommandResult {
        #if !os(macOS)
        let message =
            "Git command-line tools are not available on iOS. Use the Mac app for pull, push, and merge operations."
        if allowFailure {
            return GitCommandResult(output: message, exitCode: 127)
        }
        throw AppError.persistence(message)
        #else
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let state = GitProcessOutputState()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = repositoryURL
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let appendData: @Sendable (Data) -> Void = { data in
                guard !data.isEmpty else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                guard !chunk.isEmpty else { return }
                state.append(chunk)
                onOutput?(chunk)
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                appendData(data)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                appendData(data)
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: AppError.persistence("No se pudo ejecutar git: \(error.localizedDescription)"))
                return
            }

            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                appendData(outputPipe.fileHandleForReading.readDataToEndOfFile())
                appendData(errorPipe.fileHandleForReading.readDataToEndOfFile())

                let output = state.trimmedOutput()
                let result = GitCommandResult(output: output, exitCode: process.terminationStatus)

                guard state.markResumed() else { return }
                if process.terminationStatus == 0 || allowFailure {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: AppError.persistence(output.isEmpty ? "Git fallo con codigo \(process.terminationStatus)." : output))
                }
            }
        }
        #endif
    }
}
