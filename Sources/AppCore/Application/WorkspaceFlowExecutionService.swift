import EfbyApplication
import Foundation

public struct WorkspaceFlowResolvedRequest: Sendable {
    public var requestID: UUID
    public var collectionID: UUID
    public var request: APIRequestModel
    public var collectionVariables: [VariableValue]

    public init(
        requestID: UUID,
        collectionID: UUID,
        request: APIRequestModel,
        collectionVariables: [VariableValue]
    ) {
        self.requestID = requestID
        self.collectionID = collectionID
        self.request = request
        self.collectionVariables = collectionVariables
    }
}

public struct WorkspaceFlowExecutionService: Sendable {
    private let runner: any HTTPExecutionServiceProtocol
    private let webSocketRunner: any WebSocketExecutionServiceProtocol

    private struct RuntimeContext {
        var globals: [String: String]
        var environment: [String: String]
        var environments: [EnvironmentProfile]
        var activeEnvironmentID: UUID?
        var collectionVariables: [UUID: [String: String]]
        var lastStatusCode: Int?
    }

    private struct Token {
        var nodeID: String
        var context: RuntimeContext
    }

    private struct JoinArrival {
        var nodeID: String
        var requiredCount: Int
        var context: RuntimeContext
        var nodeName: String
    }

    private struct ProcessedTokenResult {
        var logs: [String] = []
        var taskResults: [WorkspaceFlowTaskExecutionResult] = []
        var nextTokens: [Token] = []
        var completedContexts: [RuntimeContext] = []
        var joinArrival: JoinArrival?
        /// When true, the engine cancels all other in-flight branches (BPMN terminate end semantics).
        var shouldTerminateProcess: Bool = false
    }

    public init(
        runner: any HTTPExecutionServiceProtocol,
        webSocketRunner: any WebSocketExecutionServiceProtocol
    ) {
        self.runner = runner
        self.webSocketRunner = webSocketRunner
    }

