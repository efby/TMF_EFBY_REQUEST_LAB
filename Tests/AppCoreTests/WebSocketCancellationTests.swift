import EfbyPresentation
@testable import EfbyInfrastructure
import Foundation
import XCTest

final class WebSocketCancellationTests: XCTestCase {
    func testCancellingOpenClosesTransportAndIgnoresLatePong() async throws {
        let transport = PendingWebSocketTransport()
        let pingStarted = expectation(description: "Opening ping starts")
        transport.onPing = { pingStarted.fulfill() }
        let service = WebSocketExecutionService(connectionFactory: { _ in WebSocketConnection(transport: transport.adapter) })
        let request = APIRequestModel(name: "Socket", transportKind: .webSocket, url: "wss://cancel.invalid/socket")
        let prepared = try service.prepareConnection(request: request, globals: [], collectionVariables: [], environmentVariables: [])
        let finished = expectation(description: "Opening cancellation resolves without pong")
        let task = Task {
            do {
                _ = try await service.connect(prepared: prepared, request: request)
                XCTFail("Cancelled opening returned a connection")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        await fulfillment(of: [pingStarted], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        transport.completePingsTwice()
        XCTAssertEqual(transport.resumeCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testPrecancelledOpenDoesNotCreateOrResumeTransport() async throws {
        let transport = PendingWebSocketTransport()
        let service = WebSocketExecutionService(connectionFactory: { _ in
            transport.recordFactoryCall()
            return WebSocketConnection(transport: transport.adapter)
        })
        let request = APIRequestModel(name: "Socket", transportKind: .webSocket, url: "wss://cancel.invalid/socket")
        let prepared = try service.prepareConnection(request: request, globals: [], collectionVariables: [], environmentVariables: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await service.connect(prepared: prepared, request: request)
                XCTFail("Precancelled opening returned a connection")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        await task.value
        XCTAssertEqual(transport.factoryCount, 0)
        XCTAssertEqual(transport.resumeCount, 0)
    }

    func testCancellingPingResolvesWithoutCallbackAndClosesOnce() async throws {
        let transport = PendingWebSocketTransport()
        let pingStarted = expectation(description: "Ping starts")
        transport.onPing = { pingStarted.fulfill() }
        let connection = WebSocketConnection(transport: transport.adapter)
        let finished = expectation(description: "Ping cancellation completes")
        let task = Task {
            do {
                try await connection.sendPing()
                XCTFail("Cancelled ping returned success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        await fulfillment(of: [pingStarted], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        transport.completePingsTwice()
        await connection.disconnect()
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testDisconnectResolvesPendingReceiveAndIgnoresLateMessage() async throws {
        let transport = PendingWebSocketTransport()
        let receiveStarted = expectation(description: "Receive starts")
        transport.onReceive = { receiveStarted.fulfill() }
        let connection = WebSocketConnection(transport: transport.adapter)
        let finished = expectation(description: "Disconnect releases receive")
        let receiver = Task {
            let event = await connection.receiveNextEvent()
            XCTAssertNil(event)
            finished.fulfill()
        }
        await fulfillment(of: [receiveStarted], timeout: 2)
        await connection.disconnect()
        await fulfillment(of: [finished], timeout: 2)
        transport.completeReceivesTwice()
        receiver.cancel()
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testCancellingReceiveClosesTransportWithoutNetworkCallback() async throws {
        let transport = PendingWebSocketTransport()
        let receiveStarted = expectation(description: "Receive starts")
        transport.onReceive = { receiveStarted.fulfill() }
        let connection = WebSocketConnection(transport: transport.adapter)
        let finished = expectation(description: "Receive cancellation completes")
        let receiver = Task {
            let event = await connection.receiveNextEvent()
            XCTAssertNil(event)
            finished.fulfill()
        }
        await fulfillment(of: [receiveStarted], timeout: 2)
        receiver.cancel()
        await fulfillment(of: [finished], timeout: 2)
        transport.completeReceivesTwice()
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testCancellingSendResolvesWithoutCallbackAndIgnoresLateCompletion() async throws {
        let transport = PendingWebSocketTransport()
        let sendStarted = expectation(description: "Send starts")
        transport.onSend = { sendStarted.fulfill() }
        let connection = WebSocketConnection(transport: transport.adapter)
        let finished = expectation(description: "Send cancellation completes")
        let task = Task {
            do {
                try await connection.send(text: "hello")
                XCTFail("Cancelled send returned success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        await fulfillment(of: [sendStarted], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        transport.completeSendsTwice()
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(transport.invalidateCount, 1)
    }

    func testAlreadyCancelledFlowDisconnectsLateWebSocketRegistration() async {
        let transport = PendingWebSocketTransport()
        let closed = expectation(description: "Late socket closes")
        transport.onClose = { closed.fulfill() }
        let connection = WebSocketConnection(transport: transport.adapter)
        let registry = WorkspaceFlowActiveRequestRegistry()
        registry.cancelAllHTTPDataTasks()
        registry.registerWebSocket(connection)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(transport.closeCount, 1)
    }
}

private final class PendingWebSocketTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var resumes = 0
    private var closes = 0
    private var invalidates = 0
    private var factories = 0
    private var pings: [@Sendable (Error?) -> Void] = []
    private var receives: [@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void] = []
    private var sends: [@Sendable (Error?) -> Void] = []
    var onPing: (@Sendable () -> Void)?
    var onReceive: (@Sendable () -> Void)?
    var onSend: (@Sendable () -> Void)?
    var onClose: (@Sendable () -> Void)?

    var adapter: WebSocketTransport {
        WebSocketTransport(
            resume: { self.withLock { self.resumes += 1 } },
            ping: { completion in
                self.withLock { self.pings.append(completion) }
                self.onPing?()
            },
            send: { _, completion in
                self.withLock { self.sends.append(completion) }
                self.onSend?()
            },
            receive: { completion in
                self.withLock { self.receives.append(completion) }
                self.onReceive?()
            },
            cancel: { _ in
                self.withLock { self.closes += 1 }
                self.onClose?()
            },
            invalidate: { self.withLock { self.invalidates += 1 } },
            closeDescription: { "" }
        )
    }

    var resumeCount: Int { withLock { resumes } }
    var closeCount: Int { withLock { closes } }
    var invalidateCount: Int { withLock { invalidates } }
    var factoryCount: Int { withLock { factories } }
    func recordFactoryCall() { withLock { factories += 1 } }

    func completePingsTwice() {
        let callbacks = withLock { pings }
        for callback in callbacks { callback(nil); callback(nil) }
    }

    func completeReceivesTwice() {
        let callbacks = withLock { receives }
        for callback in callbacks { callback(.success(.string("late"))); callback(.success(.string("duplicate"))) }
    }

    func completeSendsTwice() {
        let callbacks = withLock { sends }
        for callback in callbacks { callback(nil); callback(nil) }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
