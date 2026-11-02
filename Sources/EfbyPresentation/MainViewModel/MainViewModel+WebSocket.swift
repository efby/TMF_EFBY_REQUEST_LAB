import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    /// Desconecta el WebSocket de una pestaña concreta (iPad).
    public func disconnectWebSocket(forTabID tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        disconnectWebSocket(tab: tab)
    }

    func connectWebSocket(
        tab: RequestTabState,
        reconnectAttempt: Int = 0,
        resetSessionHistory: Bool = true,
        executionID suppliedExecutionID: UUID? = nil
    ) {
        let contextID = workspaceContextID
        let executionID = suppliedExecutionID ?? UUID()
        tab.executionID = executionID
        cancelWebSocketTasks(for: tab)
        if let connection = tab.webSocketConnection {
            Task {
                await connection.disconnect()
            }
            tab.webSocketConnection = nil
        }

        tab.task?.cancel()
        tab.response = nil
        tab.rawResponseText = nil
        tab.isSending = true
        tab.webSocketConnectionState = .connecting
        tab.webSocketReconnectAttempt = reconnectAttempt
        let wsEnvLine = "Entorno: \(executionEnvironmentDisplayName(for: tab))"
        if resetSessionHistory {
            tab.consoleLogs = [
                wsEnvLine,
                "URL plantilla: \(tab.request.url)",
                "Conectando WebSocket…",
            ]
            tab.webSocketTranscript = [WebSocketTranscriptEntry(direction: .system, body: "Opening WebSocket connection...")]
            tab.webSocketPingSentCount = 0
            tab.webSocketLastPingSentAt = nil
        } else {
            tab.consoleLogs.append(wsEnvLine)
            tab.consoleLogs.append("URL plantilla: \(tab.request.url)")
            tab.consoleLogs.append("Reconnecting WebSocket…")
            appendWebSocketTranscript(
                WebSocketTranscriptEntry(direction: .system, body: "Opening WebSocket connection (attempt \(reconnectAttempt))..."),
                to: tab
            )
        }
        persistDraft(for: tab, syncNow: true)

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

            var preparedOutcome: WebSocketPreparationOutcome?

            do {
                guard await self.flushPendingWorkspacePersistence() else {
                    if self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) {
                        tab.isSending = false
                        tab.webSocketConnectionState = .disconnected
                    }
                    return
                }
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                let prepared = try await self.webSocketCoordinator.prepareConnection(
                    request: effectiveRequest,
                    globals: globals,
                    collectionVariables: collectionVariables,
                    environmentVariables: environment,
                    workspaceEnvironments: self.workspace.environments,
                    activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                    utilityLibraries: self.workspace.utilityLibraries
                )
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                preparedOutcome = prepared
                let connection = try await self.connectWebSocketWithTimeout(
                    prepared: prepared,
                    request: effectiveRequest
                )

                if Task.isCancelled || !self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) {
                    await connection.disconnect()
                    return
                }

                tab.webSocketConnection = connection
                tab.rawRequestText = prepared.rawRequest
                if let updatedRequestHeaders = prepared.updatedRequestHeaders {
                    tab.request.headers = updatedRequestHeaders
                }
                if let updatedRequestQueryItems = prepared.updatedRequestQueryItems {
                    tab.request.queryItems = updatedRequestQueryItems
                }
                if let updatedRequestBody = prepared.updatedRequestBody {
                    tab.request.body = updatedRequestBody
                }
                if resetSessionHistory {
                    tab.consoleLogs = [wsEnvLine] + prepared.logs + ["WebSocket connected."]
                } else {
                    tab.consoleLogs.append(contentsOf: prepared.logs)
                    tab.consoleLogs.append("WebSocket reconnected.")
                }
                tab.webSocketConnectionState = .connected
                tab.isSending = false
                tab.webSocketReconnectAttempt = 0
                self.applyExecutionVariableUpdates(
                    to: tab,
                    updatedGlobals: prepared.updatedGlobals,
                    updatedCollection: prepared.updatedCollection,
                    updatedEnvironment: prepared.updatedEnvironment,
                    updatedEnvironments: prepared.updatedEnvironments,
                    activeEnvironmentID: prepared.activeEnvironmentID,
                    updatedLocal: prepared.updatedLocal
                )
                self.appendWebSocketTranscript(
                    WebSocketTranscriptEntry(
                        direction: .system,
                        body: resetSessionHistory
                            ? "Connected to \(effectiveRequest.url)"
                            : "Reconnected to \(effectiveRequest.url)"
                    ),
                    to: tab
                )
                self.startWebSocketAutomationTasks(for: tab, request: effectiveRequest, connection: connection)
                self.persistWorkspace(syncSharedData: false)

                let receiveTask = await connection.startReceiving { [weak self, weak tab] event in
                    guard let self, let tab else { return }
                    await self.handleWebSocketEvent(event, for: tab, contextID: contextID, executionID: executionID)
                }
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else {
                    receiveTask.cancel()
                    await connection.disconnect()
                    return
                }
                tab.webSocketReceiveTask = receiveTask
            } catch is CancellationError {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) else { return }
                tab.consoleLogs = ["WebSocket connection cancelled."]
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .disconnected
                tab.isSending = false
            } catch {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) else { return }
                if let preparedOutcome {
                    tab.rawRequestText = preparedOutcome.rawRequest
                    if let updatedRequestHeaders = preparedOutcome.updatedRequestHeaders {
                        tab.request.headers = updatedRequestHeaders
                    }
                    if let updatedRequestQueryItems = preparedOutcome.updatedRequestQueryItems {
                        tab.request.queryItems = updatedRequestQueryItems
                    }
                    if let updatedRequestBody = preparedOutcome.updatedRequestBody {
                        tab.request.body = updatedRequestBody
                    }
                    self.applyExecutionVariableUpdates(
                        to: tab,
                        updatedGlobals: preparedOutcome.updatedGlobals,
                        updatedCollection: preparedOutcome.updatedCollection,
                        updatedEnvironment: preparedOutcome.updatedEnvironment,
                        updatedEnvironments: preparedOutcome.updatedEnvironments,
                        activeEnvironmentID: preparedOutcome.activeEnvironmentID,
                        updatedLocal: preparedOutcome.updatedLocal
                    )
                    tab.consoleLogs = preparedOutcome.logs + ["Error: \(error.localizedDescription)"]
                    self.appendWebSocketTranscript(
                        WebSocketTranscriptEntry(direction: .system, body: "Connection error: \(error.localizedDescription)"),
                        to: tab
                    )
                } else {
                    tab.consoleLogs = ["Error: \(error.localizedDescription)"]
                }
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .failed
                tab.isSending = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleWebSocketEvent(
        _ event: WebSocketReceiveEvent,
        for tab: RequestTabState,
        contextID: UUID,
        executionID: UUID
    ) async {
        guard isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
        switch event {
        case .entry(let entry):
            if self.messageExceedsConfiguredLimit(entry.body, for: tab.request) {
                let limit = tab.request.webSocketMaximumMessageSizeMB
                let note = "Incoming message ignored because it exceeded the configured limit of \(limit) MB."
                self.appendWebSocketTranscript(
                    WebSocketTranscriptEntry(direction: .system, body: note),
                    to: tab
                )
                tab.consoleLogs.append(note)
                return
            }
            self.appendWebSocketTranscript(entry, to: tab)
            let collection = self.collection(for: tab)
            let outcome = await self.webSocketCoordinator.executeIncomingMessageScripts(
                message: entry.body,
                request: tab.request,
                globals: self.workspace.globalVariables,
                collectionVariables: collection?.variables ?? [],
                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                workspaceEnvironments: self.workspace.environments,
                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                utilityLibraries: self.workspace.utilityLibraries
            )
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            guard self.applyWebSocketScriptOutcome(outcome, to: tab) else {
                self.disconnectWebSocket(tab: tab, doneCause: "Disconnected after script failure.")
                return
            }
            if !outcome.logs.isEmpty {
                tab.consoleLogs.append(contentsOf: outcome.logs)
            }
            if outcome.shouldDisconnect {
                tab.consoleLogs.append("WebSocket disconnect requested by script.")
                self.disconnectWebSocket(
                    tab: tab,
                    doneCause: "Disconnected by script.",
                    consoleMessage: "WebSocket disconnected by script."
                )
            }
        case .closed(let message):
            self.appendWebSocketTranscript(
                WebSocketTranscriptEntry(direction: .system, body: message),
                to: tab
            )
            let collection = self.collection(for: tab)
            let outcome = await self.webSocketCoordinator.executeDoneScripts(
                cause: message,
                request: tab.request,
                globals: self.workspace.globalVariables,
                collectionVariables: collection?.variables ?? [],
                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                workspaceEnvironments: self.workspace.environments,
                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                utilityLibraries: self.workspace.utilityLibraries
            )
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            self.applyWebSocketScriptOutcome(outcome, to: tab)
            tab.consoleLogs.append(message)
            if !outcome.logs.isEmpty {
                tab.consoleLogs.append(contentsOf: outcome.logs)
            }
            self.cancelWebSocketTasks(for: tab)
            tab.webSocketConnection = nil
            tab.isSending = false
            tab.task = nil
            if outcome.scriptError != nil || !self.scheduleWebSocketReconnectIfPossible(for: tab, reason: message) {
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .disconnected
            }
        case .failure(let message):
            self.appendWebSocketTranscript(
                WebSocketTranscriptEntry(direction: .system, body: "Receive error: \(message)"),
                to: tab
            )
            let collection = self.collection(for: tab)
            let outcome = await self.webSocketCoordinator.executeDoneScripts(
                cause: message,
                request: tab.request,
                globals: self.workspace.globalVariables,
                collectionVariables: collection?.variables ?? [],
                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                workspaceEnvironments: self.workspace.environments,
                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                utilityLibraries: self.workspace.utilityLibraries
            )
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            self.applyWebSocketScriptOutcome(outcome, to: tab)
            tab.consoleLogs.append("Receive error: \(message)")
            if !outcome.logs.isEmpty {
                tab.consoleLogs.append(contentsOf: outcome.logs)
            }
            self.cancelWebSocketTasks(for: tab)
            tab.webSocketConnection = nil
            tab.isSending = false
            tab.task = nil
            if outcome.scriptError != nil || !self.scheduleWebSocketReconnectIfPossible(for: tab, reason: message) {
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .failed
                self.errorMessage = message
            }
        }
    }

    @discardableResult
    private func applyWebSocketScriptOutcome(_ outcome: WebSocketMessageScriptOutcome, to tab: RequestTabState) -> Bool {
        if let error = outcome.scriptError {
            tab.consoleLogs.append("Script error: \(error)")
            errorMessage = error
            return false
        }
        applyExecutionVariableUpdates(
            to: tab,
            updatedGlobals: outcome.updatedGlobals,
            updatedCollection: outcome.updatedCollection,
            updatedEnvironment: outcome.updatedEnvironment,
            updatedEnvironments: outcome.updatedEnvironments,
            activeEnvironmentID: outcome.activeEnvironmentID,
            updatedLocal: outcome.updatedLocal
        )
        persistWorkspace(syncSharedData: false)
        return true
    }

    public func sendCurrentWebSocketMessage() {
        guard let tabID = currentTab?.id else { return }
        sendWebSocketMessage(forTabID: tabID)
    }

    /// Envía el mensaje saliente WebSocket usando el cuerpo/mensaje de la petición de la pestaña indicada.
    public func sendWebSocketMessage(forTabID tabID: UUID) {
        guard !isChangingWorkspace, let tab = tabs.first(where: { $0.id == tabID }) else { return }
        guard !tab.isWebSocketMessageInFlight else { return }
        let contextID = workspaceContextID
        let executionID = tab.executionID
        tab.isWebSocketMessageInFlight = true
        tab.webSocketSendTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if tab.executionID == executionID {
                    tab.isWebSocketMessageInFlight = false
                    tab.webSocketSendTask = nil
                }
            }
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            guard tab.request.transportKind == .webSocket else { return }
            guard tab.webSocketConnectionState == .connected,
                let connection = tab.webSocketConnection
            else {
                self.errorMessage = "Connect the WebSocket before sending messages."
                return
            }

            guard await self.refreshPersistedVariableStoresFromDisk() else {
                if self.isCurrentExecution(tab, contextID: contextID, executionID: executionID) { tab.isSending = false }
                return
            }
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            self.refreshTabEnvironmentSnapshotFromWorkspace(for: tab)

            do {
                let collection = self.collection(for: tab)
                let collectionVariables = collection?.variables ?? []
                let payload = try await self.webSocketCoordinator.resolveOutgoingMessage(
                    from: tab.request,
                    globals: self.workspace.globalVariables,
                    collectionVariables: collectionVariables,
                    environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                    utilityLibraries: self.workspace.utilityLibraries
                )

                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.errorMessage = "The outgoing WebSocket message is empty."
                    return
                }

                await self.sendWebSocketMessage(
                    payload,
                    on: connection,
                    for: tab,
                    transcriptDirection: .outgoing,
                    consoleMessage: "Sent WebSocket message (\(payload.count) chars)."
                )
            } catch {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                tab.consoleLogs.append("Send error: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func sendWebSocketMessage(
        _ payload: String,
        on connection: any WebSocketConnectionProtocol,
        for tab: RequestTabState,
        transcriptDirection: WebSocketTranscriptDirection,
        consoleMessage: String
    ) async {
        let contextID = workspaceContextID
        let executionID = tab.executionID
        guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
        do {
            try await connection.send(text: payload)
            await MainActor.run {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                self.appendWebSocketTranscript(
                    WebSocketTranscriptEntry(direction: transcriptDirection, body: payload),
                    to: tab
                )
                tab.consoleLogs.append(consoleMessage)
            }
        } catch {
            await MainActor.run {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                tab.consoleLogs.append("Send error: \(error.localizedDescription)")
                tab.webSocketConnectionState = .failed
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func disconnectCurrentWebSocket() {
        guard let currentTab else { return }
        disconnectWebSocket(tab: currentTab)
    }

    func disconnectWebSocket(
        tab: RequestTabState,
        doneCause: String = "Disconnected.",
        consoleMessage: String = "WebSocket disconnected."
    ) {
        guard tab.webSocketConnectionState != .disconnecting else {
            return
        }
        let contextID = workspaceContextID
        let executionID = UUID()
        tab.executionID = executionID
        cancelWebSocketTasks(for: tab)
        tab.task?.cancel()
        guard let connection = tab.webSocketConnection else {
            tab.webSocketReconnectAttempt = 0
            tab.webSocketConnectionState = .disconnected
            tab.isSending = false
            return
        }

        tab.webSocketConnectionState = .disconnecting
        tab.isSending = false

        tab.task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            await connection.disconnect()
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            let collection = self.collection(for: tab)
            let outcome = await self.webSocketCoordinator.executeDoneScripts(
                cause: doneCause,
                request: tab.request,
                globals: self.workspace.globalVariables,
                collectionVariables: collection?.variables ?? [],
                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                workspaceEnvironments: self.workspace.environments,
                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                utilityLibraries: self.workspace.utilityLibraries
            )
            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
            self.applyWebSocketScriptOutcome(outcome, to: tab)
            tab.webSocketConnection = nil
            tab.task = nil
            tab.webSocketReconnectAttempt = 0
            tab.webSocketConnectionState = .disconnected
            tab.consoleLogs.append(consoleMessage)
            if !outcome.logs.isEmpty {
                tab.consoleLogs.append(contentsOf: outcome.logs)
            }
            self.appendWebSocketTranscript(
                WebSocketTranscriptEntry(direction: .system, body: doneCause),
                to: tab
            )
        }
    }

    private func scheduleWebSocketReconnectIfPossible(for tab: RequestTabState, reason: String) -> Bool {
        let contextID = workspaceContextID
        let executionID = tab.executionID
        let maxAttempts = max(0, tab.request.webSocketReconnectAttempts)
        guard maxAttempts > 0 else {
            return false
        }

        let nextAttempt = tab.webSocketReconnectAttempt + 1
        guard nextAttempt <= maxAttempts else {
            return false
        }

        let delayMilliseconds = max(0, tab.request.webSocketReconnectIntervalMilliseconds)
        let reconnectMessage = delayMilliseconds > 0
            ? "Scheduling reconnect in \(delayMilliseconds) ms (attempt \(nextAttempt) of \(maxAttempts))."
            : "Scheduling reconnect now (attempt \(nextAttempt) of \(maxAttempts))."

        tab.webSocketReconnectAttempt = nextAttempt
        tab.webSocketConnectionState = .connecting
        tab.consoleLogs.append(reconnectMessage)
        appendWebSocketTranscript(
            WebSocketTranscriptEntry(direction: .system, body: "\(reason)\n\(reconnectMessage)"),
            to: tab
        )

        tab.task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }

            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }

            await MainActor.run {
                guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                guard tab.webSocketConnectionState == .connecting else { return }
                self.connectWebSocket(
                    tab: tab,
                    reconnectAttempt: nextAttempt,
                    resetSessionHistory: false
                )
            }
        }

        return true
    }

    private func messageExceedsConfiguredLimit(_ message: String, for request: APIRequestModel) -> Bool {
        let limitMB = max(0, request.webSocketMaximumMessageSizeMB)
        guard limitMB > 0 else {
            return false
        }

        let sizeInBytes = message.lengthOfBytes(using: .utf8)
        let allowedBytes = limitMB * 1_024 * 1_024
        return sizeInBytes > allowedBytes
    }

    private func appendWebSocketTranscript(_ entry: WebSocketTranscriptEntry, to tab: RequestTabState) {
        tab.webSocketTranscript.append(entry)
        if tab.webSocketTranscript.count > 500 {
            tab.webSocketTranscript.removeFirst(tab.webSocketTranscript.count - 500)
        }
    }

    private func connectWebSocketWithTimeout(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol {
        let timeoutSeconds = request.webSocketOpenTimeoutSeconds
        if timeoutSeconds <= 0 {
            return try await webSocketCoordinator.connect(prepared: prepared, request: request)
        }

        return try await withThrowingTaskGroup(of: (any WebSocketConnectionProtocol).self) { group in
            group.addTask { [webSocketCoordinator] in
                try await webSocketCoordinator.connect(prepared: prepared, request: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppError.network("WebSocket open timed out after \(Int(timeoutSeconds)) seconds.")
            }

            let result = try await group.next()
            group.cancelAll()
            guard let result else {
                throw AppError.network("WebSocket open timed out.")
            }
            return result
        }
    }

    private func startWebSocketAutomationTasks(
        for tab: RequestTabState,
        request: APIRequestModel,
        connection: any WebSocketConnectionProtocol
    ) {
        let contextID = workspaceContextID
        let executionID = tab.executionID
        if request.webSocketPingIntervalSeconds > 0 {
            let pingInterval = request.webSocketPingIntervalSeconds
            tab.webSocketPingTask = Task { [weak self, weak tab] in
                guard let self, let tab else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                        guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                        try await connection.sendPing()
                        await MainActor.run {
                            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                            tab.webSocketPingSentCount += 1
                            tab.webSocketLastPingSentAt = Date()
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await MainActor.run {
                            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                            tab.consoleLogs.append("Ping error: \(error.localizedDescription)")
                        }
                        return
                    }
                }
            }
        }

        let keepAliveMessage = request.webSocketKeepAliveMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.webSocketKeepAliveIntervalSeconds > 0,
           !keepAliveMessage.isEmpty {
            let keepAliveInterval = request.webSocketKeepAliveIntervalSeconds
            tab.webSocketKeepAliveTask = Task { [weak self, weak tab] in
                guard let self, let tab else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(keepAliveInterval * 1_000_000_000))
                        guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }

                        let collection = await MainActor.run { self.collection(for: tab) }
                        let collectionVariables = await MainActor.run { collection?.variables ?? [] }
                        let environmentVariables = await MainActor.run { self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments) }
                        let globals = await MainActor.run { self.workspace.globalVariables }

                        let payload = try await self.webSocketCoordinator.resolveAsync(
                            keepAliveMessage,
                            globals: globals,
                            collectionVariables: collectionVariables,
                            environmentVariables: environmentVariables,
                            localVariables: tab.request.localVariables,
                            request: tab.request,
                            utilityLibraries: self.workspace.utilityLibraries
                        )

                        guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                        try await connection.send(text: payload)
                        await MainActor.run {
                            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                            self.appendWebSocketTranscript(
                                WebSocketTranscriptEntry(direction: .system, body: "Keepalive message sent:\n\(payload)"),
                                to: tab
                            )
                            tab.consoleLogs.append("Keepalive message sent (\(payload.count) chars).")
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await MainActor.run {
                            guard self.isCurrentExecution(tab, contextID: contextID, executionID: executionID), !Task.isCancelled else { return }
                            tab.consoleLogs.append("Keepalive error: \(error.localizedDescription)")
                        }
                        return
                    }
                }
            }
        }
    }

    func cancelWebSocketTasks(for tab: RequestTabState) {
        tab.isWebSocketMessageInFlight = false
        tab.webSocketSendTask?.cancel()
        tab.webSocketSendTask = nil
        tab.webSocketReceiveTask?.cancel()
        tab.webSocketReceiveTask = nil
        tab.webSocketPingTask?.cancel()
        tab.webSocketPingTask = nil
        tab.webSocketKeepAliveTask?.cancel()
        tab.webSocketKeepAliveTask = nil
    }
}
