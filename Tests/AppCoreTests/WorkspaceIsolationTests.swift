import EfbyPresentation
import Foundation
import XCTest

final class WorkspaceIsolationTests: XCTestCase {
    @MainActor
    func testFailedWorkspaceLoadRestoresPreviousContextAndPreservesTargetSnapshot() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.newRequest()
        let target = fixture.root.appendingPathComponent("B")
        let collections = target.appendingPathComponent("collections")
        try FileManager.default.createDirectory(at: collections, withIntermediateDirectories: true)
        let corruptFile = collections.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("invalid JSON to preserve".utf8)
        try corruptBytes.write(to: corruptFile)
        let snapshotURL = await fixture.shared.workspaceSnapshotURL(in: target)
        let previousSnapshot = try Data(contentsOf: snapshotURL)

        vm.selectWorkspace(named: "B")
        try await eventually { vm.errorMessage != nil && vm.currentTab != nil }
        XCTAssertEqual(vm.workspace.activeWorkspaceName, "A")
        XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["A"])
        await vm.flushStateForApplicationTermination()
        XCTAssertEqual(try Data(contentsOf: snapshotURL), previousSnapshot)
        XCTAssertEqual(try Data(contentsOf: corruptFile), corruptBytes)
    }

    @MainActor
    func testRepeatedWebSocketSendDoesNotCancelPendingSendOrCloseConnection() async throws {
        let sendGate = WebSocketConnectGate()
        let connection = IsolationWebSocketConnection(sendGate: sendGate)
        let fixture = try await Fixture.make(webSocket: IsolationWebSocketService(connection: connection))
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.newRequest()
        let tab = try XCTUnwrap(vm.currentTab)
        tab.request.transportKind = .webSocket
        vm.sendCurrentRequest()
        await connection.waitUntilReceiving()
        vm.sendCurrentWebSocketMessage()
        await sendGate.waitUntilStarted()
        let pending = try XCTUnwrap(tab.webSocketSendTask)
        vm.sendCurrentWebSocketMessage()
        XCTAssertFalse(pending.isCancelled)
        await sendGate.release()
        await pending.value
        let sends = await connection.sendCount
        let disconnects = await connection.disconnectCount
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(disconnects, 0)
        XCTAssertEqual(tab.webSocketConnectionState, .connected)
        vm.closeTab(tab)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testSwitchingAndCreatingEmptyWorkspaceDoNotCopyFlowsOrUtilities() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.workspace.utilityLibraries = [WorkspaceScriptUtility(name: "Only A", source: "const onlyA = true;")]
        vm.workspace.flows = [WorkspaceFlowDefinition(name: "Only A")]

        vm.selectWorkspace(named: "B")
        try await eventually { vm.currentTab != nil }
        XCTAssertTrue(vm.workspace.flows.isEmpty)
        XCTAssertTrue(vm.workspace.utilityLibraries.isEmpty)
        let flows = try await fixture.shared.loadFlows(from: fixture.root.appendingPathComponent("B"))
        let utilities = try await fixture.shared.loadUtilityLibraries(from: fixture.root.appendingPathComponent("B"))
        XCTAssertTrue(flows.isEmpty)
        XCTAssertTrue(utilities.isEmpty)

        vm.workspace.utilityLibraries = [WorkspaceScriptUtility(name: "Only B", source: "const onlyB = true;")]
        vm.workspace.flows = [WorkspaceFlowDefinition(name: "Only B")]
        vm.createWorkspace(named: "Created")
        try await eventually { vm.workspace.activeWorkspaceName == "Created" && vm.currentTab != nil }
        XCTAssertTrue(vm.workspace.flows.isEmpty)
        XCTAssertTrue(vm.workspace.utilityLibraries.isEmpty)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testLateHTTPResultCannotModifyNewWorkspace() async throws {
        let runner = SuspendedHTTPRunner()
        let fixture = try await Fixture.make(http: runner)
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.newRequest()
        let tab = try XCTUnwrap(vm.currentTab)
        vm.sendCurrentRequest()
        try await runner.waitForCalls(1)
        let oldTask = try XCTUnwrap(tab.task)

        vm.selectWorkspace(named: "B")
        try await eventually { vm.currentTab != nil }
        XCTAssertTrue(oldTask.isCancelled)
        await runner.finish(0, with: .success(Self.outcome(marker: "late-A")))
        await oldTask.value

        XCTAssertEqual(vm.workspace.activeWorkspaceName, "B")
        XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["B"])
        XCTAssertTrue(vm.workspace.environments.isEmpty)
        XCTAssertTrue(vm.workspace.history.isEmpty)
        XCTAssertNil(vm.errorMessage)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testOldFailureAndCancellationDoNotFinishNewHTTPRequest() async throws {
        for oldError in [AppError.network("old failure") as any Error, CancellationError()] {
            let runner = SuspendedHTTPRunner()
            let fixture = try await Fixture.make(http: runner)
            let vm = fixture.viewModel
            vm.newRequest()
            let tab = try XCTUnwrap(vm.currentTab)
            vm.sendCurrentRequest()
            try await runner.waitForCalls(1)
            let first = try XCTUnwrap(tab.task)
            vm.sendCurrentRequest()
            try await runner.waitForCalls(2)
            let second = try XCTUnwrap(tab.task)

            await runner.finish(0, with: .failure(oldError))
            await first.value
            XCTAssertTrue(tab.isSending)
            XCTAssertNil(vm.errorMessage)
            XCTAssertFalse(tab.consoleLogs.contains(where: { $0.contains("old failure") }))
            await runner.finish(1, with: .success(Self.outcome(marker: "new")))
            await second.value
            XCTAssertFalse(tab.isSending)
            XCTAssertEqual(tab.response?.body, "new")
            await vm.flushStateForApplicationTermination()
            fixture.cleanup()
        }
    }

    @MainActor
    func testExplicitCancelAndClosingTabRejectLateSuccessfulResponse() async throws {
        for closeTab in [false, true] {
            let runner = SuspendedHTTPRunner()
            let fixture = try await Fixture.make(http: runner)
            let vm = fixture.viewModel
            vm.newRequest()
            let tab = try XCTUnwrap(vm.currentTab)
            vm.sendCurrentRequest()
            try await runner.waitForCalls(1)
            let task = try XCTUnwrap(tab.task)
            if closeTab { vm.closeTab(tab) } else { vm.cancelRequest(forTabID: tab.id) }
            await runner.finish(0, with: .success(Self.outcome(marker: "late")))
            await task.value
            XCTAssertTrue(task.isCancelled)
            XCTAssertFalse(tab.isSending)
            XCTAssertNil(tab.response)
            XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["A"])
            XCTAssertTrue(vm.workspace.history.isEmpty)
            await vm.flushStateForApplicationTermination()
            fixture.cleanup()
        }
    }

    @MainActor
    func testWorkspaceChangeDisconnectsWebSocketAndRejectsQueuedEvents() async throws {
        let connection = IsolationWebSocketConnection()
        let service = IsolationWebSocketService(connection: connection)
        let fixture = try await Fixture.make(webSocket: service)
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.newRequest()
        let tab = try XCTUnwrap(vm.currentTab)
        tab.request.transportKind = .webSocket
        vm.sendCurrentRequest()
        await connection.waitUntilReceiving()
        let transcriptCount = tab.webSocketTranscript.count
        vm.selectWorkspace(named: "B")
        try await eventually { vm.currentTab != nil }

        // This double retains and invokes the callback even after disconnect/cancellation.
        await connection.emit(.entry(WebSocketTranscriptEntry(direction: .incoming, body: "late")))
        await connection.emit(.failure("obsolete failure"))
        let disconnected = await connection.disconnectCount
        XCTAssertGreaterThanOrEqual(disconnected, 1)
        XCTAssertEqual(tab.webSocketTranscript.count, transcriptCount)
        XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["B"])
        XCTAssertNil(vm.errorMessage)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testLateWebSocketConnectionIsClosedWithoutApplyingPreparedVariables() async throws {
        let connection = IsolationWebSocketConnection()
        let connectGate = WebSocketConnectGate()
        let service = IsolationWebSocketService(connection: connection, connectGate: connectGate)
        let fixture = try await Fixture.make(webSocket: service)
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.newRequest()
        let tab = try XCTUnwrap(vm.currentTab)
        tab.request.transportKind = .webSocket
        vm.sendCurrentRequest()
        await connectGate.waitUntilStarted()
        let task = try XCTUnwrap(tab.task)
        vm.selectWorkspace(named: "B")
        try await eventually { vm.currentTab != nil }
        await connectGate.release()
        await task.value

        let disconnected = await connection.disconnectCount
        XCTAssertEqual(disconnected, 1)
        XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["B"])
        XCTAssertNil(tab.webSocketConnection)
        XCTAssertNil(vm.errorMessage)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testWebSocketPreparationLeavesMainActorResponsiveToCancel() async throws {
        let prepGate = BlockingPreparationGate()
        defer { prepGate.release() }
        let service = IsolationWebSocketService(connection: IsolationWebSocketConnection(), preparationGate: prepGate)
        let fixture = try await Fixture.make(webSocket: service)
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        vm.newRequest()
        let tab = try XCTUnwrap(vm.currentTab)
        tab.request.transportKind = .webSocket
        vm.sendCurrentRequest()
        let started = await XCTWaiter.fulfillment(of: [prepGate.started], timeout: 2)
        XCTAssertEqual(started, .completed)
        let task = try XCTUnwrap(tab.task)
        vm.cancelCurrentRequest()
        XCTAssertFalse(tab.isSending)
        XCTAssertFalse(prepGate.didTimeOut, "Preparation blocked the MainActor instead of allowing Cancel")
        prepGate.release()
        await task.value
        let count = await service.connectCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(tab.webSocketConnectionState, .disconnected)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testRapidWorkspaceSelectionKeepsLastSelectionAndRejectsOldLocalLoad() async throws {
        let gate = BlockingPreparationGate()
        let local = DelayedWorkspaceRepository(gate: gate)
        let fixture = try await Fixture.make(local: local)
        defer { gate.release(); fixture.cleanup() }
        let vm = fixture.viewModel
        let reload = Task { await vm.loadWorkspace() }
        let started = await XCTWaiter.fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(started, .completed)
        vm.selectWorkspace(named: "B")
        vm.selectWorkspace(named: "C")
        gate.release()
        await reload.value
        try await eventually { vm.currentTab != nil && vm.workspace.activeWorkspaceName == "C" }
        XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["C"])
        XCTAssertTrue(vm.workspace.flows.isEmpty)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testLateFlowOutcomeAndCheckpointCannotModifyNewWorkspace() async throws {
        let runner = SuspendedHTTPRunner()
        let fixture = try await Fixture.make(http: runner)
        defer { fixture.cleanup() }
        let vm = fixture.viewModel
        let request = APIRequestModel(name: "Flow request", url: "https://example.invalid/flow")
        vm.workspace.collections = [CollectionModel(info: CollectionInfoModel(name: "A"), items: [
            CollectionNode(name: "Flow request", kind: .request, request: request),
        ])]
        let flow = WorkspaceFlowDefinition(name: "A flow", bpmnXML: "", taskBindings: [WorkspaceFlowTaskBinding(elementID: "task", requestID: request.id)])
        vm.workspace.flows = [flow]
        let graph = WorkspaceFlowGraphSnapshot(nodes: [
            WorkspaceFlowGraphNode(id: "start", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent, outgoingIDs: ["task"]),
            WorkspaceFlowGraphNode(id: "task", name: "Task", bpmnType: "bpmn:Task", nodeType: .task, incomingIDs: ["start"], outgoingIDs: ["end"]),
            WorkspaceFlowGraphNode(id: "end", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent, incomingIDs: ["task"]),
        ], connections: [
            WorkspaceFlowGraphConnection(id: "one", sourceID: "start", targetID: "task"),
            WorkspaceFlowGraphConnection(id: "two", sourceID: "task", targetID: "end"),
        ])
        XCTAssertTrue(vm.validateFlow(flow, graph: graph).isValid)
        let execution = Task { try await vm.executeFlow(flow, graph: graph) }
        try await runner.waitForCalls(1)
        vm.selectWorkspace(named: "B")
        try await eventually { vm.currentTab != nil }
        try await runner.waitForCancellation(0)
        await runner.finish(0, with: .success(Self.outcome(marker: "late-flow")))
        do { _ = try await execution.value; XCTFail("Obsolete flow should cancel") }
        catch is CancellationError { }
        XCTAssertEqual(vm.workspace.globalVariables.map(\.value), ["B"])
        XCTAssertTrue(vm.workspace.environments.isEmpty)
        XCTAssertTrue(vm.flowRunSessions.isEmpty)
        XCTAssertTrue(vm.flowExecutionHighlightElementIDs.isEmpty)
        await vm.flushStateForApplicationTermination()
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Workspace transition did not finish")
                throw AppError.persistence("Workspace transition did not finish")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func outcome(marker: String) -> ExecutionOutcome {
        ExecutionOutcome(response: HTTPResponseModel(url: "https://example.invalid/late", statusCode: 200,
            statusText: "OK", headers: [], body: marker, durationMilliseconds: 1, sizeBytes: marker.utf8.count, mimeType: "text/plain"),
            rawRequest: "request", rawResponse: "response", updatedGlobals: [VariableValue(key: "workspace", value: marker)],
            updatedCollection: [], updatedEnvironment: [], updatedEnvironments: [EnvironmentProfile(name: marker)],
            updatedLocal: [], logs: [marker])
    }

    private struct Fixture {
        let root: URL
        let shared: SharedCollectionsRepository
        let viewModel: MainViewModel

        @MainActor static func make(
            http: any HTTPExecutionServiceProtocol = RequestExecutionService(),
            webSocket: any WebSocketExecutionServiceProtocol = WebSocketExecutionService(),
            local suppliedLocal: (any WorkspaceRepositoryProtocol)? = nil
        ) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceIsolationTests-\(UUID())", isDirectory: true)
            let shared = SharedCollectionsRepository()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let initial = WorkspaceState(sharedCollectionsDirectoryPath: root.path, activeWorkspaceName: "A",
                globalVariables: [VariableValue(key: "workspace", value: "A")])
            let local: any WorkspaceRepositoryProtocol = suppliedLocal ?? WorkspaceRepository(storageURL: root.appendingPathComponent("local.json"))
            try await local.save(initial)
            for name in ["A", "B", "C"] {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var snapshot = initial
                snapshot.activeWorkspaceName = name
                snapshot.globalVariables = [VariableValue(key: "workspace", value: name)]
                try await shared.saveWorkspaceSnapshot(snapshot, to: directory)
            }
            let vm = MainViewModel(dependencies: .live(workspaceRepository: local, sharedCollectionsRepository: shared,
                httpService: http, webSocketExecutionService: webSocket), autoloadWorkspace: false)
            vm.workspace = initial
            return Fixture(root: root, shared: shared, viewModel: vm)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor SuspendedHTTPRunner: HTTPExecutionServiceProtocol {
    private var continuations: [Int: CheckedContinuation<ExecutionOutcome, any Error>] = [:]
    private var callCount = 0
    private var waiters: [(Int, XCTestExpectation)] = []
    private var cancelledCalls: Set<Int> = []
    private var cancellationWaiters: [Int: XCTestExpectation] = [:]
    func execute(request: APIRequestModel, globals: [VariableValue], collectionVariables: [VariableValue],
                 environmentVariables: [VariableValue], workspaceEnvironments: [EnvironmentProfile],
                 activeEnvironmentID: UUID?, utilityLibraries: [WorkspaceScriptUtility]) async throws -> ExecutionOutcome {
        let index = callCount
        callCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[index] = continuation
                let ready = waiters.filter { callCount >= $0.0 }
                waiters.removeAll { callCount >= $0.0 }
                ready.forEach { $0.1.fulfill() }
            }
        } onCancel: {
            Task { await self.recordCancellation(index) }
        }
    }
    func waitForCalls(_ count: Int) async throws {
        if callCount >= count { return }
        let started = XCTestExpectation(description: "HTTP runner receives call \(count)")
        waiters.append((count, started))
        guard await XCTWaiter.fulfillment(of: [started], timeout: 3) == .completed else {
            throw AppError.network("HTTP test runner did not receive call \(count)")
        }
    }
    func finish(_ index: Int, with result: Result<ExecutionOutcome, any Error>) {
        continuations.removeValue(forKey: index)?.resume(with: result)
    }
    private func recordCancellation(_ index: Int) {
        cancelledCalls.insert(index)
        cancellationWaiters.removeValue(forKey: index)?.fulfill()
    }
    func waitForCancellation(_ index: Int) async throws {
        if cancelledCalls.contains(index) { return }
        let cancelled = XCTestExpectation(description: "HTTP runner receives cancellation")
        cancellationWaiters[index] = cancelled
        guard await XCTWaiter.fulfillment(of: [cancelled], timeout: 3) == .completed else {
            throw AppError.network("HTTP test runner did not receive cancellation")
        }
    }
}

private actor WebSocketConnectGate {
    private var started = false
    private var released = false
    private var waitingForStart: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        waitingForStart?.resume()
        waitingForStart = nil
        if !released { await withCheckedContinuation { pending = $0 } }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waitingForStart = $0 }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}

