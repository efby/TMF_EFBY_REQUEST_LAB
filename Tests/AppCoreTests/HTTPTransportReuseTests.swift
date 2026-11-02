import EfbyPresentation
@testable import EfbyInfrastructure
import Foundation
import Security
import XCTest

final class HTTPTransportReuseTests: XCTestCase {
    func testWebSocketPreparationDoesNotCreateTransportSessions() throws {
        let counter = HTTPReuseSessionCounter()
        let service = WebSocketExecutionService(sessionFactory: counter.makeSession)
        let request = APIRequestModel(
            name: "Preparation", transportKind: .webSocket, url: "wss://prepare.invalid/socket",
            tlsValidationMode: .insecure, minimumTLSVersion: .tls12
        )
        for _ in 0..<20 {
            let prepared = try service.prepareConnection(request: request, globals: [], collectionVariables: [], environmentVariables: [])
            XCTAssertTrue(prepared.logs.contains { $0.contains("validation is disabled") })
            XCTAssertTrue(prepared.logs.contains { $0.contains("TLS 1.2") })
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testSequentialRequestsReuseOneSession() async throws {
        let counter = HTTPReuseSessionCounter()
        let (service, baseSession) = makeService(counter: counter)
        defer { service.invalidate(); baseSession.invalidateAndCancel() }
        for _ in 0..<12 {
            let request = makeRequest(probe: HTTPReuseProbe())
            let outcome = try await execute(service, request: request)
            XCTAssertEqual(outcome.response.statusCode, 200)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testParallelRequestsReuseOneSession() async throws {
        let counter = HTTPReuseSessionCounter()
        let (service, baseSession) = makeService(counter: counter)
        defer { service.invalidate(); baseSession.invalidateAndCancel() }
        let requests = (0..<20).map { _ in makeRequest(probe: HTTPReuseProbe()) }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for request in requests {
                group.addTask {
                    try await service.execute(request: request, globals: [], collectionVariables: [], environmentVariables: []).response.statusCode
                }
            }
            var completed = 0
            for try await status in group {
                XCTAssertEqual(status, 200)
                completed += 1
            }
            XCTAssertEqual(completed, 20)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testTLSOptionsUseSeparateSessionsAndRetainInjectedProtocolConfiguration() async throws {
        let counter = HTTPReuseSessionCounter()
        let (service, baseSession) = makeService(counter: counter)
        defer { service.invalidate(); baseSession.invalidateAndCancel() }
        for validation in TLSValidationMode.allCases {
            for minimum in TLSMinimumVersionOption.allCases {
                for _ in 0..<2 {
                    var request = makeRequest(probe: HTTPReuseProbe())
                    request.tlsValidationMode = validation
                    request.minimumTLSVersion = minimum
                    _ = try await execute(service, request: request)
                }
            }
        }
        XCTAssertEqual(counter.count, TLSValidationMode.allCases.count * TLSMinimumVersionOption.allCases.count)
        XCTAssertTrue(counter.protocolInjectionPreserved)
        XCTAssertTrue(counter.minimumVersions.contains(.TLSv12))
        XCTAssertTrue(counter.minimumVersions.contains(.TLSv11))
        XCTAssertTrue(counter.minimumVersions.contains(.TLSv10))
    }

    func testCancellingOneParallelRequestDoesNotCancelItsSibling() async throws {
        let counter = HTTPReuseSessionCounter()
        let (service, baseSession) = makeService(counter: counter)
        defer { service.invalidate(); baseSession.invalidateAndCancel() }
        let firstStarted = expectation(description: "First request waits")
        let secondStarted = expectation(description: "Second request waits")
        let first = HTTPReuseProbe(holdResponse: true, onStart: { firstStarted.fulfill() })
        let second = HTTPReuseProbe(holdResponse: true, onStart: { secondStarted.fulfill() })
        let firstRequest = makeRequest(probe: first)
        let secondRequest = makeRequest(probe: second)
        let cancelled = expectation(description: "Only first request is cancelled")
        let siblingCompleted = expectation(description: "Sibling request completes")
        let firstTask = Task {
            do {
                _ = try await service.execute(request: firstRequest, globals: [], collectionVariables: [], environmentVariables: [])
                XCTFail("Cancelled request returned success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            cancelled.fulfill()
        }
        let secondTask = Task {
            do {
                let outcome = try await service.execute(request: secondRequest, globals: [], collectionVariables: [], environmentVariables: [])
                XCTAssertEqual(outcome.response.statusCode, 200)
            } catch {
                XCTFail("Cancelling a sibling invalidated the shared session: \(error)")
            }
            siblingCompleted.fulfill()
        }
        await fulfillment(of: [firstStarted, secondStarted], timeout: 2)
        let pooledSession = try XCTUnwrap(counter.firstSession)
        let nativeTasks = await withCheckedContinuation { continuation in
            pooledSession.getAllTasks { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(nativeTasks.count, 2)
        let taskDelegates = Set(nativeTasks.compactMap { $0.delegate.map { ObjectIdentifier($0) } })
        XCTAssertEqual(taskDelegates.count, 2, "TLS diagnostics must belong to each request, not a shared mutable delegate")
        firstTask.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        second.respond()
        await fulfillment(of: [siblingCompleted], timeout: 2)
        secondTask.cancel()
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.invalidations, 0)
    }

    func testExplicitInvalidationClosesPoolAndRejectsFurtherRequests() async throws {
        let invalidated = expectation(description: "Owned session invalidates")
        let counter = HTTPReuseSessionCounter(onInvalidation: { invalidated.fulfill() })
        let (service, baseSession) = makeService(counter: counter)
        defer { baseSession.invalidateAndCancel() }
        _ = try await execute(service, request: makeRequest(probe: HTTPReuseProbe()))
        service.invalidate()
        await fulfillment(of: [invalidated], timeout: 2)
        do {
            _ = try await execute(service, request: makeRequest(probe: HTTPReuseProbe()))
            XCTFail("An invalidated service must reject further requests")
        } catch {}
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.invalidations, 1)
    }

    func testDeinitializingServiceInvalidatesOwnedSessions() async throws {
        let invalidated = expectation(description: "Service deinit closes its session")
        let counter = HTTPReuseSessionCounter(onInvalidation: { invalidated.fulfill() })
        let configuration = makeConfiguration()
        let baseSession = URLSession(configuration: configuration)
        defer { baseSession.invalidateAndCancel() }
        var service: RequestExecutionService? = RequestExecutionService(session: baseSession, sessionFactory: counter.makeSession)
        _ = try await execute(try XCTUnwrap(service), request: makeRequest(probe: HTTPReuseProbe()))
        service = nil
        await fulfillment(of: [invalidated], timeout: 2)
        XCTAssertEqual(counter.invalidations, 1)
    }

    private func execute(_ service: RequestExecutionService, request: APIRequestModel) async throws -> ExecutionOutcome {
        try await service.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
    }

    private func makeService(counter: HTTPReuseSessionCounter) -> (RequestExecutionService, URLSession) {
        let baseSession = URLSession(configuration: makeConfiguration())
        return (RequestExecutionService(session: baseSession, sessionFactory: counter.makeSession), baseSession)
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPReuseURLProtocol.self]
        return configuration
    }

    private func makeRequest(probe: HTTPReuseProbe) -> APIRequestModel {
        let identifier = UUID().uuidString
        HTTPReuseURLProtocol.probes.insert(probe, for: identifier)
        return APIRequestModel(name: "Reuse", url: "https://reuse.invalid/\(identifier)")
    }
}

private final class HTTPReuseSessionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [URLSessionConfiguration] = []
    private var invalidatedCount = 0
    private weak var firstCreatedSession: URLSession?
    private let onInvalidation: (@Sendable () -> Void)?

    init(onInvalidation: (@Sendable () -> Void)? = nil) { self.onInvalidation = onInvalidation }
    var count: Int { withLock { configurations.count } }
    var invalidations: Int { withLock { invalidatedCount } }
    var firstSession: URLSession? { withLock { firstCreatedSession } }
    var minimumVersions: [tls_protocol_version_t] { withLock { configurations.map(\.tlsMinimumSupportedProtocolVersion) } }
    var protocolInjectionPreserved: Bool {
        withLock { configurations.allSatisfy { $0.protocolClasses?.contains { $0 == HTTPReuseURLProtocol.self } == true } }
    }

    func makeSession(configuration: URLSessionConfiguration, delegate: any URLSessionDelegate) -> URLSession {
        withLock { configurations.append(configuration) }
        // These tests intercept every request; forwarding retains the real authentication policy.
        let observer = HTTPReuseSessionDelegate(forwarding: delegate) {
            self.withLock { self.invalidatedCount += 1 }
            self.onInvalidation?()
        }
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        withLock { if firstCreatedSession == nil { firstCreatedSession = session } }
        return session
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class HTTPReuseSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let forwarding: any URLSessionDelegate
    private let onInvalidation: @Sendable () -> Void

    init(forwarding: any URLSessionDelegate, onInvalidation: @escaping @Sendable () -> Void) {
        self.forwarding = forwarding
        self.onInvalidation = onInvalidation
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { onInvalidation() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if forwarding.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))) {
            forwarding.urlSession?(session, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private final class HTTPReuseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: (@Sendable () -> Void)?
    let holdResponse: Bool
    let onStart: (@Sendable () -> Void)?

    init(holdResponse: Bool = false, onStart: (@Sendable () -> Void)? = nil) {
        self.holdResponse = holdResponse
        self.onStart = onStart
    }

    func start(delivery: @escaping @Sendable () -> Void) {
        lock.lock()
        self.delivery = delivery
        lock.unlock()
        onStart?()
        if !holdResponse { respond() }
    }

    func respond() {
        lock.lock()
        let delivery = delivery
        self.delivery = nil
        lock.unlock()
        delivery?()
    }

    func stop() {
        lock.lock()
        delivery = nil
        lock.unlock()
    }
}

private final class HTTPReuseURLProtocol: URLProtocol, @unchecked Sendable {
    static let probes = ProbeRegistry()
    private var probe: HTTPReuseProbe?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "reuse.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        probe = Self.probes.take(for: request.url?.lastPathComponent ?? "")
        guard let probe else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        probe.start { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("ok".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { probe?.stop() }

    final class ProbeRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: HTTPReuseProbe] = [:]
        func insert(_ probe: HTTPReuseProbe, for key: String) {
            lock.lock(); values[key] = probe; lock.unlock()
        }
        func take(for key: String) -> HTTPReuseProbe? {
            lock.lock()
            defer { lock.unlock() }
            return values.removeValue(forKey: key)
        }
    }
}
