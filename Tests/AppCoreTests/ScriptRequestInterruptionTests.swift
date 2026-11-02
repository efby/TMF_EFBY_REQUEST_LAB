import EfbyPresentation
import Foundation
import XCTest

private final class ScriptProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    private static let calls = Calls()
    static func reset() { calls.lock.lock(); defer { calls.lock.unlock() }; calls.count = 0 }
    static var count: Int { calls.lock.lock(); defer { calls.lock.unlock() }; return calls.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.lock.lock()
        Self.calls.count += 1
        Self.calls.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class ScriptRequestInterruptionTests: XCTestCase {
    // Finite fallback keeps these integration tests bounded even if watchdog installation regresses.
    private static let slowScript = "var end = Date.now() + 500; while (Date.now() < end) {}"

    private func executor() -> (RequestExecutionService, URLSession) {
        ScriptProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (RequestExecutionService(session: session, scriptEngine: ScriptEngine(executionTimeLimit: 0.03)), session)
    }

    func testPreRequestScriptInterruptionPreventsNetworkAndNextRequestStillWorks() async throws {
        let (executor, session) = executor()
        defer { session.invalidateAndCancel() }
        let request = APIRequestModel(name: "Blocked pre-request", url: "https://example.invalid/probe", scripts: [
            ScriptDefinition(name: "Bounded probe", listen: .preRequest, language: "javascript",
                source: "pm.environment.set('partial', 'discard'); " + Self.slowScript),
        ])
        do {
            _ = try await executor.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
            XCTFail("Expected script interruption before sending")
        } catch is CancellationError {
            XCTFail("A deadline must be reported separately from user cancellation")
        } catch { }
        XCTAssertEqual(ScriptProbeURLProtocol.count, 0)
        let next = try await executor.execute(request: APIRequestModel(name: "Next", url: "https://example.invalid/next"),
            globals: [], collectionVariables: [], environmentVariables: [])
        XCTAssertEqual(next.response.statusCode, 200)
        XCTAssertFalse(next.updatedEnvironment.contains(where: { $0.key == "partial" }))
        XCTAssertEqual(ScriptProbeURLProtocol.count, 1)
    }

    func testTemplateExpressionInterruptionPreventsNetwork() async throws {
        let (executor, session) = executor()
        defer { session.invalidateAndCancel() }
        let expression = "(function() { " + Self.slowScript + "; return 'must-not-send'; })()"
        let request = APIRequestModel(name: "Blocked template", method: .post, url: "https://example.invalid/probe",
            body: RequestBodyModel(kind: .raw, raw: "{{" + expression + "}}"))
        do {
            _ = try await executor.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
            XCTFail("Expected template interruption before sending")
        } catch { }
        XCTAssertEqual(ScriptProbeURLProtocol.count, 0)
    }

    func testPostResponseScriptInterruptionDoesNotReturnSuccessOrPartialVariables() async throws {
        let (executor, session) = executor()
        defer { session.invalidateAndCancel() }
        let request = APIRequestModel(name: "Blocked post-response", url: "https://example.invalid/probe", scripts: [
            ScriptDefinition(name: "Bounded probe", listen: .test, language: "javascript",
                source: "pm.environment.set('partial', 'discard'); " + Self.slowScript),
        ])
        do {
            _ = try await executor.execute(request: request, globals: [], collectionVariables: [], environmentVariables: [])
            XCTFail("Expected script interruption instead of successful outcome")
        } catch { }
        XCTAssertEqual(ScriptProbeURLProtocol.count, 1)
    }

    func testWebSocketPreparationAndPayloadResolutionRejectInterruptedScripts() throws {
        let service = WebSocketExecutionService(scriptEngine: ScriptEngine(executionTimeLimit: 0.03))
        let request = APIRequestModel(name: "Blocked socket", transportKind: .webSocket, url: "wss://example.invalid/probe", scripts: [
            ScriptDefinition(name: "Bounded probe", listen: .preRequest, language: "javascript", source: Self.slowScript),
        ])
        XCTAssertThrowsError(try service.prepareConnection(request: request, globals: [], collectionVariables: [], environmentVariables: []))
        let template = "{{(function() { " + Self.slowScript + "; return 'must-not-send'; })()}}"
        XCTAssertThrowsError(try service.resolve(template, globals: [], collectionVariables: [], environmentVariables: [], localVariables: []))
        let payloadRequest = APIRequestModel(name: "Blocked payload", transportKind: .webSocket, url: "wss://example.invalid/probe",
            body: RequestBodyModel(kind: .raw, raw: template))
        XCTAssertThrowsError(try service.resolveOutgoingMessage(from: payloadRequest, globals: [], collectionVariables: [], environmentVariables: []))
    }

    func testWebSocketMessageAndDoneInterruptionRequestDisconnectWithoutPartialVariables() {
        let service = WebSocketExecutionService(scriptEngine: ScriptEngine(executionTimeLimit: 0.03))
        let profile = EnvironmentProfile(name: "QA", variables: [VariableValue(key: "keep", value: "original")])
        let request = APIRequestModel(name: "Blocked callbacks", transportKind: .webSocket, url: "wss://example.invalid/probe", scripts: [
            ScriptDefinition(name: "Bounded callback", listen: .test, language: "javascript",
                source: "pm.environment.set('keep', 'partial'); " + Self.slowScript),
        ])
        let incoming = service.executeIncomingMessageScripts(message: "hello", request: request, globals: [], collectionVariables: [],
            environmentVariables: profile.variables, workspaceEnvironments: [profile], activeEnvironmentID: profile.id)
        let done = service.executeDoneScripts(cause: "closed", request: request, globals: [], collectionVariables: [],
            environmentVariables: profile.variables, workspaceEnvironments: [profile], activeEnvironmentID: profile.id)
        for outcome in [incoming, done] {
            XCTAssertNotNil(outcome.scriptError)
            XCTAssertTrue(outcome.shouldDisconnect)
            XCTAssertEqual(outcome.updatedEnvironments, [profile])
            XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "keep" })?.value, "original")
        }
    }
}
