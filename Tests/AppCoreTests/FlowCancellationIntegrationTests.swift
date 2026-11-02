import EfbyPresentation
@testable import EfbyInfrastructure
import Foundation
import XCTest

final class FlowCancellationIntegrationTests: XCTestCase {
    private final class SuspendedRunner: HTTPExecutionServiceProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ExecutionOutcome, Never>?
        private var released = false
        private var count = 0
        let started = XCTestExpectation(description: "HTTP branch started")

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        func execute(request: APIRequestModel, globals: [VariableValue], collectionVariables: [VariableValue],
                     environmentVariables: [VariableValue], workspaceEnvironments: [EnvironmentProfile],
                     activeEnvironmentID: UUID?, utilityLibraries: [WorkspaceScriptUtility]) async throws -> ExecutionOutcome {
            await withCheckedContinuation { pending in
                lock.lock()
                count += 1
                let wasReleased = released
                if !wasReleased { continuation = pending }
                lock.unlock()
                started.fulfill()
                if wasReleased { pending.resume(returning: Self.outcome) }
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: Self.outcome)
        }

        private static var outcome: ExecutionOutcome {
            ExecutionOutcome(response: HTTPResponseModel(url: "https://example.invalid/late", statusCode: 200,
                statusText: "OK", headers: [], body: "{}", durationMilliseconds: 1, sizeBytes: 2, mimeType: "application/json"),
                rawRequest: "GET /late", rawResponse: "HTTP/1.1 200 OK", updatedGlobals: [], updatedCollection: [],
                updatedEnvironment: [VariableValue(key: "late", value: "must-not-apply")], updatedLocal: [], logs: [])
        }
    }

    private actor Checkpoints {
        var count = 0
        func record() { count += 1 }
    }

    private struct Scenario {
        var request = APIRequestModel(name: "Late", url: "https://example.invalid/late")
        let collectionID = UUID()
        var flow: WorkspaceFlowDefinition {
            WorkspaceFlowDefinition(name: "Cancellation", taskBindings: [WorkspaceFlowTaskBinding(elementID: "task", requestID: request.id)])
        }
        var graph: WorkspaceFlowGraphSnapshot {
            WorkspaceFlowGraphSnapshot(nodes: [
                WorkspaceFlowGraphNode(id: "start", name: "Start", bpmnType: "bpmn:StartEvent", nodeType: .startEvent),
                WorkspaceFlowGraphNode(id: "task", name: "Task", bpmnType: "bpmn:Task", nodeType: .task),
                WorkspaceFlowGraphNode(id: "end", name: "End", bpmnType: "bpmn:EndEvent", nodeType: .endEvent),
            ], connections: [
                WorkspaceFlowGraphConnection(id: "first", sourceID: "start", targetID: "task"),
                WorkspaceFlowGraphConnection(id: "last", sourceID: "task", targetID: "end"),
            ])
        }
        var requests: [WorkspaceFlowResolvedRequest] {
            [WorkspaceFlowResolvedRequest(requestID: request.id, collectionID: collectionID, request: request, collectionVariables: [])]
        }
    }

    func testPreviouslyCancelledFlowDoesNotStartAnyRequest() async throws {
        let runner = SuspendedRunner()
        let scenario = Scenario()
        let service = WorkspaceFlowExecutionService(runner: runner, webSocketRunner: WebSocketExecutionService())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.execute(flow: scenario.flow, graph: scenario.graph, globals: [], environment: [],
                                             utilityLibraries: [], resolvedRequests: scenario.requests)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(runner.callCount, 0)
    }

    func testCancelledFlowRejectsLateHTTPOutcomeAndDoesNotPublishCheckpoint() async throws {
        let runner = SuspendedRunner()
        let scenario = Scenario()
        let checkpoints = Checkpoints()
        let service = WorkspaceFlowExecutionService(runner: runner, webSocketRunner: WebSocketExecutionService())
        let task = Task {
            try await service.execute(flow: scenario.flow, graph: scenario.graph, globals: [], environment: [],
                utilityLibraries: [], resolvedRequests: scenario.requests, onVariableCheckpoint: { _ in await checkpoints.record() })
        }
        await fulfillment(of: [runner.started], timeout: 2)
        task.cancel()
        // This double intentionally ignores cancellation and returns a successful late response.
        runner.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let count = await checkpoints.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(runner.callCount, 1)
    }

    func testWebSocketOpenDeadlineCancelsNativeWaitBeforeLatePong() async throws {
        final class TransportState: @unchecked Sendable {
            let lock = NSLock()
            var cancelled = 0
            var fallbackFired = false
            func cancel() { lock.lock(); defer { lock.unlock() }; cancelled += 1 }
            func fallback() { lock.lock(); defer { lock.unlock() }; fallbackFired = true }
            var snapshot: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (cancelled, fallbackFired) }
        }
        let state = TransportState()
        let socketRunner = WebSocketExecutionService(connectionFactory: { _ in
            WebSocketConnection(transport: WebSocketTransport(
                resume: {}, ping: { completion in
                    // A bounded fallback prevents a broken cancellation bridge hanging the suite.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        state.fallback()
                        completion(nil)
                    }
                }, send: { _, completion in completion(nil) }, receive: { _ in },
                cancel: { _ in state.cancel() }, invalidate: {}, closeDescription: { "" }
            ))
        })
        var scenario = Scenario()
        scenario.request.transportKind = .webSocket
        scenario.request.url = "wss://example.invalid/pending"
        scenario.request.webSocketOpenTimeoutSeconds = 0.05
        let service = WorkspaceFlowExecutionService(runner: SuspendedRunner(), webSocketRunner: socketRunner)
        do {
            _ = try await service.execute(flow: scenario.flow, graph: scenario.graph, globals: [], environment: [],
                utilityLibraries: [], resolvedRequests: scenario.requests)
            XCTFail("Expected WebSocket open timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let snapshot = state.snapshot
        XCTAssertEqual(snapshot.0, 1)
        XCTAssertFalse(snapshot.1, "The open timeout waited for a pong instead of cancelling the native operation")
    }
}