    public func execute(
        flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        globals: [VariableValue],
        environment: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        utilityLibraries: [WorkspaceScriptUtility],
        resolvedRequests: [WorkspaceFlowResolvedRequest],
        onLog: (@Sendable (String) async -> Void)? = nil,
        onHighlight: (@Sendable (WorkspaceFlowExecutionHighlightEvent) -> Void)? = nil,
        onVariableCheckpoint: (@Sendable (WorkspaceFlowExecutionVariableCheckpoint) async -> Void)? = nil
    ) async throws -> WorkspaceFlowExecutionResult {
        let activeRegistry = WorkspaceFlowActiveRequestRegistry()
        return try await WorkspaceFlowExecutionCancellationScope.$activeRequestRegistry.withValue(activeRegistry) {
            try await withTaskCancellationHandler {
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let outgoingConnections = Dictionary(grouping: graph.connections, by: \.sourceID)
        let incomingConnections = Dictionary(grouping: graph.connections, by: \.targetID)
        let bindingsByElementID = Dictionary(uniqueKeysWithValues: flow.taskBindings.map { ($0.elementID, $0) })
        let requestsByID = Dictionary(uniqueKeysWithValues: resolvedRequests.map { ($0.requestID, $0) })

        var logs: [String] = ["Starting flow \(flow.name)"]
        var taskResults: [WorkspaceFlowTaskExecutionResult] = []
        if let onLog {
            await onLog("Starting flow \(flow.name)")
        }
        let initialFlatEnvironment = dictionaryAllowingDuplicateKeys(from: environment)
        let initialTokens: [Token] = graph.nodes
            .filter { $0.nodeType == .startEvent }
            .map {
                Token(
                    nodeID: $0.id,
                    context: RuntimeContext(
                        globals: dictionaryAllowingDuplicateKeys(from: globals),
                        environment: initialFlatEnvironment,
                        environments: workspaceEnvironments,
                        activeEnvironmentID: activeEnvironmentID,
                        collectionVariables: mergedCollectionVariables(from: resolvedRequests),
                        lastStatusCode: nil
                    )
                )
            }

        var joinBuffers: [String: [RuntimeContext]] = [:]
        var completedContexts: [RuntimeContext] = []
        var abruptTerminationContext: RuntimeContext?
        var processedTokenCount = 0
        /// Tras un terminate end (o cancelación global), no se encolan más tokens ni uniones paralelas: evita que una rama WebSocket «rezagada» siga el flujo con el socket aún abierto.
        var flowExecutionTerminated = false

        do {
        try await withThrowingTaskGroup(of: ProcessedTokenResult.self) { group in
            func enqueue(_ tokens: [Token]) throws {
                for token in tokens {
                    processedTokenCount += 1
                    if processedTokenCount > 2_000 {
                        throw AppError.invalidDocument("The flow execution stopped because it exceeded the safety limit of 2000 processed tokens.")
                    }

                    group.addTask {
                        do {
                            return try await processToken(
                                token,
                                nodesByID: nodesByID,
                                outgoingConnections: outgoingConnections,
                                incomingConnections: incomingConnections,
                                bindingsByElementID: bindingsByElementID,
                                requestsByID: requestsByID,
                                utilityLibraries: utilityLibraries,
                                onLog: onLog,
                                onHighlight: onHighlight,
                                onVariableCheckpoint: onVariableCheckpoint
                            )
                        } catch is CancellationError {
                            return ProcessedTokenResult(
                                logs: ["A flow branch was cancelled because a terminate end event stopped the process."]
                            )
                        }
                    }
                }
            }

            try enqueue(initialTokens)

            while let result = try await group.next() {
                logs.append(contentsOf: result.logs)
                if let onLog {
                    for entry in result.logs {
                        await onLog(entry)
                    }
                }

                if !flowExecutionTerminated {
                    taskResults.append(contentsOf: result.taskResults)
                    completedContexts.append(contentsOf: result.completedContexts)
                    try enqueue(result.nextTokens)

                    if let joinArrival = result.joinArrival {
                        joinBuffers[joinArrival.nodeID, default: []].append(joinArrival.context)
                        let bufferedContexts = joinBuffers[joinArrival.nodeID, default: []]

                        if bufferedContexts.count < joinArrival.requiredCount {
                            let message = "Parallel gateway \(joinArrival.nodeName) is waiting for \(joinArrival.requiredCount - bufferedContexts.count) more branch(es)."
                            logs.append(message)
                            if let onLog {
                                await onLog(message)
                            }
                            continue
                        }

                        let mergedContext = mergeContexts(bufferedContexts, environmentJoinBaseline: initialFlatEnvironment)
                        joinBuffers[joinArrival.nodeID] = []
                        let outgoing = outgoingConnections[joinArrival.nodeID] ?? []

                        if let onVariableCheckpoint {
                            await onVariableCheckpoint(variableCheckpoint(from: mergedContext))
                        }

                        let message = "Parallel gateway \(joinArrival.nodeName) synchronized \(joinArrival.requiredCount) branches."
                        logs.append(message)
                        if let onLog {
                            await onLog(message)
                        }

                        if outgoing.count <= 1 {
                            if let next = outgoing.first {
                                try enqueue([Token(nodeID: next.targetID, context: mergedContext)])
                            } else {
                                completedContexts.append(mergedContext)
                            }
                        } else {
                            try enqueue(outgoing.map { Token(nodeID: $0.targetID, context: mergedContext) })
                        }
                    }
                }

                if result.shouldTerminateProcess {
                    if !flowExecutionTerminated {
                        flowExecutionTerminated = true
                        if abruptTerminationContext == nil, let ctx = result.completedContexts.first {
                            abruptTerminationContext = ctx
                        }
                        joinBuffers.removeAll(keepingCapacity: false)
                        await activeRegistry.cancelHTTPTasksAndDisconnectWebSockets()
                        group.cancelAll()
                    }
                }
            }
        }

        // Normal end (and any drained parallel branches): release sockets and HTTP still registered.
        await activeRegistry.cancelHTTPTasksAndDisconnectWebSockets()

        try Task.checkCancellation()

        if let onHighlight {
            onHighlight(.clearAll)
        }
        } catch {
            if let onHighlight {
                onHighlight(.clearAll)
            }
            await activeRegistry.cancelHTTPTasksAndDisconnectWebSockets()
            throw error
        }

        let finalContext: RuntimeContext
        if let abrupt = abruptTerminationContext {
            finalContext = mergeContexts([abrupt], environmentJoinBaseline: initialFlatEnvironment)
        } else {
            let pendingJoinContexts = joinBuffers.values.flatMap { $0 }
            finalContext = mergeContexts(completedContexts + pendingJoinContexts, environmentJoinBaseline: initialFlatEnvironment)
        }
        return WorkspaceFlowExecutionResult(
            logs: logs,
            taskResults: taskResults,
            updatedGlobals: dictionaryToVariables(finalContext.globals),
            updatedEnvironment: dictionaryToVariables(finalContext.environment),
            updatedEnvironments: finalContext.environments,
            activeEnvironmentID: finalContext.activeEnvironmentID,
            updatedCollections: finalContext.collectionVariables.map {
                WorkspaceFlowCollectionUpdate(collectionID: $0.key, variables: dictionaryToVariables($0.value))
            }
            .sorted { $0.collectionID.uuidString < $1.collectionID.uuidString }
        )
            } onCancel: {
                activeRegistry.cancelAllHTTPDataTasks()
                Task {
                    await activeRegistry.disconnectAllRegisteredWebSockets()
                }
            }
        }
    }

