import EfbyPresentation
import Foundation
import XCTest

final class RequestCancellationTests: XCTestCase {
    func testPrecancelledExecutionStartsNoTraffic() async throws {
        let probe = HTTPPendingRequestProbe()
        let (service, session, request) = makeService(probe: probe)
        defer { session.invalidateAndCancel() }
        let gate = HTTPRequestCancellationGate()
        let waiting = expectation(description: "Task waits before execution")
        let finished = expectation(description: "Cancelled execution completes")
        let task = Task {
            await gate.wait(onWaiting: { waiting.fulfill() })
            do {
                _ = try await service.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
                XCTFail("A precancelled request must not return success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(probe.startCount, 0)
    }

    func testCancellationWhileWaitingForResponseStopsNativeTask() async throws {
        let probe = HTTPPendingRequestProbe()
        let started = expectation(description: "Native request starts")
        let stopped = expectation(description: "Native request stops")
        probe.onStart = { started.fulfill() }
        probe.onStop = { stopped.fulfill() }
        let (service, session, request) = makeService(probe: probe)
        defer { session.invalidateAndCancel() }
        let finished = expectation(description: "Cancellation resolves without server response")
        let task = Task {
            do {
                _ = try await service.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
                XCTFail("Cancelled request returned success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished, stopped], timeout: 2)
        XCTAssertEqual(probe.startCount, 1)
    }

    func testCancellationAfterPartialResponseDoesNotRetry() async throws {
        let probe = HTTPPendingRequestProbe(responseStatus: 206)
        let responseDelivered = expectation(description: "First partial response is delivered")
        probe.onResponse = { responseDelivered.fulfill() }
        let (service, session, originalRequest) = makeService(probe: probe)
        defer { session.invalidateAndCancel() }
        var request = originalRequest
        request.retryOn206Count = 5
        request.retryOn206DelayMilliseconds = 60_000
        let executionRequest = request
        let finished = expectation(description: "Cancelled retry resolves")
        let task = Task {
            do {
                _ = try await service.execute(request: executionRequest, globals: [], collectionVariables: [], environmentVariables: [])
                XCTFail("Cancelled retry returned success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            finished.fulfill()
        }
        await fulfillment(of: [responseDelivered], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(probe.startCount, 1)
    }

    func testAlreadyCancelledFlowRegistryRejectsLateHTTPRegistration() async throws {
        let probe = HTTPPendingRequestProbe()
        let (service, session, request) = makeService(probe: probe)
        defer { session.invalidateAndCancel() }
        let registry = WorkspaceFlowActiveRequestRegistry()
        registry.cancelAllHTTPDataTasks()
        do {
            _ = try await WorkspaceFlowExecutionCancellationScope.$activeRequestRegistry.withValue(registry) {
                try await service.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
            }
            XCTFail("A cancelled flow must not start a late request")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.startCount, 0)
    }

    private func makeService(probe: HTTPPendingRequestProbe) -> (RequestExecutionService, URLSession, APIRequestModel) {
        let identifier = UUID().uuidString
        HTTPPendingURLProtocol.probes.insert(probe, for: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPPendingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let request = APIRequestModel(name: "Cancellation", url: "https://cancel.invalid/\(identifier)")
        return (RequestExecutionService(session: session), session, request)
    }
}

private actor HTTPRequestCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(onWaiting: @Sendable () -> Void) async {
        await withCheckedContinuation {
            continuation = $0
            onWaiting()
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class HTTPPendingRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    let responseStatus: Int?
    var onStart: (@Sendable () -> Void)?
    var onStop: (@Sendable () -> Void)?
    var onResponse: (@Sendable () -> Void)?

    init(responseStatus: Int? = nil) { self.responseStatus = responseStatus }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func recordStart() {
        lock.lock()
        starts += 1
        lock.unlock()
        onStart?()
    }
}

private final class HTTPPendingURLProtocol: URLProtocol, @unchecked Sendable {
    static let probes = ProbeRegistry()
    private var probe: HTTPPendingRequestProbe?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cancel.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        probe = Self.probes.take(for: request.url?.lastPathComponent ?? "")
        guard let probe else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        probe.recordStart()
        if let status = probe.responseStatus {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("partial".utf8))
            client?.urlProtocolDidFinishLoading(self)
            probe.onResponse?()
        }
    }

    override func stopLoading() { probe?.onStop?() }

    final class ProbeRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: HTTPPendingRequestProbe] = [:]

        func insert(_ probe: HTTPPendingRequestProbe, for key: String) {
            lock.lock()
            values[key] = probe
            lock.unlock()
        }

        func take(for key: String) -> HTTPPendingRequestProbe? {
            lock.lock()
            defer { lock.unlock() }
            return values.removeValue(forKey: key)
        }
    }
}
