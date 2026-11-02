import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    /// Descarga el archivo fuente `.zip` de Bitbucket Cloud y configura esa carpeta como almacenamiento compartido.
    /// Repos públicos: deja usuario y contraseña/token vacíos. Repos privados: username Bitbucket + **app password** (token de Bitbucket) u otra credencial que la API acepte en Basic Auth — solo el valor del token, sin HTML.
    public func downloadBitbucketHTTPSRepositoryAndConfigure(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String
    ) {
        switch bitbucketPadCoordinator.planInitialDownload(
            cloneHTTPSURL: cloneHTTPSURL,
            branch: branch,
            bitbucketUsername: bitbucketUsername,
            bitbucketAppPassword: bitbucketAppPassword
        ) {
        case .failure(let error):
            errorMessage = error.message
        case .success(let plan):
            Task { await executeBitbucketPadImport(plan) }
        }
    }

    /// Vuelve a descargar el mismo repo Bitbucket y actualiza el almacenamiento compartido (URL/rama/usuario desde el formulario o desde la última descarga; token vacío en pantalla usa el guardado en llavero).
    public func resyncBitbucketSharedFromBitbucket(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String
    ) {
        switch bitbucketPadCoordinator.planResync(
            cloneHTTPSURL: cloneHTTPSURL,
            branch: branch,
            bitbucketUsername: bitbucketUsername,
            bitbucketAppPassword: bitbucketAppPassword,
            hasSharedRepository: sharedRepositoryURL != nil,
            savedCloneHTTPSURL: workspace.bitbucketPadCloneHTTPSURL,
            savedBranch: workspace.bitbucketPadBranch,
            savedUsername: workspace.bitbucketPadUsername
        ) {
        case .failure(let error):
            errorMessage = error.message
        case .success(let plan):
            Task { await executeBitbucketPadImport(plan) }
        }
    }

    func executeBitbucketPadImport(_ plan: BitbucketPadCoordinator.ImportPlan) async {
        isBitbucketArchiveDownloadBusy = true
        errorMessage = nil
        defer { isBitbucketArchiveDownloadBusy = false }

        do {
            let result = try await bitbucketPadCoordinator.download(plan: plan) { [persistenceCoordinator] root in
                try await persistenceCoordinator.ensureWorkdirMarker(in: root)
            }
            bitbucketPadCoordinator.applyMetadata(from: result, to: &workspace)
            configureSharedCollectionsDirectory(result.repositoryRoot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func connectGitRepository(using remoteInput: String) {
        guard let repositoryRoot = sharedRepositoryURL else {
            errorMessage = "Select the shared storage folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "connect"
        gitOutput = ""
        Task {
            do {
                let result = try await gitSessionCoordinator.connectFlow(
                    at: repositoryRoot,
                    remoteInput: remoteInput,
                    credentials: nil,
                    onOutput: makeGitOutputHandler()
                )
                switch result.state {
                case .connected:
                    await completeConnectedGitFlow(
                        at: repositoryRoot,
                        remoteURL: result.remoteURL,
                        connectOutput: result.output,
                        successMessage: "Git configured, synchronized, and refreshed without deleting the current workspaces."
                    )
                case .authenticationRequired:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        if result.authKind == .https {
                            self.gitCredentialPrompt = GitCredentialPrompt(
                                remoteInput: remoteInput,
                                remoteURL: result.remoteURL ?? remoteInput,
                                provider: result.provider,
                                authKind: result.authKind,
                                message: result.output,
                                instructions: result.credentialInstructions ?? "Enter the credentials required by your Git provider to continue.",
                                preferredMode: result.preferredCredentialMode ?? .token,
                                helpURL: result.helpURL
                            )
                            self.infoMessage = "Git needs credentials. Complete the form to connect this repository."
                        } else {
                            if let helpURL = result.helpURL {
                                Self.openExternalURL(helpURL)
                            }
                            self.errorMessage = "Git needs authentication with \(result.provider.displayName). The browser was opened with the recommended setup page."
                        }
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                case .gitMissing:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        if let helpURL = result.helpURL {
                            Self.openExternalURL(helpURL)
                        }
                        self.errorMessage = "Git is not installed. The browser was opened with the install page for macOS."
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGitBusy = false
                    self.gitBusyOperation = nil
                }
            }
        }
    }

    public func submitGitCredentials(mode: GitCredentialMode, username: String, secret: String) {
        guard let repositoryRoot = sharedRepositoryURL,
              let prompt = gitCredentialPrompt else {
            errorMessage = "Start the Git connection flow first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "credentials"
        gitOutput = ""
        Task {
            do {
                let result = try await gitSessionCoordinator.connectFlow(
                    at: repositoryRoot,
                    remoteInput: prompt.remoteInput,
                    credentials: GitCredentialInput(mode: mode, username: username, secret: secret),
                    onOutput: makeGitOutputHandler()
                )

                switch result.state {
                case .connected:
                    await completeConnectedGitFlow(
                        at: repositoryRoot,
                        remoteURL: result.remoteURL,
                        connectOutput: result.output,
                        successMessage: "Git authenticated, synchronized, and refreshed successfully."
                    )
                case .authenticationRequired:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        self.gitCredentialPrompt = GitCredentialPrompt(
                            remoteInput: prompt.remoteInput,
                            remoteURL: result.remoteURL ?? prompt.remoteURL,
                            provider: result.provider,
                            authKind: result.authKind,
                            message: result.output,
                            instructions: result.credentialInstructions ?? prompt.instructions,
                            preferredMode: result.preferredCredentialMode ?? prompt.preferredMode,
                            helpURL: result.helpURL ?? prompt.helpURL
                        )
                        self.errorMessage = "The provided credentials were not accepted. Review the form and try again."
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                case .gitMissing:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        self.gitCredentialPrompt = nil
                        self.errorMessage = "Git is not installed. The browser was opened with the install page for macOS."
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGitBusy = false
                    self.gitBusyOperation = nil
                }
            }
        }
    }

    public func cancelGitCredentialPrompt() {
        gitCredentialPrompt = nil
    }

    public func exportCollectionsToSharedDirectory() {
        Task {
            do {
                guard let workspaceRoot = activeWorkspaceDirectoryURL else {
                    throw AppError.persistence("Select a workspace inside the shared repository first.")
                }
                var exportSnapshot = workspace
                exportSnapshot.flows = flowsPortableForPersistence(workspace.flows, collections: workspace.collections)
                try await persistenceCoordinator.saveSharedGitSnapshot(
                    collections: workspace.collections,
                    environments: workspace.environments,
                    utilities: workspace.utilityLibraries,
                    flows: exportSnapshot.flows,
                    snapshot: exportSnapshot,
                    to: workspaceRoot
                )
                self.infoMessage = "Workspace exported to \(workspaceRoot.path)."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func gitStatus() {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "status"
        gitOutput = ""
        Task {
            do {
                let result = try await gitSessionCoordinator.status(
                    at: root,
                    onOutput: makeGitOutputHandler()
                )
                await MainActor.run {
                    if result.output.isEmpty {
                        self.appendGitOutput("Working tree clean.\n")
                    }
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func gitPull() {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        gitSessionCoordinator.resetStashFlags()
        isGitBusy = true
        gitBusyOperation = "pull"
        gitOutput = ""
        let contextID = workspaceContextID
        Task {
            defer { self.finishGitBusyState() }
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            do {
                if self.isBitbucketPadMirrorWorkspace {
                    self.gitSessionCoordinator.resetStashFlags()
                    self.gitPullRecoveryPrompt = nil
                    try await self.applyPullOutcome(
                        try await self.gitSessionCoordinator.performHardResetPull(
                            at: root,
                            onOutput: self.makeGitOutputHandler()
                        ),
                        at: root, expectedContextID: contextID
                    )
                    return
                }

                let gate = await evaluateSharedGitPushGate(at: root)
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.applyPushGate(gate)
                }

                let changedPaths = try await gitSessionCoordinator.localChangesForPull(at: root)
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
                if !changedPaths.isEmpty {
                    await MainActor.run {
                        guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                        self.gitPullRecoveryPrompt = GitPullRecoveryPrompt(changedPaths: changedPaths)
                        self.finishGitBusyState()
                    }
                    return
                }

                try await applyPullOutcome(
                    try await gitSessionCoordinator.performPull(
                        at: root,
                        restoringDeletedPaths: nil,
                        stashPopWhenDone: false,
                        onOutput: makeGitOutputHandler()
                    ),
                    at: root, expectedContextID: contextID
                )
            } catch {
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func confirmGitPullRecoverDeletedFiles() {
        guard let root = sharedRepositoryURL,
              gitPullRecoveryPrompt != nil else {
            return
        }

        gitPullRecoveryPrompt = nil
        gitSessionCoordinator.resetStashFlags()
        isGitBusy = true
        gitBusyOperation = "pull"
        gitOutput = ""
        let contextID = workspaceContextID
        Task {
            defer { self.finishGitBusyState() }
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            do {
                let revertResult = try await gitSessionCoordinator.revertLocalChanges(at: root)
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
                if !revertResult.output.isEmpty {
                    await MainActor.run {
                        guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                        self.appendGitOutput(revertResult.output)
                        self.appendGitOutput("\n")
                    }
                }
                try await applyPullOutcome(
                    try await gitSessionCoordinator.performPull(
                        at: root,
                        restoringDeletedPaths: nil,
                        stashPopWhenDone: false,
                        onOutput: makeGitOutputHandler()
                    ),
                    at: root, expectedContextID: contextID
                )
            } catch {
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func continueGitPullWithoutRecoveringDeletedFiles() {
        gitPullRecoveryPrompt = nil
    }

    public func cancelGitPullRecoveryPrompt() {
        gitPullRecoveryPrompt = nil
    }

    private func evaluateSharedGitPushGate(at root: URL) async -> GitWorkspaceCoordinator.SharedGitPushGate {
        await gitSessionCoordinator.evaluatePushGate(at: root, isReadOnlyMirror: isBitbucketPadMirrorWorkspace)
    }

    private func applyPushGate(_ gate: GitWorkspaceCoordinator.SharedGitPushGate) {
        canPushToSharedGit = gate.canPush
        gitPushDisabledReason = gate.reason
        isSharedGitMergeInProgress = gate.mergeInProgress
    }

    private func finishGitBusyState() {
        isGitBusy = false
        gitBusyOperation = nil
    }

    public func refreshSharedGitPushAvailability() {
        guard let root = sharedRepositoryURL else {
            canPushToSharedGit = false
            gitPushDisabledReason = "Configure the shared Git repository folder first."
            isSharedGitMergeInProgress = false
            return
        }

        if isBitbucketPadMirrorWorkspace {
            canPushToSharedGit = false
            gitPushDisabledReason =
                "Este workspace está vinculado a Bitbucket en solo lectura: no se suben cambios al remoto."
            isSharedGitMergeInProgress = false
            return
        }

        let contextID = workspaceContextID
        Task {
            let gate = await evaluateSharedGitPushGate(at: root)
            await MainActor.run {
                guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                self.applyPushGate(gate)
            }
        }
    }

    public func confirmGitPullStashAndUpdate() {
        guard let root = sharedRepositoryURL,
              gitPullRecoveryPrompt != nil else {
            return
        }

        gitPullRecoveryPrompt = nil
        gitSessionCoordinator.markPendingStashPopAfterPull(true)
        isGitBusy = true
        gitBusyOperation = "pull"
        gitOutput = ""
        let contextID = workspaceContextID
        Task {
            defer { self.finishGitBusyState() }
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            do {
                let stashResult = try await gitSessionCoordinator.stashPushForUpdate(
                    at: root,
                    onOutput: makeGitOutputHandler()
                )
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
                if !stashResult.output.isEmpty {
                    await MainActor.run {
                        guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                        self.appendGitOutput(stashResult.output)
                        self.appendGitOutput("\n")
                    }
                }
                guard stashResult.exitCode == 0 else {
                    await MainActor.run {
                        guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                        self.errorMessage = stashResult.output.isEmpty ? "Git stash failed." : stashResult.output
                        self.gitSessionCoordinator.resetStashFlags()
                        self.finishGitBusyState()
                    }
                    await MainActor.run {
                        guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                        self.refreshSharedGitPushAvailability()
                    }
                    return
                }
                try await applyPullOutcome(
                    try await gitSessionCoordinator.performPull(
                        at: root,
                        restoringDeletedPaths: nil,
                        stashPopWhenDone: true,
                        onOutput: makeGitOutputHandler()
                    ),
                    at: root, expectedContextID: contextID
                )
            } catch {
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    self.gitSessionCoordinator.resetStashFlags()
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    guard self.workspaceContextID == contextID, !Task.isCancelled else { return }
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func gitResolveMergeConflict(path: String, keepLocal: Bool) {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "pull"
        Task {
            do {
                let outcome = try await gitSessionCoordinator.resolveMergeConflict(
                    path: path,
                    keepLocal: keepLocal,
                    at: root,
                    onOutput: makeGitOutputHandler()
                )

                if let mergeCommitOutput = outcome.mergeCommitOutput {
                    await MainActor.run {
                        self.appendGitOutput(mergeCommitOutput)
                        self.appendGitOutput("\n")
                    }
                }
                if outcome.shouldRefreshWorkspace {
                    await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)
                }
                if let stashDropOutput = outcome.stashDropOutput {
                    await MainActor.run {
                        self.appendGitOutput(stashDropOutput)
                        self.appendGitOutput("\n")
                    }
                }
                if outcome.stalledAfterStashPop {
                    await MainActor.run {
                        self.gitMergeConflictPaths = outcome.remainingConflicts
                        self.appendGitOutput("Resolve stash pop conflicts below.\n")
                        self.finishGitBusyState()
                    }
                    refreshSharedGitPushAvailability()
                    return
                }
                if let conflictsResolvedMessage = outcome.conflictsResolvedMessage {
                    await MainActor.run {
                        self.appendGitOutput(conflictsResolvedMessage)
                    }
                }

                await MainActor.run {
                    self.gitMergeConflictPaths = outcome.remainingConflicts
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            }
        }
    }

    public func gitAbortSharedMerge() {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "pull"
        Task {
            do {
                try await gitSessionCoordinator.abortMerge(at: root, onOutput: makeGitOutputHandler())
                await MainActor.run {
                    self.gitMergeConflictPaths = []
                    self.appendGitOutput("Merge aborted.\n")
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            }
        }
    }

    public func gitCommitAndPush() {
#if !os(macOS)
        errorMessage =
            "En iPhone e iPad la app no crea commits ni hace push al remoto Git. Publica cambios desde la app para Mac."
        return
#endif
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        if isBitbucketPadMirrorWorkspace {
            errorMessage =
                "Este workspace está vinculado a Bitbucket en solo lectura: no se suben cambios al remoto."
            return
        }

        isGitBusy = true
        gitBusyOperation = "push"
        gitOutput = ""
        Task {
            do {
                let gate = await evaluateSharedGitPushGate(at: root)
                if !gate.canPush {
                    await MainActor.run {
                        self.errorMessage = gate.reason
                            ?? "Push is blocked until the remote is merged locally (run Update) and the working tree is clean."
                        self.applyPushGate(gate)
                        self.finishGitBusyState()
                    }
                    return
                }

                await MainActor.run {
                    self.canPushToSharedGit = true
                    self.gitPushDisabledReason = nil
                    self.isSharedGitMergeInProgress = gate.mergeInProgress
                }

                guard let workspaceRoot = activeWorkspaceDirectoryURL else {
                    throw AppError.persistence("Select a workspace before pushing.")
                }
                var gitSnapshot = workspace
                gitSnapshot.flows = flowsPortableForPersistence(workspace.flows, collections: workspace.collections)
                try await persistenceCoordinator.saveSharedGitSnapshot(
                    collections: pushableCollectionsSnapshot(),
                    environments: pushableEnvironmentsSnapshot(),
                    utilities: workspace.utilityLibraries,
                    flows: gitSnapshot.flows,
                    snapshot: gitSnapshot,
                    to: workspaceRoot
                )
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
                let workspaceName = workspace.activeWorkspaceName ?? "workspace"
                let message = "Update \(workspaceName) \(formatter.string(from: Date()))"
                let result = try await gitSessionCoordinator.commitAndPush(
                    at: root,
                    message: message,
                    onOutput: makeGitOutputHandler()
                )
                await MainActor.run {
                    if result.output.isEmpty {
                        self.appendGitOutput("Commit and push completed.\n")
                    }
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    @MainActor
    private static func openExternalURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }

    private func pushableCollectionsSnapshot() -> [CollectionModel] {
        workspace.collections
    }

    private func pushableEnvironmentsSnapshot() -> [EnvironmentProfile] {
        persistedSharedEnvironments
    }

    private func appendGitOutput(_ chunk: String) {
        gitSessionCoordinator.append(chunk: chunk, to: &gitOutput)
    }

    private func makeGitOutputHandler() -> GitOutputHandler {
        let contextID = workspaceContextID
        return gitSessionCoordinator.makeOutputHandler { [weak self] chunk in
            guard let self, self.workspaceContextID == contextID else { return }
            self.appendGitOutput(chunk)
        }
    }

    private func applyPullOutcome(_ outcome: GitSessionCoordinator.PullOutcome, at root: URL, expectedContextID: UUID) async throws {
        guard workspaceContextID == expectedContextID, !Task.isCancelled else { return }
        gitMergeConflictPaths = []

        switch outcome {
        case .mergeConflictsPending(let paths, let output):
            await MainActor.run {
                guard self.workspaceContextID == expectedContextID, !Task.isCancelled else { return }
                self.gitMergeConflictPaths = paths
                if !output.isEmpty {
                    if !(self.gitOutput?.isEmpty == false) {
                        self.gitOutput = output
                    } else {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(output)
                    }
                }
                self.finishGitBusyState()
            }
            await MainActor.run {
                guard self.workspaceContextID == expectedContextID, !Task.isCancelled else { return }
                self.refreshSharedGitPushAvailability()
            }

        case .stashPopStalled(let message, let conflictPaths):
            await MainActor.run {
                guard self.workspaceContextID == expectedContextID, !Task.isCancelled else { return }
                self.gitMergeConflictPaths = conflictPaths
                self.appendGitOutput(message)
                self.finishGitBusyState()
            }
            await MainActor.run {
                guard self.workspaceContextID == expectedContextID, !Task.isCancelled else { return }
                self.refreshSharedGitPushAvailability()
            }

        case .completed(let extraOutputParts, let commandOutput, let emptySuccessMessage, let requiresFullRefresh, let changedPaths):
            var outputParts = extraOutputParts

            if requiresFullRefresh {
                await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)
            } else if let selectiveRefreshMessage = await applySelectiveGitPullRefresh(
                changedPaths: changedPaths,
                repositoryRoot: root
            ) {
                outputParts.append(selectiveRefreshMessage)
            }

            guard workspaceContextID == expectedContextID, !Task.isCancelled else { return }
            if !commandOutput.isEmpty && gitOutput?.isEmpty != false {
                outputParts.append(commandOutput)
            }

            await MainActor.run {
                guard self.workspaceContextID == expectedContextID, !Task.isCancelled else { return }
                if outputParts.isEmpty {
                    if commandOutput.isEmpty {
                        self.appendGitOutput(emptySuccessMessage)
                    }
                } else {
                    if self.gitOutput?.isEmpty == false {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                    } else {
                        self.gitOutput = outputParts.joined(separator: "\n\n")
                    }
                }
                self.finishGitBusyState()
            }
            await MainActor.run {
                guard self.workspaceContextID == expectedContextID, !Task.isCancelled else { return }
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    private func applySelectiveGitPullRefresh(changedPaths: [String], repositoryRoot: URL) async -> String? {
        let contextID = workspaceContextID
        do {
            try await persistenceCoordinator.ensureWorkdirMarker(in: repositoryRoot)
            guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
            var workspaceNames = try await persistenceCoordinator.workspaceNames(in: repositoryRoot)
            guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
            if workspaceNames.isEmpty {
                let defaultWorkspace = try await persistenceCoordinator.ensureDefaultWorkspace(in: repositoryRoot)
                guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
                workspaceNames = [defaultWorkspace]
            }
            availableWorkspaceNames = workspaceNames
            let remote = try await gitSessionCoordinator.remoteURL(at: repositoryRoot)
            guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
            gitRemoteDescription = remote

            guard let activeWorkspaceName = workspace.activeWorkspaceName else {
                return nil
            }

            guard workspaceNames.contains(activeWorkspaceName) else {
                if let nextWorkspace = workspaceNames.first { selectWorkspace(named: nextWorkspace) }
                return nil
            }

            let workspacePrefix = "\(activeWorkspaceName)/"
            let relevantPaths = changedPaths.filter { $0.hasPrefix(workspacePrefix) }
            guard !relevantPaths.isEmpty else {
                return nil
            }

            let workspaceRoot = repositoryRoot.appendingPathComponent(activeWorkspaceName, isDirectory: true)
            var notes: [String] = []

            if relevantPaths.contains(where: { $0.hasPrefix("\(workspacePrefix)collections/") }) {
                let importedCollections = try await persistenceCoordinator.loadCollections(from: workspaceRoot)
                guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
                let reloadedCollections = SharedWorkspaceCoordinator.preserveCollectionIdentifiers(
                    from: workspace.collections,
                    in: importedCollections
                )
                workspace.collections = reloadedCollections
                reconcileOpenTabsWithWorkspace(
                    affectedCollectionIDs: Set(reloadedCollections.map(\.id)),
                    affectedEnvironmentIDs: nil
                )
            }

            if relevantPaths.contains(where: { $0.hasPrefix("\(workspacePrefix)environments/") }) {
                let hasLocalEnvironmentDrafts =
                    hasPendingEnvironmentStoreChanges ||
                    tabs.contains(where: hasPendingEnvironmentChanges(for:))

                if hasLocalEnvironmentDrafts {
                    notes.append("Skipped reloading environment files from pull because local environment drafts are still in memory.")
                } else {
                    let reloadedEnvironments = try await persistenceCoordinator.loadEnvironments(from: workspaceRoot)
                    guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
                    workspace.environments = reloadedEnvironments
                    persistedSharedEnvironments = reloadedEnvironments
                    if workspace.activeEnvironmentID == nil || !reloadedEnvironments.contains(where: { $0.id == workspace.activeEnvironmentID }) {
                        workspace.activeEnvironmentID = reloadedEnvironments.first(where: \.isEnabled)?.id
                    }
                    sanitizeEnvironmentSelections()
                    reconcileOpenTabsWithWorkspace(
                        affectedCollectionIDs: nil,
                        affectedEnvironmentIDs: Set(reloadedEnvironments.map(\.id))
                    )
                }
            }

            return notes.isEmpty ? nil : notes.joined(separator: "\n")
        } catch {
            guard workspaceContextID == contextID, !Task.isCancelled else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func completeConnectedGitFlow(
        at repositoryRoot: URL,
        remoteURL: String?,
        connectOutput: String,
        successMessage: String
    ) async {
        var outputParts = [connectOutput].filter { !$0.isEmpty }

        do {
            let pullResult = try await gitSessionCoordinator.pull(at: repositoryRoot, onOutput: makeGitOutputHandler())
            if !pullResult.mergeConflictsPending.isEmpty {
                if !pullResult.output.isEmpty {
                    outputParts.append(pullResult.output)
                }
                await MainActor.run {
                    self.gitMergeConflictPaths = pullResult.mergeConflictsPending
                    self.gitCredentialPrompt = nil
                    self.gitRemoteDescription = remoteURL
                    if self.gitOutput?.isEmpty == false {
                        if !outputParts.isEmpty {
                            if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                                self.appendGitOutput("\n")
                            }
                            self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                        }
                    } else {
                        self.gitOutput = outputParts.joined(separator: "\n\n")
                    }
                    self.infoMessage = successMessage
                    self.isGitBusy = false
                    self.gitBusyOperation = nil
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
                return
            }

            if !pullResult.output.isEmpty {
                outputParts.append(pullResult.output)
            }
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)

            await MainActor.run {
                self.gitCredentialPrompt = nil
                self.gitRemoteDescription = remoteURL
                if self.gitOutput?.isEmpty == false {
                    if !outputParts.isEmpty {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                    }
                } else {
                    self.gitOutput = outputParts.joined(separator: "\n\n")
                }
                self.infoMessage = successMessage
                self.isGitBusy = false
                self.gitBusyOperation = nil
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        } catch {
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)

            await MainActor.run {
                self.gitCredentialPrompt = nil
                self.gitRemoteDescription = remoteURL
                if self.gitOutput?.isEmpty == false {
                    if !outputParts.isEmpty {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                    }
                } else {
                    self.gitOutput = outputParts.joined(separator: "\n\n")
                }
                self.errorMessage = error.localizedDescription
                self.isGitBusy = false
                self.gitBusyOperation = nil
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    func validateRepositoryDirectory(_ url: URL, requireEmpty: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.persistence("The selected shared storage directory does not exist.")
        }

        guard requireEmpty else {
            return
        }

        if let recognizedExistingWorkdir = try? isRecognizedExistingWorkdir(url),
           recognizedExistingWorkdir {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        if !contents.isEmpty {
            throw AppError.persistence("Select an empty folder for the initial shared storage.")
        }
    }

    private func isRecognizedExistingWorkdir(_ url: URL) throws -> Bool {
        let markerURL = url.appendingPathComponent(SharedCollectionsRepository.workdirMarkerFilename, isDirectory: false)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            return true
        }

        let hiddenDotMarkerURL = url.appendingPathComponent(".directoritrabajo", isDirectory: false)
        if FileManager.default.fileExists(atPath: hiddenDotMarkerURL.path) {
            return true
        }

        let gitURL = url.appendingPathComponent(".git", isDirectory: false)
        if FileManager.default.fileExists(atPath: gitURL.path) {
            return true
        }

        return false
    }
}
