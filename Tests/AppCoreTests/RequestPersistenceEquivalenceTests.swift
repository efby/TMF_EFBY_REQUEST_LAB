@testable import EfbyPresentation
import Foundation
import XCTest

@MainActor
final class RequestPersistenceEquivalenceTests: XCTestCase {
    private let coordinator = RequestTabsCoordinator()

    func testGeneratedIdentifiersDoNotCreateUnsavedChanges() {
        let lhs = request()
        var rhs = lhs
        rhs.id = UUID()
        rhs.headers[0].id = UUID()
        rhs.queryItems[0].id = UUID()
        rhs.pathVariables[0].id = UUID()
        rhs.cookies[0].id = UUID()
        rhs.localVariables[0].id = UUID()
        rhs.body.parameters[0].id = UUID()
        rhs.scripts[0].id = UUID()
        XCTAssertTrue(coordinator.requestsEquivalentForPersistence(lhs, rhs))
    }

    func testExecutionAndEditorValuesRemainPartOfThePersistenceComparison() {
        let original = request()
        let edits: [(String, (inout APIRequestModel) -> Void)] = [
            ("name", { $0.name = "Changed" }),
            ("method", { $0.method = .put }),
            ("url", { $0.url += "/changed" }),
            ("transport", { $0.transportKind = .webSocket }),
            ("target", { $0.httpRequestTargetKind = .invokeLambda }),
            ("headers", { $0.headers[0].value = "changed" }),
            ("enabled", { $0.headers[0].isEnabled = false }),
            ("query", { $0.queryItems[0].value = "changed" }),
            ("path", { $0.pathVariables[0].value = "changed" }),
            ("cookies", { $0.cookies[0].value = "changed" }),
            ("local", { $0.localVariables[0].value = "changed" }),
            ("body", { $0.body.raw = "changed" }),
            ("body kind", { $0.body.kind = .json }),
            ("body parameters", { $0.body.parameters[0].value = "changed" }),
            ("script", { $0.scripts[0].source = "changed" }),
            ("script language", { $0.scripts[0].language = "mini" }),
            ("script event", { $0.scripts[0].listen = .test }),
            ("auth", { $0.auth.token = "changed" }),
            ("timeout", { $0.timeoutSeconds += 1 }),
            ("retry", { $0.retryOn206Count += 1 }),
            ("retry delay", { $0.retryOn206DelayMilliseconds += 1 }),
            ("TLS validation", { $0.tlsValidationMode = .insecure }),
            ("TLS version", { $0.minimumTLSVersion = .tls12 }),
            ("subprotocol", { $0.webSocketSubprotocols = "changed" }),
            ("open timeout", { $0.webSocketOpenTimeoutSeconds += 1 }),
            ("reconnect count", { $0.webSocketReconnectAttempts += 1 }),
            ("reconnect interval", { $0.webSocketReconnectIntervalMilliseconds += 1 }),
            ("message size", { $0.webSocketMaximumMessageSizeMB += 1 }),
            ("ping", { $0.webSocketPingIntervalSeconds += 1 }),
            ("keepalive", { $0.webSocketKeepAliveMessage = "changed" }),
            ("keepalive interval", { $0.webSocketKeepAliveIntervalSeconds += 1 }),
            ("AWS portal", { $0.awsAccessPortalURLTemplate = "https://example.invalid/changed" }),
        ]
        for (name, edit) in edits {
            var changed = original
            edit(&changed)
            XCTAssertFalse(coordinator.requestsEquivalentForPersistence(original, changed), name)
        }
    }

    func testReorderedEntriesRemainAnEdit() {
        var original = request()
        original.headers.append(KeyValueEntry(key: "Second", value: "two"))
        var reordered = original
        reordered.headers.reverse()
        XCTAssertFalse(coordinator.requestsEquivalentForPersistence(original, reordered))
    }

    private func request() -> APIRequestModel {
        let entry = KeyValueEntry(key: "key", value: "value")
        return APIRequestModel(name: "Request", method: .post, url: "https://example.invalid/request",
            queryItems: [entry], pathVariables: [entry], headers: [entry], cookies: [entry],
            auth: AuthConfiguration(type: .bearer, token: "fixture-token"),
            body: RequestBodyModel(kind: .raw, raw: "body", parameters: [entry]),
            scripts: [ScriptDefinition(name: "Prepare", listen: .preRequest, language: "javascript", source: "console.log('fixture');")],
            localVariables: [entry])
    }
}