    private func processToken(
        _ token: Token,
        nodesByID: [String: WorkspaceFlowGraphNode],
        outgoingConnections: [String: [WorkspaceFlowGraphConnection]],
        incomingConnections: [String: [WorkspaceFlowGraphConnection]],
        bindingsByElementID: [String: WorkspaceFlowTaskBinding],
        requestsByID: [UUID: WorkspaceFlowResolvedRequest],
        utilityLibraries: [WorkspaceScriptUtility],
        onLog: (@Sendable (String) async -> Void)?,
        onHighlight: (@Sendable (WorkspaceFlowExecutionHighlightEvent) -> Void)?,
        onVariableCheckpoint: (@Sendable (WorkspaceFlowExecutionVariableCheckpoint) async -> Void)?
    ) async throws -> ProcessedTokenResult {
        guard let node = nodesByID[token.nodeID] else {
            return ProcessedTokenResult(logs: ["Skipping missing node \(token.nodeID)."])
        }

        return try await withExecutionHighlight(elementID: node.id, onHighlight: onHighlight) {
            try Task.checkCancellation()
            let outgoing = outgoingConnections[node.id] ?? []
            let incoming = incomingConnections[node.id] ?? []
            let nodeName = node.name.isEmpty ? node.id : node.name
            var result = ProcessedTokenResult()

            switch node.nodeType {
        case .startEvent:
            result.nextTokens = outgoing.map { Token(nodeID: $0.targetID, context: token.context) }

        case .endEvent:
            result.logs.append("Reached end event \(nodeName).")
            result.completedContexts = [token.context]

        case .terminateEndEvent:
            result.logs.append("Terminate end event \(nodeName): stopping the entire flow and cancelling other branches.")
            result.completedContexts = [token.context]
            result.shouldTerminateProcess = true

        case .task:
            guard let binding = bindingsByElementID[node.id], let requestID = binding.requestID, let resolvedRequest = requestsByID[requestID] else {
                throw AppError.invalidDocument("Task '\(nodeName)' is not bound to a valid workspace request.")
            }
            let taskStartMarker = taskStartLogLine(elementID: node.id, requestName: resolvedRequest.request.name)
            let taskEndMarker = taskEndLogLine(elementID: node.id)
            let taskTargetLines = taskConnectionLogLines(
                request: resolvedRequest.request,
                context: token.context,
                collectionID: resolvedRequest.collectionID
            )
            switch resolvedRequest.request.transportKind {
            case .http, .invokeLambda:
                result.logs.append(taskStartMarker)
                result.logs.append(contentsOf: taskTargetLines)
                result.logs.append("Executing task \(nodeName) with request \(resolvedRequest.request.name).")
                do {
                    let outcome = try await runner.execute(
                        request: resolvedRequest.request,
                        globals: dictionaryToVariables(token.context.globals),
                        collectionVariables: dictionaryToVariables(token.context.collectionVariables[resolvedRequest.collectionID] ?? [:]),
                        environmentVariables: dictionaryToVariables(token.context.environment),
                        workspaceEnvironments: token.context.environments,
                        activeEnvironmentID: token.context.activeEnvironmentID,
                        utilityLibraries: utilityLibraries
                    )

                    var updatedContext = token.context
                    applyVariableUpdates(
                        to: &updatedContext,
                        collectionID: resolvedRequest.collectionID,
                        updatedGlobals: outcome.updatedGlobals,
                        updatedCollection: outcome.updatedCollection,
                        updatedEnvironment: outcome.updatedEnvironment,
                        updatedEnvironments: outcome.updatedEnvironments,
                        activeEnvironmentID: outcome.activeEnvironmentID
                    )
                    updatedContext.lastStatusCode = outcome.response.statusCode

                    result.logs.append(contentsOf: outcome.logs)
                    result.logs.append(taskEndMarker)
                    result.taskResults = [
                        WorkspaceFlowTaskExecutionResult(
                            elementID: node.id,
                            requestID: resolvedRequest.requestID,
                            requestName: resolvedRequest.request.name,
                            statusCode: outcome.response.statusCode,
                            durationMilliseconds: outcome.response.durationMilliseconds
                        )
                    ]
                    if let onVariableCheckpoint {
                        await onVariableCheckpoint(variableCheckpoint(from: updatedContext))
                    }
                    result.nextTokens = outgoing.map { Token(nodeID: $0.targetID, context: updatedContext) }
                } catch is CancellationError {
                    result.logs.append(taskEndMarker)
                    throw CancellationError()
                } catch {
                    result.logs.append("Task failed: \(error.localizedDescription)")
                    result.logs.append(taskEndMarker)
                    throw AppError.network(result.logs.joined(separator: "\n"))
                }

            case .webSocket:
                result.logs.append(taskStartMarker)
                if let onLog {
                    await onLog(taskStartMarker)
                }
                for line in taskTargetLines {
                    result.logs.append(line)
                    if let onLog {
                        await onLog(line)
                    }
                }
                do {
                    let socketOutcome = try await executeWebSocketTask(
                        resolvedRequest: resolvedRequest,
                        initialContext: token.context,
                        utilityLibraries: utilityLibraries,
                        onLog: onLog
                    )
                    result.logs.append(contentsOf: socketOutcome.logs)
                    result.logs.append(taskEndMarker)
                    if let onLog {
                        await onLog(taskEndMarker)
                    }
                    result.taskResults = [
                        WorkspaceFlowTaskExecutionResult(
                            elementID: node.id,
                            requestID: resolvedRequest.requestID,
                            requestName: resolvedRequest.request.name,
                            statusCode: socketOutcome.statusCode,
                            durationMilliseconds: socketOutcome.durationMilliseconds
                        )
                    ]
                    if let onVariableCheckpoint {
                        await onVariableCheckpoint(variableCheckpoint(from: socketOutcome.context))
                    }
                    result.nextTokens = outgoing.map { Token(nodeID: $0.targetID, context: socketOutcome.context) }
                } catch is CancellationError {
                    if let onLog {
                        await onLog(taskEndMarker)
                    }
                    result.logs.append(taskEndMarker)
                    throw CancellationError()
                } catch {
                    let failureLine = "Task failed: \(error.localizedDescription)"
                    result.logs.append(failureLine)
                    result.logs.append(taskEndMarker)
                    if let onLog {
                        await onLog(failureLine)
                        await onLog(taskEndMarker)
                    }
                    throw AppError.network(result.logs.joined(separator: "\n"))
                }
            }

        case .timerEvent:
            guard let delayMilliseconds = WorkspaceFlowTimerParser.parseDelayMilliseconds(from: node) else {
                let currentValue = WorkspaceFlowTimerParser.displayExpression(for: node) ?? "empty"
                throw AppError.invalidDocument("Timer event '\(nodeName)' requires a valid delay. Received '\(currentValue)'.")
            }

            result.logs.append("Timer event \(nodeName) waiting \(delayMilliseconds) ms.")
            try await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
            result.logs.append("Timer event \(nodeName) completed.")
            result.nextTokens = outgoing.map { Token(nodeID: $0.targetID, context: token.context) }

        case .exclusiveGateway:
            guard !outgoing.isEmpty else {
                result.logs.append("Decision gateway \(nodeName) has no outgoing connections.")
                return result
            }

            let selectedConnection = chooseExclusiveConnection(
                from: outgoing,
                context: token.context
            ) ?? outgoing.first

            if let selectedConnection {
                result.logs.append("Decision gateway \(nodeName) selected flow \(selectedConnection.id).")
                if let onVariableCheckpoint {
                    await onVariableCheckpoint(variableCheckpoint(from: token.context))
                }
                result.nextTokens = [Token(nodeID: selectedConnection.targetID, context: token.context)]
            }

        case .parallelGateway:
            if incoming.count > 1 {
                result.joinArrival = JoinArrival(
                    nodeID: node.id,
                    requiredCount: incoming.count,
                    context: token.context,
                    nodeName: nodeName
                )
            } else if outgoing.count > 1 {
                result.logs.append("Parallel gateway \(nodeName) forked \(outgoing.count) branches.")
                result.nextTokens = outgoing.map { Token(nodeID: $0.targetID, context: token.context) }
            } else if let next = outgoing.first {
                result.nextTokens = [Token(nodeID: next.targetID, context: token.context)]
            } else {
                result.completedContexts = [token.context]
            }

        case .unsupported:
            throw AppError.invalidDocument("Unsupported BPMN element '\(node.bpmnType)' in flow execution.")
        }

            return result
        }
    }