private actor IsolationWebSocketConnection: WebSocketConnectionProtocol {
    private let sendGate: WebSocketConnectGate?
    private var callback: (@Sendable (WebSocketReceiveEvent) async -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var disconnectCount = 0
    private(set) var sendCount = 0
    init(sendGate: WebSocketConnectGate? = nil) { self.sendGate = sendGate }
    func startReceiving(onEvent: @escaping @Sendable (WebSocketReceiveEvent) async -> Void) -> Task<Void, Never> {
        callback = onEvent
        waiting?.resume()
        waiting = nil
        return Task { }
    }
    func waitUntilReceiving() async {
        if callback != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func emit(_ event: WebSocketReceiveEvent) async { await callback?(event) }
    func receiveNextEvent() async -> WebSocketReceiveEvent? { nil }
    func send(text: String) async throws {
        sendCount += 1
        await withTaskCancellationHandler {
            await sendGate?.wait()
        } onCancel: {
            Task { await self.disconnect() }
        }
    }
    func sendPing() async throws { }
    func disconnect() { disconnectCount += 1 }
}

private final class BlockingPreparationGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Background operation started")
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func wait() {
        started.fulfill()
        let result = semaphore.wait(timeout: .now() + 2)
        lock.lock(); timedOut = result == .timedOut; lock.unlock()
    }
    func release() { semaphore.signal() }
}

private actor DelayedWorkspaceRepository: WorkspaceRepositoryProtocol {
    let gate: BlockingPreparationGate
    private var state = WorkspaceState()
    init(gate: BlockingPreparationGate) { self.gate = gate }
    func load() -> WorkspaceState { let snapshot = state; gate.wait(); return snapshot }
    func save(_ state: WorkspaceState) { self.state = state }
}

private final class IsolationWebSocketService: WebSocketExecutionServiceProtocol, @unchecked Sendable {
    let connection: IsolationWebSocketConnection
    let connectGate: WebSocketConnectGate?
    let preparationGate: BlockingPreparationGate?
    private let lock = NSLock()
    private var connections = 0
    var connectCount: Int { get async { lockedConnectCount() } }
    private func lockedConnectCount() -> Int { lock.lock(); defer { lock.unlock() }; return connections }
    init(connection: IsolationWebSocketConnection, connectGate: WebSocketConnectGate? = nil, preparationGate: BlockingPreparationGate? = nil) {
        self.connection = connection; self.connectGate = connectGate; self.preparationGate = preparationGate
    }
    func prepareConnection(request: APIRequestModel, globals: [VariableValue], collectionVariables: [VariableValue],
                           environmentVariables: [VariableValue], workspaceEnvironments: [EnvironmentProfile],
                           activeEnvironmentID: UUID?, utilityLibraries: [WorkspaceScriptUtility]) throws -> WebSocketPreparationOutcome {
        preparationGate?.wait()
        return WebSocketPreparationOutcome(urlRequest: URLRequest(url: URL(string: "wss://example.invalid/socket")!),
            rawRequest: "WebSocket", updatedGlobals: globals, updatedCollection: [], updatedEnvironment: [], updatedLocal: [], logs: [])
    }
    func connect(prepared: WebSocketPreparationOutcome, request: APIRequestModel) async throws -> any WebSocketConnectionProtocol {
        recordConnection()
        await connectGate?.wait()
        return connection
    }
    private func recordConnection() { lock.lock(); connections += 1; lock.unlock() }
    func resolveOutgoingMessage(from request: APIRequestModel, globals: [VariableValue], collectionVariables: [VariableValue],
                                environmentVariables: [VariableValue], utilityLibraries: [WorkspaceScriptUtility]) -> String { "message" }
    func resolve(_ text: String, globals: [VariableValue], collectionVariables: [VariableValue], environmentVariables: [VariableValue],
                 localVariables: [KeyValueEntry], request: APIRequestModel?, utilityLibraries: [WorkspaceScriptUtility]) -> String { text }
    func executeIncomingMessageScripts(message: String, request: APIRequestModel, globals: [VariableValue],
        collectionVariables: [VariableValue], environmentVariables: [VariableValue], workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?, utilityLibraries: [WorkspaceScriptUtility]) -> WebSocketMessageScriptOutcome {
        WebSocketMessageScriptOutcome(updatedGlobals: [VariableValue(key: "workspace", value: "stale-event")],
            updatedCollection: [], updatedEnvironment: [], updatedLocal: [], logs: [], shouldDisconnect: false)
    }
    func executeDoneScripts(cause: String, request: APIRequestModel, globals: [VariableValue], collectionVariables: [VariableValue],
        environmentVariables: [VariableValue], workspaceEnvironments: [EnvironmentProfile], activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility]) -> WebSocketMessageScriptOutcome {
        WebSocketMessageScriptOutcome(updatedGlobals: globals, updatedCollection: [], updatedEnvironment: [], updatedLocal: [],
            logs: [], shouldDisconnect: false)
    }
}
