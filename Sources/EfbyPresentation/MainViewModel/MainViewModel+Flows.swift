import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    public func suggestedFlowName() -> String {
        catalogCoordinator.suggestedFlowName(flows: workspace.flows)
    }

    public func suggestedFlowCloneName(for flow: WorkspaceFlowDefinition) -> String {
        catalogCoordinator.suggestedFlowCloneName(for: flow, flows: workspace.flows)
    }

    public func flowNameValidationMessage(_ rawName: String, excluding excludedFlowID: UUID? = nil) -> String? {
        catalogCoordinator.flowNameValidationMessage(
            rawName,
            flows: workspace.flows,
            excluding: excludedFlowID
        )
    }

    @discardableResult
    public func addFlow(named rawName: String) -> WorkspaceFlowDefinition? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? suggestedFlowName() : trimmedName

        if let validationMessage = flowNameValidationMessage(name) {
            errorMessage = validationMessage
            return nil
        }

        let flow = WorkspaceFlowDefinition(name: name)
        workspace.flows.append(flow)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
        return flow
    }

    @discardableResult
    public func updateFlow(_ flow: WorkspaceFlowDefinition) -> Bool {
        if let validationMessage = flowNameValidationMessage(flow.name, excluding: flow.id) {
            errorMessage = validationMessage
            return false
        }

        guard let index = workspace.flows.firstIndex(where: { $0.id == flow.id }) else {
            return false
        }

        var updated = flow
        updated.updatedAt = Date()
        updated = normalizeFlowTaskBindingsForExecution(updated)
        workspace.flows[index] = updated
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
        return true
    }

    public func renameFlow(_ flow: WorkspaceFlowDefinition, to rawName: String) {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = workspace.flows.firstIndex(where: { $0.id == flow.id }) else { return }
        guard flowNameValidationMessage(trimmedName, excluding: flow.id) == nil else {
            errorMessage = flowNameValidationMessage(trimmedName, excluding: flow.id)
            return
        }
        workspace.flows[index].name = trimmedName
        workspace.flows[index].updatedAt = Date()
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
    }

    /// Deep-copies BPMN, bindings, viewport, and batch cases with a new id and persisted name.
    @discardableResult
    public func cloneFlow(_ flow: WorkspaceFlowDefinition, named rawName: String) -> WorkspaceFlowDefinition? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? suggestedFlowCloneName(for: flow) : trimmedName
        if let validationMessage = flowNameValidationMessage(name) {
            errorMessage = validationMessage
            return nil
        }

        var copy = catalogCoordinator.makeClonedFlow(from: flow, named: name)
        copy = normalizeFlowTaskBindingsForExecution(copy)
        workspace.flows.append(copy)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
        infoMessage = "Flow '\(name)' cloned."
        return copy
    }

    public func deleteFlow(_ flow: WorkspaceFlowDefinition) {
        cancelFlowExecution(flowID: flow.id)
        workspace.flows.removeAll { $0.id == flow.id }
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
    }

    public func availableFlowRequests() -> [WorkspaceFlowRequestReference] {
        catalogCoordinator.flowRequestReferences(in: workspace.collections)
    }

    private func availableFlowRequests(forCollections collections: [CollectionModel]) -> [WorkspaceFlowRequestReference] {
        catalogCoordinator.flowRequestReferences(in: collections)
    }

    public func validateFlow(
        _ flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot
    ) -> WorkspaceFlowValidationResult {
        flowCoordinator.validate(
            flow: flow,
            graph: flowCoordinator.executionGraph(for: flow, editorGraph: graph),
            availableRequests: availableFlowRequests()
        )
    }

    public func executeFlow(
        _ flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        onLog: (@Sendable (String) async -> Void)? = nil,
        executionEnvironmentID: UUID? = nil
    ) async throws -> WorkspaceFlowExecutionResult {
        let validation = validateFlow(flow, graph: graph)
        if !validation.isValid {
            let messages = validation.issues
                .filter { $0.severity == .error }
                .map(\.message)
                .joined(separator: "\n")
            throw AppError.invalidDocument(messages.isEmpty ? "The flow is not valid." : messages)
        }
        let executionGraph = flowCoordinator.executionGraph(for: flow, editorGraph: graph)
        let contextID = workspaceContextID
        let executionID = UUID()
        let task = Task { [weak self] in
            guard let self, self.workspaceContextID == contextID, !Task.isCancelled else { throw CancellationError() }
            return try await self.performFlowExecutionCore(
                flow: flow,
                graph: executionGraph,
                onLog: onLog,
                executionEnvironmentID: executionEnvironmentID
            )
        }
        editorFlowExecutionTasks[executionID] = (flow.id, task)
        defer { editorFlowExecutionTasks[executionID] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func flowRunSession(for flowID: UUID) -> WorkspaceFlowRunSession? {
        flowRunSessions[flowID]
    }

    public func hasActiveFlowRun(for flowID: UUID) -> Bool {
        flowCoordinator.hasActiveRun(in: flowRunSessions, flowID: flowID)
    }

    /// Cancels background and editor flow tasks, and notifies editors to stop their batch loops.
    public func cancelAllRunningFlowExecutions() {
        for id in Array(flowRunTasks.keys) {
            flowRunTasks[id]?.cancel()
        }
        for execution in editorFlowExecutionTasks.values { execution.task.cancel() }
        cancelAllRunningFlowsTick &+= 1
    }

    /// Marks the session as cooperatively cancelled (same as task cancellation outcome).
    public func markFlowRunCancelled(flowID: UUID) {
        markFlowRunSessionCancelled(flowID: flowID)
    }

    /// Removes a **completed** session so the flow editor can show batch-only logs without mixing in an older background run.
    public func removeFlowRunSessionIfNotRunning(flowID: UUID) {
        guard let session = flowRunSessions[flowID], !session.isRunning else { return }
        var copy = flowRunSessions
        copy.removeValue(forKey: flowID)
        flowRunSessions = copy
    }

    public func recordWorkspaceFlowBatchCaseTranscript(flowID: UUID, caseID: UUID, lines: [String]) {
        var outer = workspaceFlowBatchCaseTranscripts
        var byCase = outer[flowID] ?? [:]
        byCase[caseID] = lines
        outer[flowID] = byCase
        workspaceFlowBatchCaseTranscripts = outer
    }

    public func removeWorkspaceFlowBatchCaseTranscript(flowID: UUID, caseID: UUID) {
        guard var byCase = workspaceFlowBatchCaseTranscripts[flowID] else { return }
        byCase.removeValue(forKey: caseID)
        var outer = workspaceFlowBatchCaseTranscripts
        if byCase.isEmpty {
            outer.removeValue(forKey: flowID)
        } else {
            outer[flowID] = byCase
        }
        workspaceFlowBatchCaseTranscripts = outer
    }

    public func clearWorkspaceFlowBatchCaseTranscripts(for flowID: UUID) {
        var outer = workspaceFlowBatchCaseTranscripts
        outer.removeValue(forKey: flowID)
        workspaceFlowBatchCaseTranscripts = outer
    }

    public func workspaceFlowBatchCaseTranscript(flowID: UUID, caseID: UUID) -> [String] {
        workspaceFlowBatchCaseTranscripts[flowID]?[caseID] ?? []
    }

    /// Starts a fresh **running** session for a synchronous `executeFlow` from the flow editor (batch / sequential). Cancels any detached task for the same `flowID`.
    public func beginEditorSynchronousFlowRun(flowID: UUID) {
        for execution in editorFlowExecutionTasks.values where execution.flowID == flowID { execution.task.cancel() }
        flowRunTasks[flowID]?.cancel()
        flowRunTasks[flowID] = nil
        replaceFlowRunSession(flowID, WorkspaceFlowRunSession(flowID: flowID, logs: [], isRunning: true))
    }

    public func appendEditorSynchronousFlowRunLog(flowID: UUID, line: String) {
        appendFlowRunLog(flowID: flowID, line: line)
    }

    public func finishEditorSynchronousFlowRun(flowID: UUID, result: WorkspaceFlowExecutionResult) {
        completeFlowRunSession(flowID: flowID, result: result)
    }

    public func markEditorSynchronousFlowRunFailed(flowID: UUID, error: Error) {
        markFlowRunSessionFailed(flowID: flowID, error: error)
    }

    /// Ejecuta un caso de batch del flow (misma lógica que el editor Mac: entorno + `executeFlow` síncrono).
    public func runPadFlowBatchSingleCase(flowID: UUID, caseID: UUID, executionEnvironmentID: UUID? = nil) async {
        let contextID = workspaceContextID
        guard !isChangingWorkspace else { return }
        guard let flow = workspace.flows.first(where: { $0.id == flowID }),
              let rows = flow.batchRunCases,
              let index = rows.firstIndex(where: { $0.id == caseID })
        else { return }

        cancelFlowExecution(flowID: flowID)

        let graph: WorkspaceFlowGraphSnapshot
        do {
            graph = try WorkspaceFlowBPMNParser().parse(xml: flow.bpmnXML)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        beginEditorSynchronousFlowRun(flowID: flowID)
        do {
            let result = try await performPadFlowBatchRunCase(
                flow: flow,
                allRows: rows,
                runCase: rows[index],
                caseIndex: index,
                graph: graph,
                executionEnvironmentID: executionEnvironmentID
            )
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            finishEditorSynchronousFlowRun(flowID: flowID, result: result)
        } catch is CancellationError {
            guard workspaceContextID == contextID else { return }
            markFlowRunCancelled(flowID: flowID)
        } catch {
            guard workspaceContextID == contextID else { return }
            markEditorSynchronousFlowRunFailed(flowID: flowID, error: error)
            errorMessage = error.localizedDescription
        }
    }

    /// Ejecuta todos los casos batch en orden. Cancela con `Task.cancel()` en la tarea que invoque este método.
    public func runPadFlowBatchAllCasesSequentially(flowID: UUID, executionEnvironmentID: UUID? = nil) async {
        let contextID = workspaceContextID
        guard !isChangingWorkspace else { return }
        guard let flow = workspace.flows.first(where: { $0.id == flowID }),
              let rows = flow.batchRunCases,
              !rows.isEmpty
        else { return }

        cancelFlowExecution(flowID: flowID)

        let graph: WorkspaceFlowGraphSnapshot
        do {
            graph = try WorkspaceFlowBPMNParser().parse(xml: flow.bpmnXML)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        beginEditorSynchronousFlowRun(flowID: flowID)
        var lastCompletedResult: WorkspaceFlowExecutionResult?
        var aborted = false
        let orderedIDs = rows.map(\.id)
        for (offset, caseID) in orderedIDs.enumerated() {
            guard workspaceContextID == contextID else { return }
            if Task.isCancelled {
                aborted = true
                markFlowRunCancelled(flowID: flowID)
                break
            }

            appendEditorSynchronousFlowRunLog(
                flowID: flowID,
                line: "——— Batch \(offset + 1) / \(orderedIDs.count) ———"
            )

            guard let index = rows.firstIndex(where: { $0.id == caseID }) else { continue }
            do {
                let result = try await performPadFlowBatchRunCase(
                    flow: flow,
                    allRows: rows,
                    runCase: rows[index],
                    caseIndex: index,
                    graph: graph,
                    executionEnvironmentID: executionEnvironmentID
                )
                guard workspaceContextID == contextID, !Task.isCancelled else { return }
                lastCompletedResult = result
            } catch is CancellationError {
                guard workspaceContextID == contextID else { return }
                aborted = true
                markFlowRunCancelled(flowID: flowID)
                break
            } catch {
                guard workspaceContextID == contextID else { return }
                aborted = true
                errorMessage = error.localizedDescription
                markEditorSynchronousFlowRunFailed(flowID: flowID, error: error)
                break
            }
        }

        guard workspaceContextID == contextID else { return }
        if !aborted, let result = lastCompletedResult {
            guard workspaceContextID == contextID, !Task.isCancelled else { return }
            finishEditorSynchronousFlowRun(flowID: flowID, result: result)
        }
    }

    private func performPadFlowBatchRunCase(
        flow: WorkspaceFlowDefinition,
        allRows: [WorkspaceFlowBatchRunCase],
        runCase: WorkspaceFlowBatchRunCase,
        caseIndex: Int,
        graph: WorkspaceFlowGraphSnapshot,
        executionEnvironmentID: UUID?
    ) async throws -> WorkspaceFlowExecutionResult {
        let contextID = workspaceContextID
        let sessionID = flowRunSessions[flow.id]?.id
        let caseID = runCase.id
        let title = runCase.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Run \(caseIndex + 1)"
            : runCase.name

        let collector = FlowBatchTranscriptCollector()
        let headerApplying = "=== \(title): applying JSON to active environment ==="
        appendEditorSynchronousFlowRunLog(flowID: flow.id, line: headerApplying)
        await collector.append(headerApplying)
        guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
        try Task.checkCancellation()

        let keysToRemove = allTopLevelKeysFromFlowBatchRunCases(allRows)
        let keysSorted = keysToRemove.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let keysListForLog: String = {
            guard !keysSorted.isEmpty else { return "(ninguna clave en los JSON del batch)" }
            let joined = keysSorted.joined(separator: ", ")
            if joined.count <= 400 { return joined }
            return String(joined.prefix(397)) + "…"
        }()
        let scrubLine = "Batch env: quitando \(keysToRemove.count) clave(s) definidas en alguna fila del batch → [\(keysListForLog)]"
        appendEditorSynchronousFlowRunLog(flowID: flow.id, line: scrubLine)
        await collector.append(scrubLine)
        guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
        try Task.checkCancellation()

        try removeActiveEnvironmentVariables(withKeys: keysToRemove, targetEnvironmentID: executionEnvironmentID)
        try upsertActiveEnvironmentVariablesFromFlowBatchParametersJSON(
            runCase.parametersJSON,
            targetEnvironmentID: executionEnvironmentID
        )

        let headerExecuting = "=== \(title): executing flow ==="
        appendEditorSynchronousFlowRunLog(flowID: flow.id, line: headerExecuting)
        await collector.append(headerExecuting)
        guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
        try Task.checkCancellation()

        let onLog: (@Sendable (String) async -> Void) = { [weak self] line in
            await collector.append(line)
            await MainActor.run {
                guard let self, self.isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { return }
                self.appendEditorSynchronousFlowRunLog(flowID: flow.id, line: line)
            }
        }

        let result = try await executeFlow(flow, graph: graph, onLog: onLog, executionEnvironmentID: executionEnvironmentID)
        let combined = await collector.lines()
        guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
        try Task.checkCancellation()
        recordWorkspaceFlowBatchCaseTranscript(flowID: flow.id, caseID: caseID, lines: combined)
        return result
    }

    /// Starts a validated flow run in a detached task. Cooperative cancellation via `cancelFlowExecution(flowID:)`.
    /// At most one active run per `flow.id` is allowed.
    public func startBackgroundFlowExecution(
        _ flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        executionEnvironmentID: UUID? = nil
    ) throws {
        let contextID = workspaceContextID
        guard !isChangingWorkspace else { throw CancellationError() }
        let validation = validateFlow(flow, graph: graph)
        if !validation.isValid {
            let messages = validation.issues
                .filter { $0.severity == .error }
                .map(\.message)
                .joined(separator: "\n")
            throw AppError.invalidDocument(messages.isEmpty ? "The flow is not valid." : messages)
        }

        let flowID = flow.id
        if flowRunSessions[flowID]?.isRunning == true {
            throw AppError.invalidDocument("Este flow ya tiene una ejecución en curso.")
        }

        flowRunTasks[flowID]?.cancel()

        let session = WorkspaceFlowRunSession(flowID: flowID)
        replaceFlowRunSession(flowID, session)

        let capturedFlow = flow
        let capturedGraph = flowCoordinator.executionGraph(for: flow, editorGraph: graph)

        let task = Task { [weak self] in
            guard let self else { return }
            guard self.isCurrentFlowRun(flowID, contextID: contextID, sessionID: session.id), !Task.isCancelled else { return }
            do {
                let result = try await self.performFlowExecutionCore(
                    flow: capturedFlow,
                    graph: capturedGraph,
                    onLog: { line in
                        await MainActor.run {
                            guard self.isCurrentFlowRun(flowID, contextID: contextID, sessionID: session.id) else { return }
                            self.appendFlowRunLog(flowID: flowID, line: line)
                        }
                    },
                    executionEnvironmentID: executionEnvironmentID
                )
                await MainActor.run {
                    guard self.isCurrentFlowRun(flowID, contextID: contextID, sessionID: session.id) else { return }
                    self.flowRunTasks[flowID] = nil
                    self.completeFlowRunSession(flowID: flowID, result: result)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.isCurrentFlowRun(flowID, contextID: contextID, sessionID: session.id) else { return }
                    self.flowRunTasks[flowID] = nil
                    self.markFlowRunSessionCancelled(flowID: flowID)
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentFlowRun(flowID, contextID: contextID, sessionID: session.id) else { return }
                    self.flowRunTasks[flowID] = nil
                    self.markFlowRunSessionFailed(flowID: flowID, error: error)
                }
            }
        }
        flowRunTasks[flowID] = task
    }

    public func cancelFlowExecution(flowID: UUID) {
        flowRunTasks[flowID]?.cancel()
        for execution in editorFlowExecutionTasks.values where execution.flowID == flowID { execution.task.cancel() }
    }

    private func replaceFlowRunSession(_ flowID: UUID, _ session: WorkspaceFlowRunSession) {
        var copy = flowRunSessions
        copy[flowID] = session
        flowRunSessions = copy
    }

    private func appendFlowRunLog(flowID: UUID, line: String) {
        guard var session = flowRunSessions[flowID] else { return }
        session.logs.append(line)
        if session.logs.count > flowRunLogLineLimit {
            session.logs.removeFirst(session.logs.count - flowRunLogLineLimit)
        }
        replaceFlowRunSession(flowID, session)
    }

    private func completeFlowRunSession(flowID: UUID, result: WorkspaceFlowExecutionResult) {
        flowExecutionHighlightElementIDs.removeAll()
        guard var session = flowRunSessions[flowID] else { return }
        session.isRunning = false
        session.lastResult = result
        session.lastErrorDescription = nil
        replaceFlowRunSession(flowID, session)
    }

    private func markFlowRunSessionCancelled(flowID: UUID) {
        flowExecutionHighlightElementIDs.removeAll()
        guard var session = flowRunSessions[flowID] else { return }
        session.isRunning = false
        session.lastErrorDescription = "Cancelled"
        replaceFlowRunSession(flowID, session)
    }

    private func markFlowRunSessionFailed(flowID: UUID, error: Error) {
        flowExecutionHighlightElementIDs.removeAll()
        guard var session = flowRunSessions[flowID] else { return }
        session.isRunning = false
        session.lastErrorDescription = error.localizedDescription
        replaceFlowRunSession(flowID, session)
    }

    private func performFlowExecutionCore(
        flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        onLog: (@Sendable (String) async -> Void)? = nil,
        executionEnvironmentID: UUID? = nil
    ) async throws -> WorkspaceFlowExecutionResult {
        let contextID = workspaceContextID
        let sessionID = flowRunSessions[flow.id]?.id
        guard !isChangingWorkspace else { throw CancellationError() }
        try Task.checkCancellation()
        guard await flushPendingWorkspacePersistence() else { throw AppError.persistence("Save failed before flow execution.") }
        guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
        try Task.checkCancellation()
        let executionFlow = normalizeFlowTaskBindingsForExecution(flow)
        let resolvedRequests = try resolveRequests(for: executionFlow)
        let effectiveEnvironmentID = executionEnvironmentID ?? workspace.activeEnvironmentID
        let environmentVariables = environmentCoordinator.variables(for: effectiveEnvironmentID, in: workspace.environments) ?? []

        if let onLog {
            let envLabel: String = {
                guard let effectiveEnvironmentID,
                      let env = workspace.environments.first(where: { $0.id == effectiveEnvironmentID }) else {
                    return "ninguno (sin variables de entorno)"
                }
                return "\(env.name) [\(environmentVariables.count) vars, perfil \(env.isEnabled ? "activo" : "desactivado en workspace")]"
            }()
            await onLog("Entorno de ejecución del flow: \(envLabel)")
            guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
            try Task.checkCancellation()
        }

        flowExecutionHighlightElementIDs.removeAll()
        defer {
            if isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) {
                flowExecutionHighlightElementIDs.removeAll()
            }
        }

        let onHighlight: @Sendable (WorkspaceFlowExecutionHighlightEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                guard let self, self.isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { return }
                self.applyFlowExecutionHighlight(event)
            }
        }

        let onVariableCheckpoint: @Sendable (WorkspaceFlowExecutionVariableCheckpoint) async -> Void = { [weak self] checkpoint in
            await MainActor.run {
                guard let self else { return }
                guard self.isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID), !Task.isCancelled else { return }
                self.applyFlowExecutionVariableUpdates(
                    WorkspaceFlowExecutionResult(
                        logs: [],
                        taskResults: [],
                        updatedGlobals: checkpoint.updatedGlobals,
                        updatedEnvironment: checkpoint.updatedEnvironment,
                        updatedEnvironments: checkpoint.updatedEnvironments,
                        activeEnvironmentID: checkpoint.activeEnvironmentID,
                        updatedCollections: checkpoint.updatedCollections
                    ),
                    persistToDisk: false
                )
            }
        }

        var mergedResult = try await flowCoordinator.execute(
            flow: executionFlow,
            graph: graph,
            globals: workspace.globalVariables,
            environment: environmentVariables,
            workspaceEnvironments: workspace.environments,
            activeEnvironmentID: effectiveEnvironmentID,
            utilityLibraries: workspace.utilityLibraries,
            resolvedRequests: resolvedRequests,
            onLog: onLog,
            onHighlight: onHighlight,
            onVariableCheckpoint: onVariableCheckpoint
        )

        guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
        try Task.checkCancellation()
        let summaryFooter = mergedResult.taskResultsSummaryLogLines()
        for line in summaryFooter {
            mergedResult.logs.append(line)
            if let onLog {
                await onLog(line)
                guard isCurrentFlowRun(flow.id, contextID: contextID, sessionID: sessionID) else { throw CancellationError() }
                try Task.checkCancellation()
            }
        }

        applyFlowExecutionVariableUpdates(mergedResult, persistToDisk: false)
        return mergedResult
    }

    @MainActor
    private func applyFlowExecutionHighlight(_ event: WorkspaceFlowExecutionHighlightEvent) {
        switch event {
        case .enter(let id):
            flowExecutionHighlightElementIDs.insert(id)
        case .leave(let id):
            flowExecutionHighlightElementIDs.remove(id)
        case .clearAll:
            flowExecutionHighlightElementIDs.removeAll()
        }
    }

    private func isCurrentFlowRun(_ flowID: UUID, contextID: UUID, sessionID: UUID?) -> Bool {
        workspaceContextID == contextID && flowRunSessions[flowID]?.id == sessionID
    }

    private func normalizeFlowTaskBindings(
        _ flow: WorkspaceFlowDefinition,
        availableRequests: [WorkspaceFlowRequestReference]
    ) -> WorkspaceFlowDefinition {
        var copy = flow
        copy.taskBindings = flow.taskBindings.map { binding in
            var updated = binding
            guard let resolved = updated.resolvedRequestID(matching: availableRequests) else {
                return updated
            }
            updated.requestID = resolved
            if let ref = availableRequests.first(where: { $0.requestID == resolved }) {
                updated.boundCollectionName = ref.collectionName
                updated.boundRequestName = ref.requestName
                updated.boundTransportKind = ref.transportKind
            }
            return updated
        }
        return copy
    }

    private func normalizeFlowTaskBindingsForExecution(_ flow: WorkspaceFlowDefinition) -> WorkspaceFlowDefinition {
        normalizeFlowTaskBindings(flow, availableRequests: availableFlowRequests())
    }

    /// Rewrites task bindings with portable metadata and local request UUIDs using the given collections (must match the flows being saved).
    func flowsPortableForPersistence(_ flows: [WorkspaceFlowDefinition], collections: [CollectionModel]) -> [WorkspaceFlowDefinition] {
        let available = availableFlowRequests(forCollections: collections)
        return flows.map { normalizeFlowTaskBindings($0, availableRequests: available) }
    }

    private func resolveRequests(for flow: WorkspaceFlowDefinition) throws -> [WorkspaceFlowResolvedRequest] {
        let available = availableFlowRequests()
        let requestIDs = Set(flow.taskBindings.compactMap { $0.resolvedRequestID(matching: available) })

        return try requestIDs.map { requestID in
            guard let resolved = resolveRequestReference(for: requestID) else {
                throw AppError.invalidDocument("A task in flow '\(flow.name)' points to a request that no longer exists.")
            }
            return resolved
        }
    }

    private func resolveRequestReference(for requestID: UUID) -> WorkspaceFlowResolvedRequest? {
        for collection in workspace.collections {
            if let node = requestNode(for: requestID, in: collection.items),
               let request = node.request {
                let effectiveRequest = CollectionScriptSupport.enrichedRequest(
                    from: request,
                    collection: collection,
                    sourceNodeID: node.id
                )
                return WorkspaceFlowResolvedRequest(
                    requestID: request.id,
                    collectionID: collection.id,
                    request: effectiveRequest,
                    collectionVariables: collection.variables
                )
            }
        }

        return nil
    }

    private func requestNode(for requestID: UUID, in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.request?.id == requestID {
                return node
            }
            if let nested = requestNode(for: requestID, in: node.children) {
                return nested
            }
        }
        return nil
    }
}

private actor FlowBatchTranscriptCollector {
    private var stored: [String] = []

    func append(_ line: String) {
        stored.append(line)
    }

    func lines() -> [String] {
        stored
    }
}
