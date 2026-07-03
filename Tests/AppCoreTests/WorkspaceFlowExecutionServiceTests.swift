import EfbyPresentation
import Foundation
import XCTest

final class WorkspaceFlowParallelEnvironmentMergeTests: XCTestCase {
    func testFoldPrefersBranchThatDivergedFromBaselineOverStaleBatchCopy() {
        let baseline = [
            "transactionId": "test0vgw8jDa4fIo5MkX3fGZ0t3D4VXKALXdDHtL",
            "transactionCode": "test0vgw8jDao0PUFrl2CTKWIqAilV",
        ]
        let staleBranch = baseline
        let liveBranch = [
            "transactionId": "test0vgwbPC529WKi1628QJQFjJuiD817VXbEfMH",
            "transactionCode": "test0vgwbPC641wq8u0u8REQRpkXhd",
        ]
        let mergedStaleFirst = WorkspaceFlowParallelEnvironmentMerge.fold(staleBranch, liveBranch, baseline: baseline)
        XCTAssertEqual(mergedStaleFirst["transactionId"], liveBranch["transactionId"])
        XCTAssertEqual(mergedStaleFirst["transactionCode"], liveBranch["transactionCode"])

        let mergedLiveFirst = WorkspaceFlowParallelEnvironmentMerge.fold(liveBranch, staleBranch, baseline: baseline)
        XCTAssertEqual(mergedLiveFirst["transactionId"], liveBranch["transactionId"])
        XCTAssertEqual(mergedLiveFirst["transactionCode"], liveBranch["transactionCode"])
    }
}

private struct MockWorkspaceFlowRunner: HTTPExecutionServiceProtocol {
    var outcomesByRequestID: [UUID: ExecutionOutcome]
    var executedRequestIDs: LockedRequestIDLog = LockedRequestIDLog()

    func execute(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> ExecutionOutcome {
        executedRequestIDs.append(request.id)
        guard let outcome = outcomesByRequestID[request.id] else {
            throw AppError.invalidDocument("Missing mock outcome for \(request.id)")
        }
        return outcome
    }
}

private struct MockWorkspaceFlowWebSocketRunner: WebSocketExecutionServiceProtocol {
    func prepareConnection(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) throws -> WebSocketPreparationOutcome {
        throw AppError.invalidDocument("WebSocket runner not used in this test.")
    }