    private func withExecutionHighlight(
        elementID: String,
        onHighlight: (@Sendable (WorkspaceFlowExecutionHighlightEvent) -> Void)?,
        operation: () async throws -> ProcessedTokenResult
    ) async rethrows -> ProcessedTokenResult {
        if let onHighlight {
            onHighlight(.enter(elementID: elementID))
        }
        do {
            let result = try await operation()
            if let onHighlight {
                onHighlight(.leave(elementID: elementID))
            }
            return result
        } catch {
            if let onHighlight {
                onHighlight(.leave(elementID: elementID))
            }
            throw error
        }
    }

    private func chooseExclusiveConnection(
        from connections: [WorkspaceFlowGraphConnection],
        context: RuntimeContext
    ) -> WorkspaceFlowGraphConnection? {
        if let matching = connections.first(where: { !$0.isDefault && evaluateCondition($0.name, context: context) }) {
            return matching
        }
        return connections.first(where: \.isDefault)
    }

    private func evaluateCondition(_ rawCondition: String, context: RuntimeContext) -> Bool {
        let gatewayContext = WorkspaceFlowGatewayConditionContext(
            lastStatusCode: context.lastStatusCode,
            environment: context.environment,
            globals: context.globals
        )
        return WorkspaceFlowGatewayCondition.evaluatesToTrue(rawCondition, context: gatewayContext)
    }

