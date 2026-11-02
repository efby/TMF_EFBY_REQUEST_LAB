import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    public func hasPendingRequestChanges(for tab: RequestTabState) -> Bool {
        hasPendingRequestEditorChanges(for: tab)
    }

    public func hasPendingRequestEditorChanges(for tab: RequestTabState) -> Bool {
        !requestsEquivalentForPersistence(tab.persistedRequest, tab.request)
    }

    public func newRequest() {
        let tab = RequestTabState(
            request: APIRequestModel(
                name: "Untitled Request",
                method: .get,
                url: "https://postman-echo.com/get"
            ),
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistPendingChanges(for: tab)
    }

    public func newRequest(in collection: CollectionModel) {
        guard let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        let request = APIRequestModel(
            name: "New Request",
            method: .get,
            url: "https://postman-echo.com/get"
        )
        let node = CollectionNode(
            name: request.name,
            kind: .request,
            request: request
        )

        workspace.collections[collectionIndex].items.append(node)

        let tab = RequestTabState(
            request: request,
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedRequest: request,
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            sourceCollectionID: collection.id,
            sourceNodeID: node.id
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistWorkspace()
    }

    public func duplicateCurrentRequest() {
        guard let currentTab else { return }
        let duplicated = RequestTabState(
            request: APIRequestModel(
                name: "\(currentTab.request.name) Copy",
                transportKind: currentTab.request.transportKind,
                httpRequestTargetKind: currentTab.request.httpRequestTargetKind,
                method: currentTab.request.method,
                url: currentTab.request.url,
                queryItems: currentTab.request.queryItems,
                pathVariables: currentTab.request.pathVariables,
                headers: currentTab.request.headers,
                cookies: currentTab.request.cookies,
                auth: currentTab.request.auth,
                body: currentTab.request.body,
                scripts: currentTab.request.scripts,
                localVariables: currentTab.request.localVariables,
                timeoutSeconds: currentTab.request.timeoutSeconds,
                retryOn206Count: currentTab.request.retryOn206Count,
                retryOn206DelayMilliseconds: currentTab.request.retryOn206DelayMilliseconds,
                tlsValidationMode: currentTab.request.tlsValidationMode,
                minimumTLSVersion: currentTab.request.minimumTLSVersion,
                webSocketSubprotocols: currentTab.request.webSocketSubprotocols,
                webSocketOpenTimeoutSeconds: currentTab.request.webSocketOpenTimeoutSeconds,
                webSocketReconnectAttempts: currentTab.request.webSocketReconnectAttempts,
                webSocketReconnectIntervalMilliseconds: currentTab.request.webSocketReconnectIntervalMilliseconds,
                webSocketMaximumMessageSizeMB: currentTab.request.webSocketMaximumMessageSizeMB,
                webSocketPingIntervalSeconds: currentTab.request.webSocketPingIntervalSeconds,
                webSocketKeepAliveMessage: currentTab.request.webSocketKeepAliveMessage,
                webSocketKeepAliveIntervalSeconds: currentTab.request.webSocketKeepAliveIntervalSeconds,
                awsAccessPortalURLTemplate: currentTab.request.awsAccessPortalURLTemplate
            ),
            selectedEnvironmentID: currentTab.selectedEnvironmentID,
            pendingEnvironmentVariables: currentTab.pendingEnvironmentVariables,
            persistedRequest: APIRequestModel(
                name: "\(currentTab.request.name) Copy",
                transportKind: currentTab.request.transportKind,
                httpRequestTargetKind: currentTab.request.httpRequestTargetKind,
                method: currentTab.request.method,
                url: currentTab.request.url,
                queryItems: currentTab.request.queryItems,
                pathVariables: currentTab.request.pathVariables,
                headers: currentTab.request.headers,
                cookies: currentTab.request.cookies,
                auth: currentTab.request.auth,
                body: currentTab.request.body,
                scripts: currentTab.request.scripts,
                localVariables: currentTab.request.localVariables,
                timeoutSeconds: currentTab.request.timeoutSeconds,
                retryOn206Count: currentTab.request.retryOn206Count,
                retryOn206DelayMilliseconds: currentTab.request.retryOn206DelayMilliseconds,
                tlsValidationMode: currentTab.request.tlsValidationMode,
                minimumTLSVersion: currentTab.request.minimumTLSVersion,
                webSocketSubprotocols: currentTab.request.webSocketSubprotocols,
                webSocketOpenTimeoutSeconds: currentTab.request.webSocketOpenTimeoutSeconds,
                webSocketReconnectAttempts: currentTab.request.webSocketReconnectAttempts,
                webSocketReconnectIntervalMilliseconds: currentTab.request.webSocketReconnectIntervalMilliseconds,
                webSocketMaximumMessageSizeMB: currentTab.request.webSocketMaximumMessageSizeMB,
                webSocketPingIntervalSeconds: currentTab.request.webSocketPingIntervalSeconds,
                webSocketKeepAliveMessage: currentTab.request.webSocketKeepAliveMessage,
                webSocketKeepAliveIntervalSeconds: currentTab.request.webSocketKeepAliveIntervalSeconds,
                awsAccessPortalURLTemplate: currentTab.request.awsAccessPortalURLTemplate
            ),
            persistedSelectedEnvironmentID: currentTab.selectedEnvironmentID,
            persistedEnvironmentVariables: currentTab.pendingEnvironmentVariables,
            sourceCollectionID: currentTab.sourceCollectionID
        )
        tabs.append(duplicated)
        selectedTabID = duplicated.id
        persistPendingChanges(for: duplicated)
    }

    public func closeTab(_ tab: RequestTabState) {
        guard pendingTabCloseTasks[tab.id] == nil else { return }
        invalidateExecution(for: tab)
        persistPendingChanges(for: tab)
        let contextID = workspaceContextID
        pendingTabCloseTasks[tab.id] = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { self.pendingTabCloseTasks[tab.id] = nil }
            guard await self.flushPendingWorkspacePersistence(), self.workspaceContextID == contextID else { return }
            self.finishClosingTab(tab)
        }
    }

    private func finishClosingTab(_ tab: RequestTabState) {
        if let collectionID = tab.sourceCollectionID,
           let nodeID = tab.sourceNodeID {
            removeDraft(nodeID: nodeID, collectionID: collectionID)
        } else {
            removeStandaloneDraft(tabID: tab.id)
        }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id {
            selectedTabID = tabs.last?.id
        }
        if tabs.isEmpty {
            newRequest()
        } else {
            persistWorkspace(syncSharedData: false, immediately: true)
        }
    }

    public func open(request node: CollectionNode, in collection: CollectionModel) async {
        let contextID = workspaceContextID
        guard !isChangingWorkspace else { return }
        guard await refreshPersistedVariableStoresFromDisk() else { return }
        guard workspaceContextID == contextID, !Task.isCancelled else { return }
        openRequestImmediately(node, in: collection)
    }

    private func openRequestImmediately(_ node: CollectionNode, in collection: CollectionModel) {
        guard var request = node.request else { return }
        let draft = draftState(for: node.id, collectionID: collection.id)
        if let draft {
            request = draft.request
        }
        request.scripts = CollectionScriptSupport.mergeScripts(node.scripts, request.scripts)

        let savedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)

        if let existing = tabs.first(where: { $0.sourceNodeID == node.id }) {
            selectedTabID = existing.id
            return
        }

        let selectedEnvironmentID = draft?.selectedEnvironmentID ?? workspace.activeEnvironmentID
        let persistedSelectedEnvironmentID = draft?.persistedSelectedEnvironmentID
            ?? draft?.selectedEnvironmentID
            ?? workspace.activeEnvironmentID

        let tab = RequestTabState(
            request: request,
            selectedEnvironmentID: selectedEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments),
            persistedRequest: draft?.persistedRequest ?? savedRequest,
            persistedSelectedEnvironmentID: persistedSelectedEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: persistedSelectedEnvironmentID, in: workspace.environments),
            sourceCollectionID: collection.id,
            sourceNodeID: node.id
        )
        tabs.append(tab)
        selectedTabID = tab.id
    }

    public func open(history entry: HistoryEntry) {
        let tab = RequestTabState(
            request: entry.request,
            response: entry.response,
            consoleLogs: ["Loaded from history: \(entry.createdAt.formatted())"],
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedRequest: entry.request,
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments)
        )
        tabs.append(tab)
        selectedTabID = tab.id
    }

    public func saveCurrentRequest() {
        guard let tab = currentTab else { return }
        persistRequestToWorkspace(for: tab, preferredCollectionID: nil, immediately: true)
    }

    private func persistRequestToWorkspace(for tab: RequestTabState, preferredCollectionID: UUID?, immediately: Bool = false) {
        var targetCollectionID = tab.sourceCollectionID
        let previousNodeID = tab.sourceNodeID

        if targetCollectionID == nil {
            targetCollectionID = preferredCollectionID ?? workspace.collections.first?.id
        }

        guard let collectionID = targetCollectionID,
              let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collectionID }) else {
            updateDraft(for: tab)
            persistWorkspace(syncSharedData: false, immediately: immediately)
            return
        }

        var node = tab.sourceNodeID.flatMap {
            find(nodeID: $0, in: workspace.collections[collectionIndex].items)
        } ?? CollectionNode(
            id: tab.sourceNodeID ?? UUID(),
            name: tab.request.name,
            kind: .request
        )
        node.name = tab.request.name
        node.request = tab.request
        node.scripts = tab.request.scripts
        node.auth = tab.request.auth

        if let sourceNodeID = tab.sourceNodeID,
           workspace.collections[collectionIndex].items.contains(where: { contains(nodeID: sourceNodeID, in: $0) }) {
            workspace.collections[collectionIndex].items = workspace.collections[collectionIndex].items.map {
                update(nodeID: sourceNodeID, in: $0, with: node)
            }
        } else {
            workspace.collections[collectionIndex].items.append(node)
            tab.sourceNodeID = node.id
            tab.sourceCollectionID = collectionID
        }

        removeDraft(nodeID: previousNodeID, collectionID: collectionID)
        removeDraft(nodeID: tab.sourceNodeID, collectionID: collectionID)
        removeStandaloneDraft(tabID: tab.id)
        updateDraft(for: tab)
        persistWorkspace(syncSharedCollections: true, syncSharedEnvironments: false,
                         syncSharedFlows: false, syncSharedUtilities: false, immediately: immediately)
    }

    public func sendCurrentRequest() {
        guard let tabID = currentTab?.id else { return }
        sendRequest(forTabID: tabID)
    }

    /// Envía la petición HTTP/Lambda o inicia conexión WebSocket de la **pestaña indicada** (p. ej. iPad con varias pestañas sin depender solo de `selectedTabID`).
    public func sendRequest(forTabID tabID: UUID) {
        guard !isChangingWorkspace, let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let contextID = workspaceContextID
        let executionID = UUID()
        tab.executionID = executionID
        tab.task?.cancel()
        tab.isSending = true
        #if os(macOS)
        if NSApp != nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        #endif

        tab.task = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            guard await self.refreshPersistedVariableStoresFromDisk() else {
                if self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) { tab.isSending = false }
                return
            }
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            self.refreshTabEnvironmentSnapshotFromWorkspace(for: tab)

            switch tab.request.transportKind {
            case .http, .invokeLambda:
                self.send(tab: tab, contextID: contextID, executionID: executionID)
            case .webSocket:
                self.connectWebSocket(tab: tab, executionID: executionID)
            }
        }
    }

    private func send(tab: RequestTabState, contextID: UUID, executionID: UUID) {
        tab.isSending = true
        persistDraft(for: tab, syncNow: true)
        let methodLabel = tab.request.isLambdaInvoke ? HTTPMethod.post.rawValue : tab.request.method.rawValue
        let envLine = "Entorno: \(executionEnvironmentDisplayName(for: tab))"
        tab.consoleLogs = [envLine, "URL plantilla: \(tab.request.url)", "Enviando \(methodLabel)…"]

        let collection = collection(for: tab)
        let effectiveRequest = CollectionScriptSupport.enrichedRequest(
            from: tab.request,
            collection: collection,
            sourceNodeID: tab.sourceNodeID
        )
        ensureEnvironmentExistsIfRequired(for: tab, collection: collection, request: effectiveRequest)
        let globals = workspace.globalVariables
        let environment = environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments)
        let collectionVariables = collection?.variables ?? []

        tab.task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }

            do {
                guard await self.flushPendingWorkspacePersistence() else {
                    if self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) { tab.isSending = false }
                    return
                }
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                let outcome = try await requestTabCoordinator.execute(
                    request: effectiveRequest,
                    globals: globals,
                    collectionVariables: collectionVariables,
                    environmentVariables: environment,
                    workspaceEnvironments: self.workspace.environments,
                    activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                    utilityLibraries: self.workspace.utilityLibraries
                )

                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }

                tab.response = outcome.response
                tab.rawRequestText = outcome.rawRequest
                tab.rawResponseText = outcome.rawResponse
                if let updatedRequestHeaders = outcome.updatedRequestHeaders {
                    tab.request.headers = updatedRequestHeaders
                }
                if let updatedRequestQueryItems = outcome.updatedRequestQueryItems {
                    tab.request.queryItems = updatedRequestQueryItems
                }
                if let updatedRequestBody = outcome.updatedRequestBody {
                    tab.request.body = updatedRequestBody
                }
                let tail = outcome.logs.isEmpty ? ["Request completed successfully."] : outcome.logs
                tab.consoleLogs = [envLine] + tail
                self.applyExecutionVariableUpdates(
                    to: tab,
                    updatedGlobals: outcome.updatedGlobals,
                    updatedCollection: outcome.updatedCollection,
                    updatedEnvironment: outcome.updatedEnvironment,
                    updatedEnvironments: outcome.updatedEnvironments,
                    activeEnvironmentID: outcome.activeEnvironmentID,
                    updatedLocal: outcome.updatedLocal
                )
                self.workspace.history.insert(
                    HistoryEntry(request: tab.request, response: outcome.response),
                    at: 0
                )
                self.workspace.history = Array(self.workspace.history.prefix(100))
                self.persistWorkspace(syncSharedData: false, immediately: true)
                _ = await self.flushPendingWorkspacePersistence()
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) else { return }
                tab.isSending = false
            } catch is CancellationError {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) else { return }
                tab.consoleLogs = [envLine, "URL plantilla: \(tab.request.url)", "Request cancelled."]
                tab.isSending = false
            } catch {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) else { return }
                tab.consoleLogs = [envLine, "URL plantilla: \(tab.request.url)", "Error: \(error.localizedDescription)"]
                tab.isSending = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func cancelCurrentRequest() {
        guard let currentTab else { return }
        cancelRequest(forTabID: currentTab.id)
    }

    /// Cancela envío HTTP en curso o desconecta WebSocket de la pestaña indicada (misma semántica que en Mac).
    public func cancelRequest(forTabID tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        switch tab.request.transportKind {
        case .http, .invokeLambda:
            guard tab.isSending else { return }
            tab.executionID = UUID()
            tab.task?.cancel()
            tab.task = nil
            tab.isSending = false
            tab.consoleLogs.append("Request cancelled.")
        case .webSocket:
            disconnectWebSocket(tab: tab)
        }
    }

    func isCurrentExecution(_ tab: RequestTabState, contextID: UUID, executionID: UUID) -> Bool {
        workspaceContextID == contextID && tab.executionID == executionID && tabs.contains { $0 === tab }
    }

    func invalidateExecution(for tab: RequestTabState) {
        tab.executionID = UUID()
        tab.task?.cancel()
        tab.task = nil
        cancelWebSocketTasks(for: tab)
        if let connection = tab.webSocketConnection {
            Task { await connection.disconnect() }
        }
        tab.webSocketConnection = nil
        tab.webSocketConnectionState = .disconnected
        tab.isSending = false
    }

    public func revertPendingChanges(for tab: RequestTabState) {
        tab.request = tab.persistedRequest
        tab.editorRefreshToken = UUID()
        persistDraft(for: tab, syncNow: true)
    }

    public func deleteHistoryEntry(_ entry: HistoryEntry) {
        workspace.history.removeAll { $0.id == entry.id }
        persistWorkspace(syncSharedData: false)
    }

    public func clearHistory() {
        workspace.history.removeAll()
        persistWorkspace(syncSharedData: false)
    }

    public func saveResponseToDisk() {
        #if os(macOS)
        guard let tab = currentTab else { return }

        if tab.request.transportKind == .webSocket {
            let transcript = tab.webSocketTranscript
                .map { "[\($0.createdAt.formatted(date: .omitted, time: .standard))] \($0.direction.rawValue.uppercased()): \($0.body)" }
                .joined(separator: "\n\n")
            guard !transcript.isEmpty else { return }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "websocket-transcript.txt"

            if panel.runModal() == .OK, let url = panel.url {
                do {
                    try transcript.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        guard let response = tab.response else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = response.suggestedDownloadFilename ?? "response.txt"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try response.body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        #else
        errorMessage = "Saving responses to disk is not available in this build. Use the Mac app for now."
        #endif
    }

    func openFirstRequestIfNeeded() {
        guard tabs.isEmpty else { return }
        if let pair = firstRequestNode() {
            openRequestImmediately(pair.node, in: pair.collection)
        } else {
            newRequest()
        }
    }

    private func firstRequestNode() -> (collection: CollectionModel, node: CollectionNode)? {
        for collection in workspace.collections {
            if let node = firstRequest(in: collection.items) {
                return (collection, node)
            }
        }
        return nil
    }

    func restoreDraftTabsIfNeeded() {
        for draft in standaloneDraftStates() {
            let tabID = draft.tabID ?? draft.id
            guard !tabs.contains(where: { $0.id == tabID }) else { continue }

            let selectedEnvironmentID = draft.selectedEnvironmentID ?? workspace.activeEnvironmentID
            let persistedSelectedEnvironmentID = draft.persistedSelectedEnvironmentID
                ?? draft.selectedEnvironmentID
                ?? workspace.activeEnvironmentID

            let tab = RequestTabState(
                id: tabID,
                request: draft.request,
                selectedEnvironmentID: selectedEnvironmentID,
                pendingEnvironmentVariables: environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments),
                persistedRequest: draft.persistedRequest ?? draft.request,
                persistedSelectedEnvironmentID: persistedSelectedEnvironmentID,
                persistedEnvironmentVariables: environmentCoordinator.variables(for: persistedSelectedEnvironmentID, in: workspace.environments)
            )
            tabs.append(tab)
        }

        for draft in workspace.requestDrafts {
            guard let collectionID = draft.collectionID,
                  let nodeID = draft.nodeID,
                  let collection = workspace.collections.first(where: { $0.id == collectionID }),
                  let node = find(nodeID: nodeID, in: collection.items),
                  !tabs.contains(where: { $0.sourceNodeID == nodeID }) else {
                continue
            }

            let savedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)
            let request = draft.request
            let selectedEnvironmentID = draft.selectedEnvironmentID ?? workspace.activeEnvironmentID
            let persistedSelectedEnvironmentID = draft.persistedSelectedEnvironmentID
                ?? draft.selectedEnvironmentID
                ?? workspace.activeEnvironmentID
            let tab = RequestTabState(
                id: draft.tabID ?? draft.id,
                request: request,
                selectedEnvironmentID: selectedEnvironmentID,
                pendingEnvironmentVariables: environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments),
                persistedRequest: draft.persistedRequest ?? savedRequest,
                persistedSelectedEnvironmentID: persistedSelectedEnvironmentID,
                persistedEnvironmentVariables: environmentCoordinator.variables(for: persistedSelectedEnvironmentID, in: workspace.environments),
                sourceCollectionID: collectionID,
                sourceNodeID: nodeID
            )
            tabs.append(tab)
        }

        if selectedTabID == nil {
            selectedTabID = tabs.last?.id
        }
    }

    private func firstRequest(in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.kind == .request {
                return node
            }
            if let nested = firstRequest(in: node.children) {
                return nested
            }
        }
        return nil
    }

    private func collectionVariables(for tab: RequestTabState) -> [VariableValue] {
        guard let collectionID = tab.sourceCollectionID,
              let collection = workspace.collections.first(where: { $0.id == collectionID }) else {
            return []
        }
        return collection.variables
    }

    func collection(for tab: RequestTabState) -> CollectionModel? {
        guard let collectionID = tab.sourceCollectionID else {
            return nil
        }
        return workspace.collections.first(where: { $0.id == collectionID })
    }

    public func persistPendingChanges(for tab: RequestTabState) {
        if tab.sourceCollectionID != nil || tab.sourceNodeID != nil {
            persistRequestToWorkspace(for: tab, preferredCollectionID: tab.sourceCollectionID)
        } else {
            persistDraft(for: tab)
        }
    }

    func requestsEquivalentForPersistence(_ lhs: APIRequestModel, _ rhs: APIRequestModel) -> Bool {
        requestTabsCoordinator.requestsEquivalentForPersistence(lhs, rhs)
    }
}