    func connect(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol {
        throw AppError.invalidDocument("WebSocket runner not used in this test.")
    }

    func resolveOutgoingMessage(
        from request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> String {
        ""
    }

    func resolve(
        _ text: String,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        localVariables: [KeyValueEntry],
        request: APIRequestModel?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> String {
        text
    }

    func executeIncomingMessageScripts(
        message: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> WebSocketMessageScriptOutcome {
        WebSocketMessageScriptOutcome(
            updatedGlobals: globals,
            updatedCollection: collectionVariables,
            updatedEnvironment: environmentVariables,
            updatedEnvironments: workspaceEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            updatedLocal: [],
            logs: [],
            shouldDisconnect: false
        )
    }

    func executeDoneScripts(
        cause: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> WebSocketMessageScriptOutcome {
        WebSocketMessageScriptOutcome(
            updatedGlobals: globals,
            updatedCollection: collectionVariables,
            updatedEnvironment: environmentVariables,
            updatedEnvironments: workspaceEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            updatedLocal: [],
            logs: [],
            shouldDisconnect: false
        )
    }
}

private final class LockedRequestIDLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID] = []

    func append(_ requestID: UUID) {
        lock.lock()
        storage.append(requestID)
        lock.unlock()
    }

    var values: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class WorkspaceFlowExecutionServiceTests: XCTestCase {
    func testValidatorRejectsUnboundTaskNode() {
        let flow = WorkspaceFlowDefinition(name: "Assignment Flow")
        let graph = WorkspaceFlowGraphSnapshot(
            nodes: [
                WorkspaceFlowGraphNode(id: "StartEvent_1", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["Task_1"]),
                WorkspaceFlowGraphNode(id: "Task_1", name: "Assign Request", bpmnType: "bpmn:Task", nodeType: .task, incomingIDs: ["StartEvent_1"], outgoingIDs: ["EndEvent_1"]),
                WorkspaceFlowGraphNode(id: "EndEvent_1", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent, incomingIDs: ["Task_1"]),
            ],
            connections: [
                WorkspaceFlowGraphConnection(id: "Flow_1", sourceID: "StartEvent_1", targetID: "Task_1"),
                WorkspaceFlowGraphConnection(id: "Flow_2", sourceID: "Task_1", targetID: "EndEvent_1"),
            ]
        )

        let result = WorkspaceFlowValidator().validate(
            flow: flow,
            graph: graph,
            availableRequests: []
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains(where: { $0.elementID == "Task_1" && $0.message.contains("Every task node must be bound") }))
    }

    func testValidatorAcceptsStaleRequestUUIDWhenBoundNamesMatchWorkspace() {
        let staleRequestID = UUID()
        let liveRequestID = UUID()
        let binding = WorkspaceFlowTaskBinding(
            elementID: "Task_1",
            requestID: staleRequestID,
            boundCollectionName: "Demo Collection",
            boundRequestName: "Ping",
            boundTransportKind: .http
        )
        let available = [
            WorkspaceFlowRequestReference(
                requestID: liveRequestID,
                collectionID: UUID(),
                nodeID: UUID(),
                collectionName: "Demo Collection",
                requestName: "Ping",
                transportKind: .http
            ),
        ]
        let flow = WorkspaceFlowDefinition(name: "Portable Flow", taskBindings: [binding])
        let graph = WorkspaceFlowGraphSnapshot(
            nodes: [
                WorkspaceFlowGraphNode(id: "StartEvent_1", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["Task_1"]),
                WorkspaceFlowGraphNode(id: "Task_1", name: "Ping", bpmnType: "bpmn:Task", nodeType: .task, incomingIDs: ["StartEvent_1"], outgoingIDs: ["EndEvent_1"]),
                WorkspaceFlowGraphNode(id: "EndEvent_1", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent, incomingIDs: ["Task_1"]),
            ],
            connections: [
                WorkspaceFlowGraphConnection(id: "Flow_1", sourceID: "StartEvent_1", targetID: "Task_1"),
                WorkspaceFlowGraphConnection(id: "Flow_2", sourceID: "Task_1", targetID: "EndEvent_1"),
            ]
        )

        let result = WorkspaceFlowValidator().validate(
            flow: flow,
            graph: graph,
            availableRequests: available
        )

        XCTAssertTrue(result.isValid, "Expected stale UUID to remap via bound collection + request name.")
    }

    func testExecutionRunsBoundTaskAndMergesVariableUpdates() async throws {
        let requestID = UUID()
        let collectionID = UUID()
        let outcome = ExecutionOutcome(
            response: HTTPResponseModel(
                url: "https://api.example.com/assign",
                statusCode: 200,
                statusText: "OK",
                headers: [],
                body: #"{"ok":true}"#,
                durationMilliseconds: 42,
                sizeBytes: 11,
                mimeType: "application/json"
            ),
            rawRequest: "GET /assign",
            rawResponse: "HTTP/1.1 200 OK",
            updatedGlobals: [VariableValue(key: "traceId", value: "flow-123")],
            updatedCollection: [VariableValue(key: "collectionToken", value: "abc")],
            updatedEnvironment: [VariableValue(key: "assignedPinpad", value: "pinpad-01")],
            updatedLocal: [],
            logs: ["Task executed"]
        )

        let runner = MockWorkspaceFlowRunner(outcomesByRequestID: [requestID: outcome])
        let service = WorkspaceFlowExecutionService(
            runner: runner,
            webSocketRunner: MockWorkspaceFlowWebSocketRunner()
        )
        let flow = WorkspaceFlowDefinition(
            name: "Assignment Flow",
            taskBindings: [
                WorkspaceFlowTaskBinding(elementID: "Task_1", requestID: requestID),
            ]
        )
        let graph = WorkspaceFlowGraphSnapshot(
            nodes: [
                WorkspaceFlowGraphNode(id: "StartEvent_1", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["Task_1"]),
                WorkspaceFlowGraphNode(id: "Task_1", name: "Assign Request", bpmnType: "bpmn:Task", nodeType: .task, incomingIDs: ["StartEvent_1"], outgoingIDs: ["EndEvent_1"]),
                WorkspaceFlowGraphNode(id: "EndEvent_1", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent, incomingIDs: ["Task_1"]),
            ],
            connections: [
                WorkspaceFlowGraphConnection(id: "Flow_1", sourceID: "StartEvent_1", targetID: "Task_1"),
                WorkspaceFlowGraphConnection(id: "Flow_2", sourceID: "Task_1", targetID: "EndEvent_1"),
            ]
        )
        let resolvedRequest = WorkspaceFlowResolvedRequest(
            requestID: requestID,
            collectionID: collectionID,
            request: APIRequestModel(
                id: requestID,
                name: "Assign Request",
                method: .get,
                url: "https://api.example.com/assign"
            ),
            collectionVariables: [VariableValue(key: "collectionToken", value: "old")]
        )

        let result = try await service.execute(
            flow: flow,
            graph: graph,
            globals: [VariableValue(key: "traceId", value: "initial")],
            environment: [VariableValue(key: "assignedPinpad", value: "")],
            utilityLibraries: [],
            resolvedRequests: [resolvedRequest]
        )

        XCTAssertEqual(runner.executedRequestIDs.values, [requestID])
        XCTAssertEqual(result.taskResults.count, 1)
        XCTAssertEqual(result.taskResults.first?.statusCode, 200)
        XCTAssertEqual(result.updatedGlobals.first(where: { $0.key == "traceId" })?.value, "flow-123")
        XCTAssertEqual(result.updatedEnvironment.first(where: { $0.key == "assignedPinpad" })?.value, "pinpad-01")
        XCTAssertEqual(result.updatedCollections.first?.variables.first(where: { $0.key == "collectionToken" })?.value, "abc")
        XCTAssertTrue(result.logs.contains(where: { $0.contains("Reached end event") }))
    }

    func testExecutionEmitsVariableCheckpointAfterHttpTask() async throws {
        let requestID = UUID()
        let collectionID = UUID()
        let outcome = ExecutionOutcome(
            response: HTTPResponseModel(
                url: "https://api.example.com/assign",
                statusCode: 200,
                statusText: "OK",
                headers: [],
                body: #"{"ok":true}"#,
                durationMilliseconds: 42,
                sizeBytes: 11,
                mimeType: "application/json"
            ),
            rawRequest: "GET /assign",
            rawResponse: "HTTP/1.1 200 OK",
            updatedGlobals: [VariableValue(key: "traceId", value: "flow-456")],
            updatedCollection: [VariableValue(key: "collectionToken", value: "xyz")],
            updatedEnvironment: [VariableValue(key: "assignedPinpad", value: "pinpad-99")],
            updatedLocal: [],
            logs: []
        )

        let runner = MockWorkspaceFlowRunner(outcomesByRequestID: [requestID: outcome])
        let service = WorkspaceFlowExecutionService(
            runner: runner,
            webSocketRunner: MockWorkspaceFlowWebSocketRunner()
        )
        let flow = WorkspaceFlowDefinition(
            name: "Checkpoint Flow",
            taskBindings: [
                WorkspaceFlowTaskBinding(elementID: "Task_1", requestID: requestID),
            ]
        )
        let graph = WorkspaceFlowGraphSnapshot(
            nodes: [
                WorkspaceFlowGraphNode(id: "StartEvent_1", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["Task_1"]),
                WorkspaceFlowGraphNode(id: "Task_1", name: "Ping", bpmnType: "bpmn:Task", nodeType: .task, incomingIDs: ["StartEvent_1"], outgoingIDs: ["EndEvent_1"]),
                WorkspaceFlowGraphNode(id: "EndEvent_1", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent, incomingIDs: ["Task_1"]),
            ],
            connections: [
                WorkspaceFlowGraphConnection(id: "Flow_1", sourceID: "StartEvent_1", targetID: "Task_1"),
                WorkspaceFlowGraphConnection(id: "Flow_2", sourceID: "Task_1", targetID: "EndEvent_1"),
            ]
        )
        let resolvedRequest = WorkspaceFlowResolvedRequest(
            requestID: requestID,
            collectionID: collectionID,
            request: APIRequestModel(
                id: requestID,
                name: "Ping",
                method: .get,
                url: "https://api.example.com/assign"
            ),
            collectionVariables: [VariableValue(key: "collectionToken", value: "old")]
        )

        final class CheckpointCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }

            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        final class LastCheckpointHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: WorkspaceFlowExecutionVariableCheckpoint?
            func set(_ checkpoint: WorkspaceFlowExecutionVariableCheckpoint) {
                lock.lock()
                storage = checkpoint
                lock.unlock()
            }

            func get() -> WorkspaceFlowExecutionVariableCheckpoint? {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        let counter = CheckpointCounter()
        let lastCheckpoint = LastCheckpointHolder()
        _ = try await service.execute(
            flow: flow,
            graph: graph,
            globals: [VariableValue(key: "traceId", value: "initial")],
            environment: [VariableValue(key: "assignedPinpad", value: "")],
            utilityLibraries: [],
            resolvedRequests: [resolvedRequest],
            onVariableCheckpoint: { checkpoint in
                counter.increment()
                lastCheckpoint.set(checkpoint)
            }
        )

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(lastCheckpoint.get()?.updatedGlobals.first(where: { $0.key == "traceId" })?.value, "flow-456")
        XCTAssertEqual(lastCheckpoint.get()?.updatedEnvironment.first(where: { $0.key == "assignedPinpad" })?.value, "pinpad-99")
    }

    func testBPMNParserRecognizesTerminateEndEvent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <definitions xmlns="http://www.omg.org/spec/BPMN/20100524/MODEL">
          <process id="Process_1" isExecutable="true">
            <startEvent id="StartEvent_1" />
            <endEvent id="End_Terminate">
              <terminateEventDefinition />
            </endEvent>
            <sequenceFlow id="Flow_1" sourceRef="StartEvent_1" targetRef="End_Terminate" />
          </process>
        </definitions>
        """
        let graph = try WorkspaceFlowBPMNParser().parse(xml: xml)
        let end = graph.nodes.first(where: { $0.id == "End_Terminate" })
        XCTAssertEqual(end?.nodeType, .terminateEndEvent)
        XCTAssertEqual(end?.bpmnType, "bpmn:EndEvent")
    }

    func testTerminateEndEventCancelsParallelSlowBranch() async throws {
        let slowRequestID = UUID()
        let collectionID = UUID()
        let slowOutcome = ExecutionOutcome(
            response: HTTPResponseModel(
                url: "https://example.com/slow",
                statusCode: 200,
                statusText: "OK",
                headers: [],
                body: "{}",
                durationMilliseconds: 1,
                sizeBytes: 2,
                mimeType: "application/json"
            ),
            rawRequest: "GET /slow",
            rawResponse: "HTTP/1.1 200 OK",
            updatedGlobals: [],
            updatedCollection: [],
            updatedEnvironment: [VariableValue(key: "fromSlow", value: "should-not-apply")],
            updatedLocal: [],
            logs: []
        )

        let runner = DelayingWorkspaceFlowRunner(delayNanoseconds: 60_000_000_000, outcome: slowOutcome)
        let service = WorkspaceFlowExecutionService(
            runner: runner,
            webSocketRunner: MockWorkspaceFlowWebSocketRunner()
        )
        let flow = WorkspaceFlowDefinition(
            name: "Parallel terminate",
            taskBindings: [
                WorkspaceFlowTaskBinding(elementID: "Task_Slow", requestID: slowRequestID),
            ]
        )
        let graph = WorkspaceFlowGraphSnapshot(
            nodes: [
                WorkspaceFlowGraphNode(id: "StartEvent_1", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["ParallelGateway_1"]),
                WorkspaceFlowGraphNode(
                    id: "ParallelGateway_1",
                    name: "Fork",
                    bpmnType: "bpmn:ParallelGateway",
                    nodeType: .parallelGateway,
                    incomingIDs: ["StartEvent_1"],
                    outgoingIDs: ["Timer_1", "Task_Slow"]
                ),
                WorkspaceFlowGraphNode(
                    id: "Timer_1",
                    name: "25ms",
                    bpmnType: "bpmn:IntermediateCatchEvent",
                    nodeType: .timerEvent,
                    timerDefinition: "25ms",
                    incomingIDs: ["ParallelGateway_1"],
                    outgoingIDs: ["End_Terminate"]
                ),
                WorkspaceFlowGraphNode(
                    id: "Task_Slow",
                    name: "Slow",
                    bpmnType: "bpmn:Task",
                    nodeType: .task,
                    incomingIDs: ["ParallelGateway_1"],
                    outgoingIDs: ["End_Normal"]
                ),
                WorkspaceFlowGraphNode(
                    id: "End_Terminate",
                    name: "Stop all",
                    bpmnType: "bpmn:EndEvent",
                    nodeType: .terminateEndEvent,
                    incomingIDs: ["Timer_1"],
                    outgoingIDs: []
                ),
                WorkspaceFlowGraphNode(
                    id: "End_Normal",
                    name: "End",
                    bpmnType: "bpmn:EndEvent",
                    nodeType: .endEvent,
                    incomingIDs: ["Task_Slow"],
                    outgoingIDs: []
                ),
            ],
            connections: [
                WorkspaceFlowGraphConnection(id: "F0", sourceID: "StartEvent_1", targetID: "ParallelGateway_1"),
                WorkspaceFlowGraphConnection(id: "F1", sourceID: "ParallelGateway_1", targetID: "Timer_1"),
                WorkspaceFlowGraphConnection(id: "F2", sourceID: "ParallelGateway_1", targetID: "Task_Slow"),
                WorkspaceFlowGraphConnection(id: "F3", sourceID: "Timer_1", targetID: "End_Terminate"),
                WorkspaceFlowGraphConnection(id: "F4", sourceID: "Task_Slow", targetID: "End_Normal"),
            ]
        )
        let resolvedSlow = WorkspaceFlowResolvedRequest(
            requestID: slowRequestID,
            collectionID: collectionID,
            request: APIRequestModel(
                id: slowRequestID,
                name: "Slow",
                method: .get,
                url: "https://example.com/slow"
            ),
            collectionVariables: []
        )

        let result = try await service.execute(
            flow: flow,
            graph: graph,
            globals: [],
            environment: [VariableValue(key: "fromSlow", value: "")],
            utilityLibraries: [],
            resolvedRequests: [resolvedSlow]
        )

        XCTAssertTrue(result.logs.contains(where: { $0.contains("Terminate end event") }))
        XCTAssertTrue(result.logs.contains(where: { $0.localizedCaseInsensitiveContains("terminate end event stopped") }))
        let completed = await runner.completedAfterSleepRequestIDs()
        XCTAssertEqual(completed, [], "Slow HTTP task should not finish after terminate cancels the branch.")
        XCTAssertEqual(result.updatedEnvironment.first(where: { $0.key == "fromSlow" })?.value ?? "", "")
    }
}

private actor DelayingRunnerCompletionLog {
    private var ids: [UUID] = []

    func append(_ id: UUID) {
        ids.append(id)
    }

    func values() -> [UUID] {
        ids
    }
}

private final class DelayingWorkspaceFlowRunner: HTTPExecutionServiceProtocol, @unchecked Sendable {
    private let delayNanoseconds: UInt64
    private let outcome: ExecutionOutcome
    private let completionLog = DelayingRunnerCompletionLog()

    init(delayNanoseconds: UInt64, outcome: ExecutionOutcome) {
        self.delayNanoseconds = delayNanoseconds
        self.outcome = outcome
    }

    func completedAfterSleepRequestIDs() async -> [UUID] {
        await completionLog.values()
    }

    func execute(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) async throws -> ExecutionOutcome {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        await completionLog.append(request.id)
        return outcome
    }
}