    private func executeWebSocketTask(
        resolvedRequest: WorkspaceFlowResolvedRequest,
        initialContext: RuntimeContext,
        utilityLibraries: [WorkspaceScriptUtility],
        onLog: (@Sendable (String) async -> Void)?
    ) async throws -> (context: RuntimeContext, logs: [String], statusCode: Int, durationMilliseconds: Double) {
        var updatedContext = initialContext
        var logs = ["Connecting WebSocket task \(resolvedRequest.request.name)."]
        if let onLog {
            await onLog("Connecting WebSocket task \(resolvedRequest.request.name).")
        }

        let prepared = try webSocketRunner.prepareConnection(
            request: resolvedRequest.request,
            globals: dictionaryToVariables(updatedContext.globals),
            collectionVariables: dictionaryToVariables(updatedContext.collectionVariables[resolvedRequest.collectionID] ?? [:]),
            environmentVariables: dictionaryToVariables(updatedContext.environment),
            workspaceEnvironments: updatedContext.environments,
            activeEnvironmentID: updatedContext.activeEnvironmentID,
            utilityLibraries: utilityLibraries
        )

        logs.append(contentsOf: prepared.logs)
        if let onLog {
            for entry in prepared.logs {
                await onLog(entry)
            }
        }
        applyVariableUpdates(
            to: &updatedContext,
            collectionID: resolvedRequest.collectionID,
            updatedGlobals: prepared.updatedGlobals,
            updatedCollection: prepared.updatedCollection,
            updatedEnvironment: prepared.updatedEnvironment,
            updatedEnvironments: prepared.updatedEnvironments,
            activeEnvironmentID: prepared.activeEnvironmentID
        )

        let connection = try await connectWebSocketWithTimeout(
            prepared: prepared,
            request: resolvedRequest.request
        )

        let inFlightRegistry = WorkspaceFlowExecutionCancellationScope.activeRequestRegistry
        inFlightRegistry?.registerWebSocket(connection)

        let startedAt = Date()
        logs.append("WebSocket connected.")
        if let onLog {
            await onLog("WebSocket connected.")
            await onLog("Waiting for WebSocket messages until the connection closes.")
        }

        defer {
            Task {
                await connection.disconnect()
                inFlightRegistry?.unregisterWebSocket(connection)
            }
        }

        while let event = await connection.receiveNextEvent() {
            try Task.checkCancellation()
            switch event {
            case .entry(let entry):
                logs.append("WebSocket message received.")
                if let onLog {
                    await onLog("WebSocket message received.")
                }
                let outcome = webSocketRunner.executeIncomingMessageScripts(
                    message: entry.body,
                    request: resolvedRequest.request,
                    globals: dictionaryToVariables(updatedContext.globals),
                    collectionVariables: dictionaryToVariables(updatedContext.collectionVariables[resolvedRequest.collectionID] ?? [:]),
                    environmentVariables: dictionaryToVariables(updatedContext.environment),
                    workspaceEnvironments: updatedContext.environments,
                    activeEnvironmentID: updatedContext.activeEnvironmentID,
                    utilityLibraries: utilityLibraries
                )
                applyVariableUpdates(
                    to: &updatedContext,
                    collectionID: resolvedRequest.collectionID,
                    updatedGlobals: outcome.updatedGlobals,
                    updatedCollection: outcome.updatedCollection,
                    updatedEnvironment: outcome.updatedEnvironment,
                    updatedEnvironments: outcome.updatedEnvironments,
                    activeEnvironmentID: outcome.activeEnvironmentID
                )
                logs.append(contentsOf: outcome.logs)
                if let onLog {
                    for entry in outcome.logs {
                        await onLog(entry)
                    }
                }

                if outcome.shouldDisconnect {
                    logs.append("WebSocket disconnect requested by script.")
                    if let onLog {
                        await onLog("WebSocket disconnect requested by script.")
                    }
                    await connection.disconnect()
                    let doneOutcome = webSocketRunner.executeDoneScripts(
                        cause: "Disconnected by script.",
                        request: resolvedRequest.request,
                        globals: dictionaryToVariables(updatedContext.globals),
                        collectionVariables: dictionaryToVariables(updatedContext.collectionVariables[resolvedRequest.collectionID] ?? [:]),
                        environmentVariables: dictionaryToVariables(updatedContext.environment),
                        workspaceEnvironments: updatedContext.environments,
                        activeEnvironmentID: updatedContext.activeEnvironmentID,
                        utilityLibraries: utilityLibraries
                    )
                    applyVariableUpdates(
                        to: &updatedContext,
                        collectionID: resolvedRequest.collectionID,
                        updatedGlobals: doneOutcome.updatedGlobals,
                        updatedCollection: doneOutcome.updatedCollection,
                        updatedEnvironment: doneOutcome.updatedEnvironment,
                        updatedEnvironments: doneOutcome.updatedEnvironments,
                        activeEnvironmentID: doneOutcome.activeEnvironmentID
                    )
                    logs.append(contentsOf: doneOutcome.logs)
                    logs.append("Socket cerrado: Disconnected by script.")
                    if let onLog {
                        for entry in doneOutcome.logs {
                            await onLog(entry)
                        }
                        await onLog("Socket cerrado: Disconnected by script.")
                    }
                    return (
                        context: updatedContext,
                        logs: logs,
                        statusCode: 101,
                        durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
                    )
                }

            case .closed(let message):
                let doneOutcome = webSocketRunner.executeDoneScripts(
                    cause: message,
                    request: resolvedRequest.request,
                    globals: dictionaryToVariables(updatedContext.globals),
                    collectionVariables: dictionaryToVariables(updatedContext.collectionVariables[resolvedRequest.collectionID] ?? [:]),
                    environmentVariables: dictionaryToVariables(updatedContext.environment),
                    workspaceEnvironments: updatedContext.environments,
                    activeEnvironmentID: updatedContext.activeEnvironmentID,
                    utilityLibraries: utilityLibraries
                )
                applyVariableUpdates(
                    to: &updatedContext,
                    collectionID: resolvedRequest.collectionID,
                    updatedGlobals: doneOutcome.updatedGlobals,
                    updatedCollection: doneOutcome.updatedCollection,
                    updatedEnvironment: doneOutcome.updatedEnvironment,
                    updatedEnvironments: doneOutcome.updatedEnvironments,
                    activeEnvironmentID: doneOutcome.activeEnvironmentID
                )
                logs.append(message)
                logs.append(contentsOf: doneOutcome.logs)
                if let onLog {
                    await onLog(message)
                    for entry in doneOutcome.logs {
                        await onLog(entry)
                    }
                }
                return (
                    context: updatedContext,
                    logs: logs,
                    statusCode: 101,
                    durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
                )

            case .failure(let message):
                let doneOutcome = webSocketRunner.executeDoneScripts(
                    cause: message,
                    request: resolvedRequest.request,
                    globals: dictionaryToVariables(updatedContext.globals),
                    collectionVariables: dictionaryToVariables(updatedContext.collectionVariables[resolvedRequest.collectionID] ?? [:]),
                    environmentVariables: dictionaryToVariables(updatedContext.environment),
                    workspaceEnvironments: updatedContext.environments,
                    activeEnvironmentID: updatedContext.activeEnvironmentID,
                    utilityLibraries: utilityLibraries
                )
                applyVariableUpdates(
                    to: &updatedContext,
                    collectionID: resolvedRequest.collectionID,
                    updatedGlobals: doneOutcome.updatedGlobals,
                    updatedCollection: doneOutcome.updatedCollection,
                    updatedEnvironment: doneOutcome.updatedEnvironment,
                    updatedEnvironments: doneOutcome.updatedEnvironments,
                    activeEnvironmentID: doneOutcome.activeEnvironmentID
                )
                logs.append("Receive error: \(message)")
                logs.append(contentsOf: doneOutcome.logs)
                if let onLog {
                    await onLog("Receive error: \(message)")
                    for entry in doneOutcome.logs {
                        await onLog(entry)
                    }
                }
                throw AppError.network(logs.joined(separator: "\n"))
            }
        }

        logs.append("WebSocket finished without a close event.")
        if let onLog {
            await onLog("WebSocket finished without a close event.")
        }
        return (
            context: updatedContext,
            logs: logs,
            statusCode: 101,
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
        )
    }

