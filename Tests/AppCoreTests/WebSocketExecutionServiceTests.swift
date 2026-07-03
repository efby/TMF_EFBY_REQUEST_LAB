import EfbyPresentation
import Foundation
import XCTest

final class WebSocketExecutionServiceTests: XCTestCase {
    func testPrepareConnectionBuildsHandshakeAndAppliesPreRequestScripts() throws {
        let service = WebSocketExecutionService()
        let request = APIRequestModel(
            name: "Socket",
            transportKind: .webSocket,
            url: "wss://{{host}}/stream/:roomId",
            queryItems: [KeyValueEntry(key: "tenant", value: "{{tenant}}")],
            pathVariables: [KeyValueEntry(key: "roomId", value: "{{roomId}}")],
            headers: [KeyValueEntry(key: "X-Trace", value: "{{traceId}}")],
            cookies: [KeyValueEntry(key: "session", value: "{{sessionId}}")],
            auth: AuthConfiguration(type: .bearer, token: "{{token}}"),
            body: RequestBodyModel(kind: .raw, raw: #"{"type":"ping","room":"{{roomId}}"}"#),
            scripts: [
                ScriptDefinition(
                    name: "Prepare room",
                    listen: .preRequest,
                    language: "mini",
                    source: "set local.roomId=alpha"
                ),
            ],
            webSocketSubprotocols: "json, chat.v2"
        )

        let prepared = try service.prepareConnection(
            request: request,
            globals: [
                VariableValue(key: "host", value: "socket.example.com"),
                VariableValue(key: "tenant", value: "efby"),
                VariableValue(key: "traceId", value: "trace-123"),
                VariableValue(key: "sessionId", value: "abc123"),
                VariableValue(key: "token", value: "secret-token"),
            ],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(prepared.urlRequest.httpMethod, "GET")
        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "wss://socket.example.com/stream/alpha?tenant=efby")
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "X-Trace"), "trace-123")
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Cookie"), "session=abc123")
        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "json, chat.v2")
        XCTAssertEqual(prepared.updatedLocal.first(where: { $0.key == "roomId" })?.value, "alpha")
        XCTAssertTrue(prepared.rawRequest.contains("GET /stream/alpha?tenant=efby HTTP/1.1"))
    }

    func testPrepareConnectionReflectsMutatedHeadersAndQueryParams() throws {
        let service = WebSocketExecutionService()
        let request = APIRequestModel(
            name: "Socket",
            transportKind: .webSocket,
            url: "wss://socket.example.com/ws",
            queryItems: [KeyValueEntry(key: "legacy", value: "1")],
            headers: [KeyValueEntry(key: "X-Old", value: "old")],
            scripts: [
                ScriptDefinition(
                    name: "Mutate request",
                    listen: .preRequest,
                    language: "javascript",
                    source: """
                    pm.request.param.set("tenant", "efby");
                    pm.request.param.remove("legacy");
                    pm.request.headers.set("X-Trace", "trace-123");
                    pm.request.headers.remove("X-Old");
                    """
                ),
            ]
        )

        let prepared = try service.prepareConnection(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "wss://socket.example.com/ws?tenant=efby")
        XCTAssertEqual(prepared.updatedRequestQueryItems?.count, 1)
        XCTAssertEqual(prepared.updatedRequestQueryItems?.first?.key, "tenant")
        XCTAssertEqual(prepared.updatedRequestQueryItems?.first?.value, "efby")
        XCTAssertEqual(prepared.updatedRequestHeaders?.count, 1)
        XCTAssertEqual(prepared.updatedRequestHeaders?.first?.key, "X-Trace")
        XCTAssertEqual(prepared.updatedRequestHeaders?.first?.value, "trace-123")
    }

    func testResolveOutgoingMessageUsesResolvedVariables() {
        let service = WebSocketExecutionService()
        let request = APIRequestModel(
            name: "Socket",
            transportKind: .webSocket,
            url: "wss://socket.example.com",
            body: RequestBodyModel(kind: .raw, raw: #"{"event":"join","room":"{{roomId}}","token":"{{token}}"}"#),
            localVariables: [KeyValueEntry(key: "roomId", value: "alpha")]
        )

        let message = service.resolveOutgoingMessage(
            from: request,
            globals: [VariableValue(key: "token", value: "secret-token")],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(message, #"{"event":"join","room":"alpha","token":"secret-token"}"#)
    }

    func testResolveSupportsKeepAliveTemplates() {
        let service = WebSocketExecutionService()

        let message = service.resolve(
            #"{"kind":"keepalive","tenant":"{{tenant}}","room":"{{roomId}}"}"#,
            globals: [VariableValue(key: "tenant", value: "efby")],
            collectionVariables: [],
            environmentVariables: [],
            localVariables: [KeyValueEntry(key: "roomId", value: "alpha")]
        )

        XCTAssertEqual(message, #"{"kind":"keepalive","tenant":"efby","room":"alpha"}"#)
    }

    func testExecutesPmWebSocketOnMessageScripts() {
        let service = WebSocketExecutionService()
        let request = APIRequestModel(
            name: "Socket",
            transportKind: .webSocket,
            url: "wss://socket.example.com",
            scripts: [
                ScriptDefinition(
                    name: "incoming",
                    listen: .test,
                    language: "javascript",
                    source: """
                    pm.websocket.onMessage(function(message) {
                      const json = JSON.parse(message);
                      if (json.tipoTransaccion === "keepAlive") {
                        console.log("CAPTURANDO LOS MENSAJES");
                        console.log(json);
                        pm.environment.set("lastSocketEvent", json.tipoTransaccion);
                      }
                    });
                    """
                ),
            ]
        )

        let outcome = service.executeIncomingMessageScripts(
            message: #"{"tipoTransaccion":"keepAlive"}"#,
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertTrue(outcome.logs.contains("CAPTURANDO LOS MENSAJES"))
        XCTAssertTrue(outcome.logs.contains(#"{"tipoTransaccion":"keepAlive"}"#))
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "lastSocketEvent" })?.value, "keepAlive")
    }

    func testExecutesPmWebSocketOnDoneScripts() {
        let service = WebSocketExecutionService()
        let request = APIRequestModel(
            name: "Socket",
            transportKind: .webSocket,
            url: "wss://socket.example.com",
            scripts: [
                ScriptDefinition(
                    name: "done",
                    listen: .test,
                    language: "javascript",
                    source: """
                    pm.websocket.onDone(function(causa) {
                      console.log("SOCKET DONE:", causa);
                      pm.environment.set("socketDoneCause", causa);
                    });
                    """
                ),
            ]
        )

        let outcome = service.executeDoneScripts(
            cause: "Disconnected.",
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertTrue(outcome.logs.contains("SOCKET DONE: Disconnected."))
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "socketDoneCause" })?.value, "Disconnected.")
    }

    func testExecutesPmWebSocketDisconnectRequestFromIncomingScript() {
        let service = WebSocketExecutionService()
        let request = APIRequestModel(
            name: "Socket",
            transportKind: .webSocket,
            url: "wss://socket.example.com",
            scripts: [
                ScriptDefinition(
                    name: "incoming",
                    listen: .test,
                    language: "javascript",
                    source: """
                    pm.websocket.onMessage(function(message) {
                      const json = JSON.parse(message);
                      if (json.tipoTransaccion === "cerrar") {
                        pm.environment.set("disconnectReason", "script");
                        pm.websocket.disconnect();
                      }
                    });
                    """
                ),
            ]
        )

        let outcome = service.executeIncomingMessageScripts(
            message: #"{"tipoTransaccion":"cerrar"}"#,
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertTrue(outcome.shouldDisconnect)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "disconnectReason" })?.value, "script")
    }
}
