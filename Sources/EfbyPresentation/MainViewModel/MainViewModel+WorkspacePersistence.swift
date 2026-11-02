import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    public func loadWorkspace() async {
        let contextID = workspaceContextID
        do {
            let loaded = try await persistenceCoordinator.loadLocal()
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            workspace = loaded
            restoreSharedRepositoryAccessIfNeeded()
            persistedSharedEnvironments = workspace.environments
            if workspace.activeEnvironmentID == nil {
                workspace.activeEnvironmentID = workspace.environments.first(where: \.isEnabled)?.id
            }
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            restoreDraftTabsIfNeeded()
            openFirstRequestIfNeeded()
        } catch {
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        didFinishInitialWorkspaceLoad = true
    }

    /// En iPad, si el workspace tiene Bitbucket guardado y token en llavero, vuelve a descargar y sustituye el almacenamiento compartido; si no, recarga solo desde disco.
    public func reloadWorkspaceResyncingBitbucketIfNeeded() async {
        if isBitbucketPadMirrorWorkspace,
           sharedRepositoryURL != nil,
           let token = BitbucketPadCredentialStore.loadAPIToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            let effectiveURL = (workspace.bitbucketPadCloneHTTPSURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !effectiveURL.isEmpty else {
                await loadWorkspace()
                return
            }
            switch bitbucketPadCoordinator.planResync(
                cloneHTTPSURL: effectiveURL,
                branch: workspace.bitbucketPadBranch ?? "",
                bitbucketUsername: workspace.bitbucketPadUsername ?? "",
                bitbucketAppPassword: token,
                hasSharedRepository: true,
                savedCloneHTTPSURL: workspace.bitbucketPadCloneHTTPSURL,
                savedBranch: workspace.bitbucketPadBranch,
                savedUsername: workspace.bitbucketPadUsername
            ) {
            case .failure(let error):
                errorMessage = error.message
                await loadWorkspace()
            case .success(let plan):
                await executeBitbucketPadImport(plan)
            }
            return
        }
        await loadWorkspace()
    }

    public func refreshSharedData(forceInfoMessage: Bool = true) {
        Task {
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: forceInfoMessage)
            await MainActor.run {
                self.restoreDraftTabsIfNeeded()
                self.openFirstRequestIfNeeded()
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    public func importDocument(from url: URL) async {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            switch try documentImportCoordinator.importData(data, fileExtension: url.pathExtension) {
            case .environment(let importedEnvironment):
                upsertEnvironment(importedEnvironment)
                persistWorkspace(syncSharedData: false)
                infoMessage = "Environment '\(importedEnvironment.name)' imported successfully."
            case .collection(let imported):
                workspace.collections.append(imported)
                persistWorkspace()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func configureSharedCollectionsDirectory(_ url: URL) {
        do {
            try validateRepositoryDirectory(url, requireEmpty: sharedRepositoryURL == nil)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard repositoryDirectoryAccess.grantAccess(to: url) else {
            errorMessage = "macOS did not grant access to the selected folder. Try choosing it again."
            return
        }

        guard let bookmarkData = repositoryDirectoryAccess.makeBookmarkData(for: url) else {
            repositoryDirectoryAccess.releaseAccess()
            errorMessage = "Could not save folder permission for the selected directory. Try choosing it again."
            return
        }

        workspace.sharedCollectionsDirectoryPath = url.path
        workspace.sharedCollectionsDirectoryBookmarkData = bookmarkData
        Task {
            do {
                try await self.persistenceCoordinator.ensureWorkdirMarker(in: url)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: true)
        }
        persistWorkspace(syncSharedData: false)
        infoMessage = "Shared storage configured: \(url.path)"
    }

    public func createWorkspace(named name: String) {
        guard let repositoryRoot = sharedRepositoryURL else {
            errorMessage = "Configure the Git repository folder first."
            return
        }

        let contextID = workspaceContextID
        Task {
            do {
                let createdName = try await persistenceCoordinator.createWorkspace(named: name, in: repositoryRoot)
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
                selectWorkspace(named: createdName)
            } catch {
                guard workspaceContextID == contextID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    public func selectWorkspace(named name: String) {
        guard sharedRepositoryURL != nil else { return }
        snapshotOpenTabsIntoDrafts()
        if !isChangingWorkspace {
            workspaceTransitionFallback = (workspace, persistedSharedEnvironments)
        }
        workspaceContextID = UUID()
        let contextID = workspaceContextID
        workspaceLoadTask?.cancel()
        cancelAllRunningFlowExecutions()
        flowRunTasks.removeAll()
        flowRunSessions.removeAll()
        flowExecutionHighlightElementIDs.removeAll()
        workspaceFlowBatchCaseTranscripts.removeAll()
        for tab in tabs { invalidateExecution(for: tab) }
        workspace.activeWorkspaceName = name
        tabs.removeAll()
        selectedTabID = nil
        workspace.collections = []
        workspace.environments = []
        workspace.utilityLibraries = []
        workspace.flows = []
        workspace.globalVariables = []
        workspace.history = []
        workspace.activeEnvironmentID = nil
        persistedSharedEnvironments = []
        isChangingWorkspace = true
        workspaceLoadTask = Task {
            let flushed = await flushPendingWorkspacePersistence()
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            guard flushed else {
                restoreWorkspaceAfterFailedTransition()
                return
            }
            let loaded = await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: true)
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            isChangingWorkspace = false
            guard loaded else {
                restoreWorkspaceAfterFailedTransition()
                return
            }
            workspaceTransitionFallback = nil
            persistWorkspace(syncSharedData: false)
            restoreDraftTabsIfNeeded()
            openFirstRequestIfNeeded()
            refreshSharedGitPushAvailability()
        }
    }

    private func restoreWorkspaceAfterFailedTransition() {
        isChangingWorkspace = false
        if let fallback = workspaceTransitionFallback {
            workspace = fallback.workspace
            persistedSharedEnvironments = fallback.environments
        }
        workspaceTransitionFallback = nil
        restoreDraftTabsIfNeeded()
        openFirstRequestIfNeeded()
    }

    public func importCollectionsFromFolder(_ url: URL) {
        Task {
            do {
                let imported = try await persistenceCoordinator.importCollections(from: url)
                guard !imported.isEmpty else {
                    await MainActor.run {
                        self.errorMessage = "No valid Postman collection JSON files were found in the selected folder."
                    }
                    return
                }

                let existingNames = Set(self.workspace.collections.map(\.info.name))
                let newCollections = imported.filter { !existingNames.contains($0.info.name) }
                self.workspace.collections.append(contentsOf: newCollections)
                self.persistWorkspace()
                self.infoMessage = "Imported \(newCollections.count) collections from \(url.lastPathComponent)."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func loadCollectionsFromSharedDirectory() {
        Task {
            await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: true)
        }
    }

    @discardableResult
    public func flushStateForApplicationTermination() async -> Bool {
        let closing = Array(pendingTabCloseTasks.values)
        for task in closing { await task.value }
        snapshotOpenTabsIntoDrafts(enqueue: false)
        persistWorkspace(syncSharedData: false, immediately: true)
        return await flushPendingWorkspacePersistence()
    }

    func persistDraft(for tab: RequestTabState, syncNow: Bool = false) {
        updateDraft(for: tab)
        persistWorkspace(syncSharedData: false)
    }

    func updateDraft(for tab: RequestTabState) {
        guard let activeWorkspaceName = workspace.activeWorkspaceName else {
            return
        }

        switch requestTabsCoordinator.resolveDraftMutation(
            tab: tab,
            activeWorkspaceName: activeWorkspaceName,
            drafts: workspace.requestDrafts,
            requestsEquivalent: requestsEquivalentForPersistence
        ) {
        case .removeCollectionDraft(let nodeID, let collectionID):
            removeDraft(nodeID: nodeID, collectionID: collectionID)
        case .update(let index, let draft):
            workspace.requestDrafts[index] = draft
        case .append(let draft):
            workspace.requestDrafts.append(draft)
        }

    }

    func snapshotOpenTabsIntoDrafts(enqueue: Bool = true) {
        for tab in tabs { updateDraft(for: tab) }
        if enqueue, !tabs.isEmpty { persistWorkspace(syncSharedData: false) }
    }

    func removeDraft(nodeID: UUID?, collectionID: UUID?) {
        guard let activeWorkspaceName = workspace.activeWorkspaceName,
              let nodeID,
              let collectionID else {
            return
        }

        workspace.requestDrafts.removeAll {
            $0.workspaceName == activeWorkspaceName &&
            $0.collectionID == collectionID &&
            $0.nodeID == nodeID
        }
    }

    func removeStandaloneDraft(tabID: UUID) {
        guard let activeWorkspaceName = workspace.activeWorkspaceName else {
            return
        }

        workspace.requestDrafts.removeAll {
            $0.workspaceName == activeWorkspaceName &&
            $0.tabID == tabID &&
            $0.collectionID == nil &&
            $0.nodeID == nil
        }
    }

    func draftState(for nodeID: UUID, collectionID: UUID) -> RequestDraftState? {
        requestTabsCoordinator.draftState(
            nodeID: nodeID,
            collectionID: collectionID,
            workspaceName: workspace.activeWorkspaceName,
            drafts: workspace.requestDrafts
        )
    }

    func standaloneDraftStates() -> [RequestDraftState] {
        requestTabsCoordinator.standaloneDraftStates(
            workspaceName: workspace.activeWorkspaceName,
            drafts: workspace.requestDrafts
        )
    }

    private func savedRequestNode(nodeID: UUID, collectionID: UUID) -> CollectionNode? {
        guard let collection = workspace.collections.first(where: { $0.id == collectionID }) else {
            return nil
        }
        return find(nodeID: nodeID, in: collection.items)
    }

    func persistWorkspace(syncSharedData: Bool = true, immediately: Bool = false) {
        persistWorkspace(syncSharedCollections: syncSharedData, syncSharedEnvironments: syncSharedData,
                         syncSharedFlows: syncSharedData, syncSharedUtilities: syncSharedData, immediately: immediately)
    }

    func persistWorkspace(
        syncSharedCollections: Bool = true,
        syncSharedEnvironments: Bool = true,
        syncSharedFlows: Bool = true,
        syncSharedUtilities: Bool = true,
        immediately: Bool = false
    ) {
        let contextID = workspaceContextID
        var snapshot = workspace
        snapshot.flows = flowsPortableForPersistence(snapshot.flows, collections: snapshot.collections)
        let options = WorkspacePersistenceOptions(syncSharedCollections: syncSharedCollections,
            syncSharedEnvironments: syncSharedEnvironments, syncSharedFlows: syncSharedFlows,
            syncSharedUtilities: syncSharedUtilities)
        persistenceCoordinator.schedulePersistence(snapshot: snapshot, workspaceRoot: activeWorkspaceDirectoryURL,
            options: options, immediately: immediately) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let receipt):
                    self.confirmSuccessfulPersistence(receipt)
                case .failure(let error):
                    guard self.workspaceContextID == contextID else { return }
                    self.workspacePersistenceErrorMessage = error.localizedDescription
                    self.errorMessage = error.localizedDescription
                }
            }
    }

    private func confirmSuccessfulPersistence(_ receipt: WorkspacePersistenceReceipt) {
        guard receipt.localSnapshot.activeWorkspaceName == workspace.activeWorkspaceName,
              receipt.workspaceRoot?.standardizedFileURL == activeWorkspaceDirectoryURL?.standardizedFileURL else { return }
        let shared = receipt.sharedSnapshot ?? receipt.localSnapshot
        if receipt.options.syncSharedEnvironments {
            persistedSharedEnvironments = shared.environments
            for environment in shared.environments {
                synchronizePersistedEnvironmentBaseline(environmentID: environment.id, variables: environment.variables)
            }
        }
        for tab in tabs {
            if let collectionID = tab.sourceCollectionID, let nodeID = tab.sourceNodeID {
                if receipt.options.syncSharedCollections,
                   let collection = shared.collections.first(where: { $0.id == collectionID }),
                   let node = find(nodeID: nodeID, in: collection.items) {
                    tab.persistedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)
                }
            } else if let draft = receipt.localSnapshot.requestDrafts.first(where: { $0.tabID == tab.id }) {
                tab.persistedRequest = draft.request
                tab.persistedSelectedEnvironmentID = draft.selectedEnvironmentID
            }
        }
        for tab in tabs { updateDraft(for: tab) }
        if errorMessage == workspacePersistenceErrorMessage { errorMessage = nil }
        workspacePersistenceErrorMessage = nil
    }

    @discardableResult
    func flushPendingWorkspacePersistence() async -> Bool {
        do {
            try await persistenceCoordinator.flush()
            return true
        } catch {
            workspacePersistenceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshPersistedVariableStoresFromDisk() async -> Bool {
        let contextID = workspaceContextID
        guard await flushPendingWorkspacePersistence() else { return false }
        guard workspaceContextID == contextID, !Task.isCancelled else { return false }

        do {
            let persistedWorkspace = try await persistenceCoordinator.loadLocal()
            guard workspaceContextID == contextID, !Task.isCancelled else { return false }
            applyPersistedVariableStores(from: persistedWorkspace)
            return true
        } catch {
            guard workspaceContextID == contextID, !Task.isCancelled else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func applyPersistedVariableStores(from persistedWorkspace: WorkspaceState) {
        workspace.globalVariables = persistedWorkspace.globalVariables

        let persistedCollectionVariables = Dictionary(
            uniqueKeysWithValues: persistedWorkspace.collections.map { ($0.id, $0.variables) }
        )
        for index in workspace.collections.indices {
            guard let variables = persistedCollectionVariables[workspace.collections[index].id] else {
                continue
            }
            workspace.collections[index].variables = variables
        }

        let previousActiveEnvironmentID = workspace.activeEnvironmentID
        let previousVariablesByEnvironmentID = Dictionary(
            uniqueKeysWithValues: workspace.environments.map { ($0.id, $0.variables) }
        )

        workspace.environments = persistedWorkspace.environments

        if let activeEnvironmentID = persistedWorkspace.activeEnvironmentID,
           workspace.environments.contains(where: { $0.id == activeEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = activeEnvironmentID
        } else if let currentActiveEnvironmentID = workspace.activeEnvironmentID,
                  workspace.environments.contains(where: { $0.id == currentActiveEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = currentActiveEnvironmentID
        } else {
            workspace.activeEnvironmentID = workspace.environments.first(where: \.isEnabled)?.id
        }

        for environment in workspace.environments {
            let previousVariables = previousVariablesByEnvironmentID[environment.id]
            guard previousVariables != environment.variables else {
                continue
            }

            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environment.id,
                previousVariables: previousVariables,
                updatedVariables: environment.variables,
                excluding: UUID()
            )
        }

        sanitizeEnvironmentSelections()

        for tab in tabs {
            let currentSelection = tab.selectedEnvironmentID ?? previousActiveEnvironmentID
            let resolvedEnvironmentID = tab.selectedEnvironmentID
                ?? (currentSelection != previousActiveEnvironmentID ? currentSelection : workspace.activeEnvironmentID)
                ?? workspace.activeEnvironmentID
            tab.pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
            tab.persistedEnvironmentVariables = savedEnvironmentBaseline(for: tab)
        }
    }

    private func restoreSharedRepositoryAccessIfNeeded() {
        if let bookmarkData = workspace.sharedCollectionsDirectoryBookmarkData,
           let restoreResult = repositoryDirectoryAccess.restore(
            bookmarkData: bookmarkData,
            refreshStaleBookmark: Self.makeSecurityScopedBookmarkData(for:)
           ) {
            workspace.sharedCollectionsDirectoryPath = restoreResult.url.path
            if let refreshedBookmarkData = restoreResult.refreshedBookmarkData {
                workspace.sharedCollectionsDirectoryBookmarkData = refreshedBookmarkData
                persistWorkspace(syncSharedCollections: false, syncSharedEnvironments: false)
            }
            return
        }

        // A local app update can invalidate an app-scoped bookmark while the
        // previously selected directory remains accessible under normal OS permissions.
        // Revalidate that saved location instead of discarding the selected workspace.
        guard let path = workspace.sharedCollectionsDirectoryPath, path.hasPrefix("/"),
              repositoryDirectoryAccess.grantAccess(to: URL(fileURLWithPath: path, isDirectory: true)) else {
            repositoryDirectoryAccess.releaseAccess()
            return
        }

        if let restoredURL = repositoryDirectoryAccess.url,
           let refreshedBookmarkData = Self.makeSecurityScopedBookmarkData(for: restoredURL) {
            workspace.sharedCollectionsDirectoryPath = restoredURL.path
            workspace.sharedCollectionsDirectoryBookmarkData = refreshedBookmarkData
            persistWorkspace(syncSharedCollections: false, syncSharedEnvironments: false)
        }
    }

    private static func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
        SecurityScopedDirectoryAccess().makeBookmarkData(for: url)
    }

    @discardableResult
    private func loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: Bool = false) async -> Bool {
        let contextID = workspaceContextID
        guard let workspaceRoot = activeWorkspaceDirectoryURL else {
            return false
        }

        do {
            let loaded = try await sharedWorkspaceCoordinator.loadSharedContent(
                workspaceRoot: workspaceRoot,
                existingCollections: workspace.collections,
                existingUtilities: workspace.utilityLibraries,
                existingFlows: workspace.flows,
                currentActiveEnvironmentID: workspace.activeEnvironmentID,
                forceInfoMessage: forceInfoMessage,
                activeWorkspaceName: workspace.activeWorkspaceName
            )

            guard workspaceContextID == contextID, !Task.isCancelled else { return false }
            try await sharedWorkspaceCoordinator.applyPendingSaves(loaded.pendingSaves)
            guard workspaceContextID == contextID, !Task.isCancelled else { return false }

            workspace.collections = loaded.collections
            workspace.environments = loaded.environments
            workspace.utilityLibraries = loaded.utilityLibraries
            workspace.flows = loaded.flows
            persistedSharedEnvironments = loaded.persistedEnvironments
            workspace.activeEnvironmentID = loaded.activeEnvironmentID

            if let globalVariables = loaded.globalVariables {
                workspace.globalVariables = globalVariables
            }
            if let history = loaded.history {
                workspace.history = history
            }
            if let requestDrafts = loaded.requestDrafts {
                // A failed shared save can leave a newer, recoverable draft in the local checkpoint.
                for draft in requestDrafts where !workspace.requestDrafts.contains(where: { local in
                    guard local.workspaceName == draft.workspaceName else { return false }
                    if let collectionID = local.collectionID, let nodeID = local.nodeID {
                        return draft.collectionID == collectionID && draft.nodeID == nodeID
                    }
                    return local.id == draft.id || (local.tabID != nil && local.tabID == draft.tabID)
                }) {
                    workspace.requestDrafts.append(draft)
                }
            }

            reconcileOpenTabsWithWorkspace()
            sanitizeEnvironmentSelections()

            if let infoMessage = loaded.infoMessage {
                self.infoMessage = infoMessage
            }
            return true
        } catch {
            guard workspaceContextID == contextID, !Task.isCancelled else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reconcileOpenTabsWithWorkspace(
        affectedCollectionIDs: Set<UUID>? = nil,
        affectedEnvironmentIDs: Set<UUID>? = nil
    ) {
        for tab in tabs {
            let hasDraft: Bool
            if let collectionID = tab.sourceCollectionID, let nodeID = tab.sourceNodeID {
                hasDraft = draftState(for: nodeID, collectionID: collectionID) != nil
            } else {
                hasDraft = false
            }
            let matchesPersistedBaseline =
                requestsEquivalentForPersistence(tab.persistedRequest, tab.request)
                && tab.selectedEnvironmentID == tab.persistedSelectedEnvironmentID
                && environmentCoordinator.variablesEquivalent(tab.pendingEnvironmentVariables, tab.persistedEnvironmentVariables)

            guard !hasDraft, matchesPersistedBaseline else {
                continue
            }

            let shouldRefreshRequest: Bool
            if let affectedCollectionIDs, let collectionID = tab.sourceCollectionID {
                shouldRefreshRequest = affectedCollectionIDs.contains(collectionID)
            } else {
                shouldRefreshRequest = affectedCollectionIDs == nil
            }

            let selectedEnvironmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID
            let shouldRefreshEnvironment: Bool
            if let affectedEnvironmentIDs, let selectedEnvironmentID {
                shouldRefreshEnvironment = affectedEnvironmentIDs.contains(selectedEnvironmentID)
            } else {
                shouldRefreshEnvironment = affectedEnvironmentIDs == nil
            }

            if shouldRefreshRequest,
               let collectionID = tab.sourceCollectionID,
               let nodeID = tab.sourceNodeID,
               let node = savedRequestNode(nodeID: nodeID, collectionID: collectionID) {
                let savedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)
                tab.request = savedRequest
                tab.persistedRequest = savedRequest
                tab.editorRefreshToken = UUID()
            }

            if shouldRefreshEnvironment {
                let environmentVariables = environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments)
                tab.pendingEnvironmentVariables = environmentVariables
                tab.persistedEnvironmentVariables = environmentVariables
            }
        }
    }

    func ensureActiveWorkspaceExistsIfNeeded() async throws {
        guard let repositoryRoot = sharedRepositoryURL else {
            return
        }

        if let activeWorkspaceName = workspace.activeWorkspaceName,
           !activeWorkspaceName.isEmpty {
            return
        }

        let defaultWorkspaceName = try await persistenceCoordinator.ensureDefaultWorkspace(in: repositoryRoot)
        let workspaceNames = try await persistenceCoordinator.workspaceNames(in: repositoryRoot)
        workspace.activeWorkspaceName = defaultWorkspaceName
        availableWorkspaceNames = workspaceNames
        try await persistenceCoordinator.saveLocal(workspace)
    }

    func refreshWorkspacesAndLoadCurrent(forceInfoMessage: Bool) async {
        let contextID = workspaceContextID
        restoreSharedRepositoryAccessIfNeeded()

        guard let repositoryRoot = sharedRepositoryURL else {
            availableWorkspaceNames = []
            gitRemoteDescription = nil
            return
        }

        do {
            let context = try await sharedWorkspaceCoordinator.refreshRepositoryContext(
                repositoryRoot: repositoryRoot,
                currentWorkspace: workspace
            )

            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            availableWorkspaceNames = context.workspaceNames
            if let activeWorkspaceName = context.activeWorkspaceName {
                workspace.activeWorkspaceName = activeWorkspaceName
            }
            if context.shouldPersistLocalWorkspace {
                try await persistenceCoordinator.saveLocal(workspace)
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
            }
            gitRemoteDescription = context.gitRemoteDescription
            await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: forceInfoMessage)
        } catch {
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