    private func connectWebSocketWithTimeout(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol {
        let timeoutSeconds = request.webSocketOpenTimeoutSeconds
        if timeoutSeconds <= 0 {
            return try await webSocketRunner.connect(prepared: prepared, request: request)
        }

        return try await withThrowingTaskGroup(of: (any WebSocketConnectionProtocol).self) { group in
            group.addTask {
                try await webSocketRunner.connect(prepared: prepared, request: request)
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

    private func variableCheckpoint(from context: RuntimeContext) -> WorkspaceFlowExecutionVariableCheckpoint {
        WorkspaceFlowExecutionVariableCheckpoint(
            updatedGlobals: dictionaryToVariables(context.globals),
            updatedEnvironment: dictionaryToVariables(context.environment),
            updatedEnvironments: context.environments,
            activeEnvironmentID: context.activeEnvironmentID,
            updatedCollections: context.collectionVariables.map {
                WorkspaceFlowCollectionUpdate(collectionID: $0.key, variables: dictionaryToVariables($0.value))
            }
            .sorted { $0.collectionID.uuidString < $1.collectionID.uuidString }
        )
    }

    private func applyVariableUpdates(
        to context: inout RuntimeContext,
        collectionID: UUID,
        updatedGlobals: [VariableValue],
        updatedCollection: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?
    ) {
        context.globals = dictionaryAllowingDuplicateKeys(from: updatedGlobals)
        // Los scripts exportan `runtime.environment` como diccionario; si queda incompleto respecto al
        // estado previo del flow, fusionar evita que desaparezcan claves (p. ej. `ambiente`) y que
        // `{{…}}` se resuelva luego solo con variables de colección (p. ej. `de` en lugar de `qa`).
        if !updatedEnvironment.isEmpty {
            let mergedEnvironmentVars = mergeVariableValues(
                existing: dictionaryToVariables(context.environment),
                updates: updatedEnvironment
            )
            context.environment = dictionaryAllowingDuplicateKeys(from: mergedEnvironmentVars)
            if !updatedEnvironments.isEmpty {
                context.environments = updatedEnvironments
            } else if let environmentIndex = context.activeEnvironmentID.flatMap({ currentEnvironmentID in
                context.environments.firstIndex(where: { $0.id == currentEnvironmentID })
            }) {
                context.environments[environmentIndex].variables = mergedEnvironmentVars
            }
        } else if !updatedEnvironments.isEmpty {
            context.environments = updatedEnvironments
        }
        if let activeEnvironmentID {
            context.activeEnvironmentID = activeEnvironmentID
        }
        context.collectionVariables[collectionID] = dictionaryAllowingDuplicateKeys(from: updatedCollection)
    }

    private func mergeVariableValues(existing: [VariableValue], updates: [VariableValue]) -> [VariableValue] {
        var merged: [String: VariableValue] = [:]
        for variable in existing {
            merged[variable.key] = variable
        }
        for update in updates {
            if var current = merged[update.key] {
                current.value = update.value
                current.isEnabled = update.isEnabled
                merged[update.key] = current
            } else {
                merged[update.key] = update
            }
        }
        return merged.values.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    /// Merges parallel (or end-of-run) runtime contexts. For **environment** string map, when two branches disagree on a key,
    /// prefers the value that **diverged** from `environmentJoinBaseline` (flow start snapshot, e.g. after batch preflight) over a value still equal to baseline.
    /// This avoids a branch that never received WebSocket updates from overwriting `transactionId` / `transactionCode` set by another branch.
    private func mergeContexts(_ contexts: [RuntimeContext], environmentJoinBaseline: [String: String]) -> RuntimeContext {
        guard var merged = contexts.first else {
            return RuntimeContext(
                globals: [:],
                environment: [:],
                environments: [],
                activeEnvironmentID: nil,
                collectionVariables: [:],
                lastStatusCode: nil
            )
        }

        for context in contexts.dropFirst() {
            merged.globals.merge(context.globals) { _, rhs in rhs }
            merged.environment = WorkspaceFlowParallelEnvironmentMerge.fold(
                merged.environment,
                context.environment,
                baseline: environmentJoinBaseline
            )
            if !context.environments.isEmpty {
                merged.environments = context.environments
            }
            merged.activeEnvironmentID = context.activeEnvironmentID ?? merged.activeEnvironmentID
            for (collectionID, variables) in context.collectionVariables {
                merged.collectionVariables[collectionID, default: [:]].merge(variables) { _, rhs in rhs }
            }
            merged.lastStatusCode = context.lastStatusCode ?? merged.lastStatusCode
        }

        return merged
    }

    private func dictionaryAllowingDuplicateKeys(from variables: [VariableValue]) -> [String: String] {
        var dictionary: [String: String] = [:]
        for variable in variables where variable.isEnabled {
            dictionary[variable.key] = variable.value
        }
        return dictionary
    }

    private func mergedCollectionVariables(
        from resolvedRequests: [WorkspaceFlowResolvedRequest]
    ) -> [UUID: [String: String]] {
        var merged: [UUID: [String: String]] = [:]

        for resolvedRequest in resolvedRequests {
            let variables = dictionaryAllowingDuplicateKeys(from: resolvedRequest.collectionVariables)
            merged[resolvedRequest.collectionID, default: [:]].merge(variables) { _, rhs in rhs }
        }

        return merged
    }

    private func dictionaryToVariables(_ dictionary: [String: String]) -> [VariableValue] {
        dictionary.keys.sorted().map { key in
            VariableValue(key: key, value: dictionary[key] ?? "", isEnabled: true)
        }
    }

    /// Local wall-clock timestamp like `[2026-04-11 14:32:01]` for terminal-style flow logs.
    private func bracketedLocalTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "[%04d-%02d-%02d %02d:%02d:%02d]",
            p.year ?? 0, p.month ?? 0, p.day ?? 0,
            p.hour ?? 0, p.minute ?? 0, p.second ?? 0
        )
    }

    /// Líneas opcionales justo debajo de `INICIO TAREA`: plantilla tal como en la petición y, si cambia, destino ya resuelto (sin pre-request).
    private func taskConnectionLogLines(
        request: APIRequestModel,
        context: RuntimeContext,
        collectionID: UUID,
        at date: Date = Date()
    ) -> [String] {
        let trimmedBase = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return [] }

        let resolver = VariableResolver()
        let varContext = VariableResolutionContext(
            globals: dictionaryToVariables(context.globals),
            collection: dictionaryToVariables(context.collectionVariables[collectionID] ?? [:]),
            environment: dictionaryToVariables(context.environment),
            local: request.localVariables.filter(\.isEnabled)
        )
        var resolved = resolver.resolve(trimmedBase, context: varContext, expressionEvaluator: nil)
        for entry in request.pathVariables where entry.isEnabled {
            let value = resolver.resolve(entry.value, context: varContext, expressionEvaluator: nil)
            resolved = resolved.replacingOccurrences(of: "{\(entry.key)}", with: value)
            resolved = resolved.replacingOccurrences(of: ":\(entry.key)", with: value)
        }
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let ts = bracketedLocalTimestamp(date)
        let templateLabel: String
        let resolvedLabel: String
        if request.isLambdaInvoke {
            templateLabel = "ARN o invoke (plantilla)"
            resolvedLabel = "Lambda ARN (resuelto)"
        } else if request.transportKind == .webSocket {
            templateLabel = "WebSocket URL (plantilla)"
            resolvedLabel = "WebSocket URL (resuelto)"
        } else {
            templateLabel = "URL (plantilla)"
            resolvedLabel = "URL (resuelto)"
        }

        var lines: [String] = ["\(ts)   \(templateLabel): \(trimmedBase)"]
        if trimmed != trimmedBase {
            lines.append("\(ts)   \(resolvedLabel): \(trimmed)")
        }
        return lines
    }

    private func taskStartLogLine(elementID: String, requestName: String?, at date: Date = Date()) -> String {
        let ts = bracketedLocalTimestamp(date)
        let trimmedName = requestName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedName.isEmpty {
            return "\(ts) ####### INICIO TAREA \(elementID) #######"
        }
        return "\(ts) ####### INICIO TAREA \(elementID) + \(trimmedName) #######"
    }

    private func taskEndLogLine(elementID: String, at date: Date = Date()) -> String {
        "\(bracketedLocalTimestamp(date)) ################## FIN TAREA \(elementID) ##################"
    }
}
