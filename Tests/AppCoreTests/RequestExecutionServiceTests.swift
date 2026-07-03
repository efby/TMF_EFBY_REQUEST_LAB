import EfbyPresentation
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import XCTest

final class RequestExecutionServiceTests: XCTestCase {
    override class func tearDown() {
        MockURLProtocol.handler = nil
    }

    func testExecutesRequestResolvesVariablesAndRunsScripts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/users/42")
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Resolve Variables",
            method: .get,
            url: "{{baseUrl}}/users/{{userId}}",
            scripts: [
                ScriptDefinition(
                    name: "Prepare",
                    listen: .preRequest,
                    language: "mini",
                    source: "set local.userId=42"
                ),
                ScriptDefinition(
                    name: "Check",
                    listen: .test,
                    language: "mini",
                    source: """
                    assert.status == 200
                    assert.json $.ok == true
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [VariableValue(key: "baseUrl", value: "https://api.example.com")],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("PASS status == 200") }))
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("PASS json $.ok == true") }))
        XCTAssertEqual(outcome.updatedLocal.first(where: { $0.key == "userId" })?.value, "42")
    }

    func testPreRequestJavaScriptUpdatesEnvironmentBeforeBodyResolution() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/transactions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(requestBodyString(from: request), #"{"transaccionId":"1000001","transaccionCodigo":"502"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Confirmar transaccion",
            method: .post,
            url: "https://api.example.com/transactions",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"transaccionId":"{{transactionId}}","transaccionCodigo":"{{transactionCode}}"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare Transaction",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var transactionId = pm.environment.get("transactionId");
                    var transactionCode = pm.environment.get("transactionCode");
                    transactionId = String(Number(transactionId) + 1);
                    transactionCode = String(Number(transactionCode) + 2);
                    pm.environment.set("transactionId", transactionId);
                    pm.environment.set("transactionCode", transactionCode);
                    """
                ),
                ScriptDefinition(
                    name: "Status 200",
                    listen: .test,
                    language: "text/javascript",
                    source: """
                    pm.test("status is 200", function () {
                        pm.response.to.have.status(200);
                    });
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "transactionId", value: "1000000"),
                VariableValue(key: "transactionCode", value: "500"),
            ]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "transactionId" })?.value, "1000001")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "transactionCode" })?.value, "502")
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("PASS status is 200") }))
    }

    func testPostmanCompatibilityReadsWritesEnvironmentAndValidatesResponseStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(requestBodyString(from: request), #"{"transaccionId":"234234234"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Environment compatibility",
            method: .post,
            url: "https://api.example.com/transactions",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"transaccionId":"{{transactionId}}"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare Transaction",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var trxId = pm.environment.get("transactionId");
                    var sTrxId = "234234234";
                    pm.environment.set("transactionId", sTrxId);
                    """
                ),
                ScriptDefinition(
                    name: "Status 200",
                    listen: .test,
                    language: "text/javascript",
                    source: """
                    pm.response.to.have.status(200);
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "transactionId", value: "1000000"),
            ]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "transactionId" })?.value, "234234234")
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("PASS pm.response status 200") }))
    }

    func testWorkspaceUtilityLibrariesCanBeCalledFromPreRequestScripts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "ws-demo-trace")
            XCTAssertEqual(requestBodyString(from: request), #"{"trace":"ws-demo-trace"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let utility = WorkspaceScriptUtility(
            name: "Shared Helpers",
            language: "javascript",
            source: """
            function buildWorkspaceTrace(prefix) {
                return prefix + "-trace";
            }
            """
        )

        let request = APIRequestModel(
            name: "Workspace utility request",
            method: .post,
            url: "https://api.example.com/utilities",
            headers: [
                KeyValueEntry(key: "X-Trace", value: "{{traceId}}"),
            ],
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"trace":"{{traceId}}"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare Trace",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.environment.set("traceId", buildWorkspaceTrace("ws-demo"));
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [],
            utilityLibraries: [utility]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "traceId" })?.value, "ws-demo-trace")
    }

    func testPreRequestRunsBeforeResolvingURLHeadersQueryAndBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example.com/orders?mode=sync&trace=trace-001"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tenant"), "tenant-qa")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "trace-001")
            XCTAssertEqual(
                requestBodyString(from: request),
                #"{"resource":"orders","tenant":"tenant-qa","trace":"trace-001"}"#
            )

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let utility = WorkspaceScriptUtility(
            name: "Flow Helpers",
            language: "javascript",
            source: """
            function buildTraceId(prefix) {
                return prefix + "-001";
            }
            """
        )

        let request = APIRequestModel(
            name: "Pre-request ordering",
            method: .post,
            url: "https://{{host}}/{{resource}}",
            queryItems: [
                KeyValueEntry(key: "mode", value: "{{mode}}"),
                KeyValueEntry(key: "trace", value: "{{traceId}}"),
            ],
            headers: [
                KeyValueEntry(key: "X-Tenant", value: "{{tenant}}"),
                KeyValueEntry(key: "X-Trace", value: "{{traceId}}"),
            ],
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"resource":"{{resource}}","tenant":"{{tenant}}","trace":"{{traceId}}"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare request values",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.environment.set("host", "api.example.com");
                    pm.environment.set("resource", "orders");
                    pm.environment.set("tenant", "tenant-qa");
                    pm.environment.set("mode", "sync");
                    pm.environment.set("traceId", buildTraceId("trace"));
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "host", value: "stale.example.com"),
                VariableValue(key: "resource", value: "pending"),
                VariableValue(key: "tenant", value: "tenant-dev"),
                VariableValue(key: "mode", value: "async"),
                VariableValue(key: "traceId", value: "trace-old"),
            ],
            utilityLibraries: [utility]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "host" })?.value, "api.example.com")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "resource" })?.value, "orders")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "tenant" })?.value, "tenant-qa")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "mode" })?.value, "sync")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "traceId" })?.value, "trace-001")
    }

    func testWorkspaceUtilityLibrariesCanBeCalledInsideBodyTemplateExpressions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                requestBodyString(from: request),
                #"{"json_ejemplo": {"pinpadId":"pinpad-77","requestId":"req-pinpad-77","requestFecha":1234567890}}"#
            )

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let utility = WorkspaceScriptUtility(
            name: "GenerarBodyAsignacion",
            language: "javascript",
            source: """
            const GenerarBodyAsignacion = {
                generarBody: function(pinpadId) {
                    return {
                        pinpadId: pinpadId,
                        requestId: "req-" + pinpadId,
                        requestFecha: 1234567890
                    };
                }
            };
            """
        )

        let request = APIRequestModel(
            name: "Body template expression",
            method: .post,
            url: "https://api.example.com/body-template",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"json_ejemplo": {{utils.GenerarBodyAsignacion.generarBody(pm.environment.get("pinpadId"))}}}"#
            )
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "pinpadId", value: "pinpad-77"),
            ],
            utilityLibraries: [utility]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testJavaScriptCanCreateAndActivateEnvironmentDuringRequestExecution() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://qa.example.com/health")

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let prodEnvironment = EnvironmentProfile(
            name: "Prod",
            variables: [
                VariableValue(key: "baseUrl", value: "https://prod.example.com"),
            ]
        )

        let request = APIRequestModel(
            name: "Switch Environment",
            method: .get,
            url: "{{baseUrl}}/health",
            scripts: [
                ScriptDefinition(
                    name: "Switch to QA",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.createenvironment("QA");
                    pm.environment.set("baseUrl", "https://qa.example.com");
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: prodEnvironment.variables,
            workspaceEnvironments: [prodEnvironment],
            activeEnvironmentID: prodEnvironment.id
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "baseUrl" })?.value, "https://qa.example.com")
        XCTAssertEqual(outcome.updatedEnvironments.count, 2)
        XCTAssertEqual(
            outcome.updatedEnvironments.first(where: { $0.id == outcome.activeEnvironmentID })?.name,
            "QA"
        )
        XCTAssertEqual(
            outcome.updatedEnvironments
                .first(where: { $0.id == outcome.activeEnvironmentID })?
                .variables
                .first(where: { $0.key == "baseUrl" })?
                .value,
            "https://qa.example.com"
        )
    }

    func testPreRequestScriptsCanMutateRequestHeadersDirectly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dynamic-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "trace-123")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Remove"))

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Header mutations",
            method: .get,
            url: "https://api.example.com/headers",
            headers: [
                KeyValueEntry(key: "Authorization", value: "Bearer stale-token"),
                KeyValueEntry(key: "X-Remove", value: "remove-me"),
            ],
            scripts: [
                ScriptDefinition(
                    name: "Mutate headers",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.request.headers.set("Authorization", "Bearer dynamic-token");
                    pm.request.headers.add("X-Trace", "trace-123");
                    pm.request.headers.remove("X-Remove");
                    pm.environment.set("authHeaderSeen", pm.request.headers.get("Authorization"));
                    pm.environment.set("traceHeaderSeen", String(pm.request.headers.has("X-Trace")));
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedRequestHeaders?.count, 2)
        XCTAssertEqual(
            outcome.updatedRequestHeaders?.first(where: { $0.key == "Authorization" })?.value,
            "Bearer dynamic-token"
        )
        XCTAssertEqual(
            outcome.updatedRequestHeaders?.first(where: { $0.key == "X-Trace" })?.value,
            "trace-123"
        )
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "authHeaderSeen" })?.value, "Bearer dynamic-token")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "traceHeaderSeen" })?.value, "true")
    }

    func testPreRequestScriptsCanMutateRequestBodyDirectly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let body = try XCTUnwrap(requestBodyString(from: request))
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["trace"] as? String, "trace-123")
            XCTAssertEqual(object["count"] as? Int, 2)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Body mutations",
            method: .post,
            url: "https://api.example.com/body",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"trace":"stale"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Mutate body",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.request.body.set({ trace: "trace-123", count: 2 });
                    pm.environment.set("bodyKindSeen", pm.request.body.get().kind);
                    pm.environment.set("bodyRawSeen", pm.request.body.get().raw);
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "bodyKindSeen" })?.value, "json")
        XCTAssertEqual(outcome.updatedRequestBody?.kind, .json)
        let updatedBody = try XCTUnwrap(outcome.updatedRequestBody?.raw)
        let updatedBodyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(updatedBody.utf8)) as? [String: Any]
        )
        XCTAssertEqual(updatedBodyObject["trace"] as? String, "trace-123")
        XCTAssertEqual(updatedBodyObject["count"] as? Int, 2)
        let rawBodySeen = try XCTUnwrap(outcome.updatedEnvironment.first(where: { $0.key == "bodyRawSeen" })?.value)
        let rawBodyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rawBodySeen.utf8)) as? [String: Any]
        )
        XCTAssertEqual(rawBodyObject["trace"] as? String, "trace-123")
        XCTAssertEqual(rawBodyObject["count"] as? Int, 2)
    }

    func testInvokeLambdaSignsRequestWithAWSV4ForFunctionARN() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        let lambdaARN = "arn:aws:lambda:us-east-1:078437331515:function:puntoventa_ajusta_transaccion_post"
        let credentialsBlock = """
        [078437331515_AdministratorAccess]
        aws_access_key_id=ASIATESTACCESSKEY
        aws_secret_access_key=testSecretKeyForSigV4Only1234567890
        aws_session_token=testSessionTokenForLambdaInvoke
        """
        let expectedURL = "https://lambda.us-east-1.amazonaws.com/2015-03-31/functions/arn%3Aaws%3Alambda%3Aus-east-1%3A078437331515%3Afunction%3Apuntoventa_ajusta_transaccion_post/invocations"
        let expectedBody = #"{"transaccionId":"9234567390123156780012245678901234569185","transaccionCodigo":"923456783012145678901234569978","montoAjuste":1000}"#

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, expectedURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(requestBodyString(from: request), expectedBody)

            let securityToken = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Amz-Security-Token"))
            XCTAssertEqual(securityToken, "testSessionTokenForLambdaInvoke")

            let amzDate = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Amz-Date"))
            let payloadHash = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Amz-Content-Sha256"))
            XCTAssertEqual(payloadHash, sha256Hex(of: expectedBody))

            let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(
                authorization,
                expectedLambdaAuthorizationHeader(
                    accessKeyID: "ASIATESTACCESSKEY",
                    secretAccessKey: "testSecretKeyForSigV4Only1234567890",
                    sessionToken: "testSessionTokenForLambdaInvoke",
                    url: try XCTUnwrap(request.url),
                    amzDate: amzDate,
                    httpMethod: "POST",
                    payloadHash: payloadHash,
                    contentType: "application/json"
                )
            )

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Invoke Lambda",
            transportKind: .http,
            httpRequestTargetKind: .invokeLambda,
            method: .post,
            url: lambdaARN,
            auth: AuthConfiguration(
                type: .awsTemporaryCredentials,
                token: credentialsBlock
            ),
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"transaccionId":"{{transactionId}}","transaccionCodigo":"{{transactionCode}}","montoAjuste":1000}"#
            )
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "transactionId", value: "9234567390123156780012245678901234569185"),
                VariableValue(key: "transactionCode", value: "923456783012145678901234569978"),
            ]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("Invoking AWS Lambda \(lambdaARN).") }))
    }

    func testInvokeLambdaSignsRequestWithShellExportCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        let lambdaARN = "arn:aws:lambda:us-east-1:078437331515:function:puntoventa_ajusta_transaccion_post"
        let credentialsBlock = #"""
        export AWS_ACCESS_KEY_ID="ASIATESTACCESSKEY"
        export AWS_SECRET_ACCESS_KEY="testSecretKeyForSigV4Only1234567890"
        export AWS_SESSION_TOKEN="testSessionTokenForLambdaInvoke"
        """#
        let expectedURL = "https://lambda.us-east-1.amazonaws.com/2015-03-31/functions/arn%3Aaws%3Alambda%3Aus-east-1%3A078437331515%3Afunction%3Apuntoventa_ajusta_transaccion_post/invocations"
        let expectedBody = #"{"transaccionId":"9234567390123156780012245678901234569185","transaccionCodigo":"923456783012145678901234569978","montoAjuste":1000}"#

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, expectedURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(requestBodyString(from: request), expectedBody)

            let securityToken = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Amz-Security-Token"))
            XCTAssertEqual(securityToken, "testSessionTokenForLambdaInvoke")

            let amzDate = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Amz-Date"))
            let payloadHash = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Amz-Content-Sha256"))
            XCTAssertEqual(payloadHash, sha256Hex(of: expectedBody))

            let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(
                authorization,
                expectedLambdaAuthorizationHeader(
                    accessKeyID: "ASIATESTACCESSKEY",
                    secretAccessKey: "testSecretKeyForSigV4Only1234567890",
                    sessionToken: "testSessionTokenForLambdaInvoke",
                    url: try XCTUnwrap(request.url),
                    amzDate: amzDate,
                    httpMethod: "POST",
                    payloadHash: payloadHash,
                    contentType: "application/json"
                )
            )

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Invoke Lambda",
            transportKind: .http,
            httpRequestTargetKind: .invokeLambda,
            method: .post,
            url: lambdaARN,
            auth: AuthConfiguration(
                type: .awsTemporaryCredentials,
                token: credentialsBlock
            ),
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"transaccionId":"{{transactionId}}","transaccionCodigo":"{{transactionCode}}","montoAjuste":1000}"#
            )
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "transactionId", value: "9234567390123156780012245678901234569185"),
                VariableValue(key: "transactionCode", value: "923456783012145678901234569978"),
            ]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testInvokeLambdaDryRunAgainstAWSWhenCredentialsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let lambdaARN = environment["EFBY_LAMBDA_INVOKE_ARN"], !lambdaARN.isEmpty,
              let accessKeyID = environment["EFBY_AWS_ACCESS_KEY_ID"], !accessKeyID.isEmpty,
              let secretAccessKey = environment["EFBY_AWS_SECRET_ACCESS_KEY"], !secretAccessKey.isEmpty,
              let sessionToken = environment["EFBY_AWS_SESSION_TOKEN"], !sessionToken.isEmpty else {
            throw XCTSkip("Live AWS Lambda credentials were not provided.")
        }

        let credentialsBlock = """
        [integration]
        aws_access_key_id=\(accessKeyID)
        aws_secret_access_key=\(secretAccessKey)
        aws_session_token=\(sessionToken)
        """

        let service = RequestExecutionService()
        let request = APIRequestModel(
            name: "Lambda DryRun",
            transportKind: .http,
            httpRequestTargetKind: .invokeLambda,
            method: .post,
            url: lambdaARN,
            headers: [
                KeyValueEntry(key: "X-Amz-Invocation-Type", value: "DryRun"),
            ],
            auth: AuthConfiguration(
                type: .awsTemporaryCredentials,
                token: credentialsBlock
            ),
            body: RequestBodyModel(kind: .none)
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 204)
    }

    func testPreRequestScriptsCanMutateRequestQueryParamsDirectly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let items = components.queryItems ?? []
            XCTAssertEqual(items.first(where: { $0.name == "pinpadtoken" })?.value, "pin-123")
            XCTAssertEqual(items.first(where: { $0.name == "requestid" })?.value, "req-001")
            XCTAssertEqual(items.first(where: { $0.name == "connectionqr" })?.value, "qr-001")
            XCTAssertNil(items.first(where: { $0.name == "legacy" }))

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Param mutations",
            method: .get,
            url: "wss://api.example.com/socket",
            queryItems: [
                KeyValueEntry(key: "legacy", value: "1"),
            ],
            scripts: [
                ScriptDefinition(
                    name: "Mutate params",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.request.param.set("pinpadtoken", "pin-123");
                    pm.request.param.set("requestid", "req-001");
                    pm.request.param.add("connectionqr", "qr-001");
                    pm.request.param.remove("legacy");
                    pm.environment.set("paramSeen", pm.request.param.get("pinpadtoken"));
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "paramSeen" })?.value, "pin-123")
        XCTAssertEqual(outcome.updatedRequestQueryItems?.count, 3)
        XCTAssertEqual(
            outcome.updatedRequestQueryItems?.first(where: { $0.key == "pinpadtoken" })?.value,
            "pin-123"
        )
        XCTAssertEqual(
            outcome.updatedRequestQueryItems?.first(where: { $0.key == "requestid" })?.value,
            "req-001"
        )
        XCTAssertEqual(
            outcome.updatedRequestQueryItems?.first(where: { $0.key == "connectionqr" })?.value,
            "qr-001"
        )
    }

    func testRequestHeaderAddAndSetUpsertExistingAndMissingValues() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer second")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-New"), "created-by-set")

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Header upsert semantics",
            method: .get,
            url: "https://api.example.com/headers-upsert",
            headers: [
                KeyValueEntry(key: "Authorization", value: "Bearer first"),
            ],
            scripts: [
                ScriptDefinition(
                    name: "Upsert headers",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.request.headers.add("Authorization", "Bearer second");
                    pm.request.headers.set("X-New", "created-by-set");
                    pm.environment.set("authorizationSeen", pm.request.headers.get("Authorization"));
                    pm.environment.set("newHeaderSeen", pm.request.headers.get("X-New"));
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "authorizationSeen" })?.value, "Bearer second")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "newHeaderSeen" })?.value, "created-by-set")
    }

    func testCreateEnvironmentDoesNothingWhenEnvironmentAlreadyExists() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://prod.example.com/health")

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let prodEnvironment = EnvironmentProfile(
            name: "Prod",
            variables: [
                VariableValue(key: "baseUrl", value: "https://prod.example.com"),
            ]
        )

        let qaEnvironment = EnvironmentProfile(
            name: "QA",
            variables: [
                VariableValue(key: "baseUrl", value: "https://qa.example.com"),
            ]
        )

        let request = APIRequestModel(
            name: "Existing Environment",
            method: .get,
            url: "{{baseUrl}}/health",
            scripts: [
                ScriptDefinition(
                    name: "Do Not Switch",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.createEnvironment("QA");
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: prodEnvironment.variables,
            workspaceEnvironments: [prodEnvironment, qaEnvironment],
            activeEnvironmentID: prodEnvironment.id
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironments.count, 2)
        XCTAssertEqual(outcome.activeEnvironmentID, prodEnvironment.id)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "baseUrl" })?.value, "https://prod.example.com")
        XCTAssertEqual(
            outcome.updatedEnvironments
                .first(where: { $0.id == qaEnvironment.id })?
                .variables
                .first(where: { $0.key == "baseUrl" })?
                .value,
            "https://qa.example.com"
        )
    }

    func testBodyTemplateExpressionsCanPersistEnvironmentChangesFromUtilities() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                requestBodyString(from: request),
                #"{"json_ejemplo": {"pinpadId":"pinpad-77","requestId":"req-pinpad-77"}}"#
            )

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let utility = WorkspaceScriptUtility(
            name: "GenerarBodyAsignacion",
            language: "javascript",
            source: """
            const GenerarBodyAsignacion = {
                generarBody: function(pinpadId) {
                    const requestSecret = "secret-" + pinpadId;
                    pm.environment.set("requestSecret-asignacion", requestSecret);
                    return {
                        pinpadId: pinpadId,
                        requestId: "req-" + pinpadId
                    };
                }
            };
            """
        )

        let request = APIRequestModel(
            name: "Body template expression side effects",
            method: .post,
            url: "https://api.example.com/body-template-side-effects",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"json_ejemplo": {{utils.GenerarBodyAsignacion.generarBody(pm.environment.get("pinpadId"))}}}"#
            )
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "pinpadId", value: "pinpad-77"),
            ],
            utilityLibraries: [utility]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "requestSecret-asignacion" })?.value,
            "secret-pinpad-77"
        )
    }

    func testWorkspaceUtilitiesCanAccessOtherExportedConstantsThroughUtilsNamespace() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(requestBodyString(from: request), #"{"trace":"DEMO-token"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let tokenUtility = WorkspaceScriptUtility(
            name: "Token helpers",
            language: "javascript",
            source: """
            const TokenUtils = {
                generar: function(prefix) {
                    return prefix + "-token";
                }
            };
            """
        )
        let bodyUtility = WorkspaceScriptUtility(
            name: "Body helpers",
            language: "javascript",
            source: """
            const BodyUtils = {
                generarTrace: function(prefix) {
                    return utils.TokenUtils.generar(prefix).replace("demo", "DEMO");
                }
            };
            """
        )

        let request = APIRequestModel(
            name: "Utility chaining request",
            method: .post,
            url: "https://api.example.com/utility-chain",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"trace":"{{traceId}}"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare Trace",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.environment.set("traceId", utils.BodyUtils.generarTrace("demo"));
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [],
            utilityLibraries: [tokenUtility, bodyUtility]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "traceId" })?.value, "DEMO-token")
    }

    func testJavaScriptErrorsIncludeFunctionAndLineInformation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Broken script request",
            method: .get,
            url: "https://api.example.com/error-script",
            scripts: [
                ScriptDefinition(
                    name: "Broken Pre-request",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    function explodeTrace() {
                        throw new Error("boom");
                    }
                    explodeTrace();
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        let errorLog = try XCTUnwrap(outcome.logs.first(where: { $0.contains("JavaScript error in Broken Pre-request") }))
        XCTAssertTrue(errorLog.contains("explodeTrace"))
        XCTAssertTrue(errorLog.contains("line 2"))
    }

    func testPreRequestScriptsCanReadResolvedRequestURLAndOriginalTemplate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/pinpadapi_de_1/asignacion")

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Resolved request url",
            method: .get,
            url: "https://{{url_base}}/pinpadapi_de_1/asignacion",
            scripts: [
                ScriptDefinition(
                    name: "Read request url",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.environment.set("resolvedRequestUrl", pm.request.url);
                    pm.environment.set("requestUrlTemplate", pm.request.urlTemplate);
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "url_base", value: "api.example.com"),
            ]
        )

        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "resolvedRequestUrl" })?.value,
            "https://api.example.com/pinpadapi_de_1/asignacion"
        )
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "requestUrlTemplate" })?.value,
            "https://{{url_base}}/pinpadapi_de_1/asignacion"
        )
    }

    func testPostResponseCanUpdateEnvironmentInsideStatusGuard() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")

            let data = Data(#"{"statusCode":"200","userMessage":"NOK"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Post-response environment update",
            method: .post,
            url: "https://api.example.com/transactions",
            scripts: [
                ScriptDefinition(
                    name: "Update after 200",
                    listen: .test,
                    language: "text/javascript",
                    source: """
                    var trxId = pm.environment.get("transactionId");
                    var trxCode = pm.environment.get("transactionCode");
                    var trxIdPart1 = trxId.substring(0,35)
                    var trxIdPart2 = trxId.substring(35,40)
                    var trxCodePart1 = trxCode.substring(0,25)
                    var trxCodePart2 = trxCode.substring(25,30)
                    var nTrxId = Number(trxIdPart2);
                    var nTrxCode = Number(trxCodePart2);
                    nTrxId++;
                    nTrxCode++;
                    var sTrxId = trxIdPart1 + String(nTrxId);
                    var sTrxCode = trxCodePart1 + String(nTrxCode);

                    if (pm.response.to.have.status(200)){
                        pm.environment.set("transactionId", sTrxId);
                        pm.environment.set("transactionCode", sTrxCode);
                    }
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "transactionId", value: "1234567890123456789012345678901234500000"),
                VariableValue(key: "transactionCode", value: "12345678901234567890123450000"),
            ]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "transactionId" })?.value,
            "123456789012345678901234567890123451"
        )
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "transactionCode" })?.value,
            "12345678901234567890123451"
        )
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("PASS pm.response status 200") }))
    }

    func testDuplicateEnvironmentKeysDoNotCrashAndLastValueWins() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(requestBodyString(from: request), #"{"transactionId":"second"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Duplicate env keys",
            method: .post,
            url: "https://api.example.com/transactions",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"transactionId":"{{transactionId}}"}"#
            )
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "transactionId", value: "first"),
                VariableValue(key: "transactionId", value: "second"),
            ]
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.rawRequest, """
        POST /transactions HTTP/1.1
        Host: api.example.com
        Content-Type: application/json

        {"transactionId":"second"}
        """)
    }

    func testPostmanAliasCanReadAndWriteEnvironmentVariables() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(requestBodyString(from: request), #"{"token":"abc-123"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Postman alias",
            method: .post,
            url: "https://api.example.com/login",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"token":"{{accessToken}}"}"#
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare token",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var token = postman.getEnvironmentVariable("accessToken");
                    if (!token) {
                        postman.setEnvironmentVariable("accessToken", "abc-123");
                    }
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "accessToken" })?.value, "abc-123")
        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testPostmanSetEnvironmentVariableSupportsExpressionsAndJSONStringifyRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "firma"), "signed-hex")
            XCTAssertEqual(requestBodyString(from: request), #"{"name":"demo"}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Postman setEnvironmentVariable",
            method: .post,
            url: "https://api.example.com/sign",
            headers: [
                KeyValueEntry(key: "firma", value: "{{firma}}"),
            ],
            body: RequestBodyModel(
                kind: .raw,
                raw: "{{bodyFirmado}}"
            ),
            scripts: [
                ScriptDefinition(
                    name: "Prepare signed payload",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var signatureHexa = "signed-hex";
                    postman.setEnvironmentVariable("firma", signatureHexa);
                    request = { name: "demo" };
                    postman.setEnvironmentVariable("bodyFirmado", JSON.stringify(request));
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "firma" })?.value, "signed-hex")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "bodyFirmado" })?.value, #"{"name":"demo"}"#)
        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testCryptoJSHmacSHA256CanPopulateEnvironmentVariables() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        let expectedBody = #"{"telefono":"56993437063","tipoMensaje":"sms"}"#
        let expectedSignature = hmacSHA256Hex(message: expectedBody, key: "secret-value")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "firma"), expectedSignature)
            XCTAssertEqual(requestBodyString(from: request), expectedBody)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "CryptoJS support",
            method: .post,
            url: "https://api.example.com/telefono",
            headers: [
                KeyValueEntry(key: "firma", value: "{{firma}}"),
            ],
            body: RequestBodyModel(
                kind: .raw,
                raw: "{{bodyFirmado}}"
            ),
            scripts: [
                ScriptDefinition(
                    name: "Sign payload",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var request = {"telefono":"56993437063", "tipoMensaje":"sms"}
                    var payloadBytes = CryptoJS.enc.Utf8.parse(JSON.stringify(request));
                    var signatureHexa = CryptoJS.HmacSHA256(payloadBytes, pm.environment.get("secret")).toString(CryptoJS.enc.Hex);
                    postman.setEnvironmentVariable("firma", signatureHexa)
                    postman.setEnvironmentVariable("bodyFirmado", JSON.stringify(request))
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "secret", value: "secret-value"),
            ]
        )

        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "firma" })?.value, expectedSignature)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "bodyFirmado" })?.value, expectedBody)
        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testEncryptRsaSupportsOAEP_SHA256WithPublicKeyPEM() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "RSA helper support",
            method: .post,
            url: "https://api.example.com/rsa",
            scripts: [
                ScriptDefinition(
                    name: "Encrypt value",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var encrypted = encryptRsa("secret-demo", pm.environment.get("rsaPublicKey"));
                    pm.environment.set("encryptedSecret", encrypted);
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [
                VariableValue(key: "rsaPublicKey", value: testRSAPublicKeyPEM),
            ]
        )

        let encryptedHex = try XCTUnwrap(
            outcome.updatedEnvironment.first(where: { $0.key == "encryptedSecret" })?.value
        )
        XCTAssertEqual(encryptedHex.count, 512)
        XCTAssertFalse(encryptedHex.isEmpty)
        XCTAssertTrue(encryptedHex.allSatisfy { $0.isHexDigit })
    }

    func testCryptoAESSupportsCBCDecryptEncryptAndECBEncrypt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let utility = WorkspaceScriptUtility(
            name: "Byte helpers",
            language: "javascript",
            source: """
            const Utf8 = {
                encode: function(text) {
                    text = String(text == null ? "" : text);
                    var utf8 = unescape(encodeURIComponent(text));
                    var bytes = [];
                    for (var i = 0; i < utf8.length; i += 1) {
                        bytes.push(utf8.charCodeAt(i));
                    }
                    return bytes;
                },
                decode: function(bytes) {
                    bytes = bytes || [];
                    var binary = "";
                    for (var i = 0; i < bytes.length; i += 1) {
                        binary += String.fromCharCode(bytes[i]);
                    }
                    return decodeURIComponent(escape(binary));
                }
            };

            const common = {
                hexToBytes: function(hex) {
                    hex = String(hex == null ? "" : hex).replace(/\\s+/g, "");
                    if (hex.length % 2 !== 0) {
                        throw new Error("Hex invalido");
                    }

                    var bytes = [];
                    for (var i = 0; i < hex.length; i += 2) {
                        bytes.push(parseInt(hex.substr(i, 2), 16));
                    }
                    return bytes;
                },
                bytesToHex: function(bytes) {
                    bytes = bytes || [];
                    var hex = "";
                    for (var i = 0; i < bytes.length; i += 1) {
                        hex += (bytes[i] & 255).toString(16).padStart(2, "0");
                    }
                    return hex;
                }
            };
            """
        )

        let request = APIRequestModel(
            name: "AES helper support",
            method: .get,
            url: "https://api.example.com/aes",
            scripts: [
                ScriptDefinition(
                    name: "AES operations",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var keyBytes = utils.Utf8.encode("01234567890123456789012345678901");
                    var plainText = "1234567890abcdef1234567890abcdef";
                    var plainBytes = utils.Utf8.encode(plainText);
                    var decryptedBytes = pm.crypto.aes.decryptCBCNoPaddingFromHex(
                        keyBytes,
                        "abcdefghijklmnop",
                        "f8adb0bcc18f45244c72bc916ad4c50722a4992017a33a7a1f5a4bb29e09a126"
                    );
                    pm.environment.set("aesDecrypted", utils.Utf8.decode(decryptedBytes));
                    pm.environment.set(
                        "aesEncrypted",
                        pm.crypto.aes.encryptCBCNoPaddingToHex(keyBytes, "abcdefghijklmnop", plainBytes)
                    );
                    var ecbBytes = pm.crypto.aes.encryptECBNoPadding(
                        keyBytes,
                        utils.Utf8.encode("1234567890abcdef")
                    );
                    pm.environment.set("aesECB", utils.common.bytesToHex(ecbBytes));
                    var ecbDecryptedBytes = pm.crypto.aes.decryptECBNoPadding(
                        keyBytes,
                        utils.common.hexToBytes("ec1d23732f03589cf3ce85bc6392d79f")
                    );
                    pm.environment.set("aesECBDecrypted", utils.Utf8.decode(ecbDecryptedBytes));
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [],
            utilityLibraries: [utility]
        )

        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "aesDecrypted" })?.value,
            "1234567890abcdef1234567890abcdef"
        )
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "aesEncrypted" })?.value,
            "f8adb0bcc18f45244c72bc916ad4c50722a4992017a33a7a1f5a4bb29e09a126"
        )
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "aesECB" })?.value,
            "ec1d23732f03589cf3ce85bc6392d79f"
        )
        XCTAssertEqual(
            outcome.updatedEnvironment.first(where: { $0.key == "aesECBDecrypted" })?.value,
            "1234567890abcdef"
        )
        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testTemplateExpressionAESBridgeToleratesUndefinedArguments() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(requestBodyString(from: request), #"{"cipher":""}"#)

            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "AES undefined bridge",
            method: .post,
            url: "https://api.example.com/aes",
            body: RequestBodyModel(
                kind: .json,
                raw: #"{"cipher":"{{pm.crypto.aes.encryptCBCNoPaddingToHex(undefined, 'abcdefghijklmnop', undefined)}}"}"#
            )
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testBase64BrowserHelpersSupportBtoaAndAtob() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Base64 helper support",
            method: .get,
            url: "https://api.example.com/base64",
            scripts: [
                ScriptDefinition(
                    name: "Encode and decode base64",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    pm.environment.set("base64Value", btoa("ABC"));
                    pm.environment.set("decodedValue", atob("QUJD"));
                    """
                )
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "base64Value" })?.value, "QUJD")
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "decodedValue" })?.value, "ABC")
        XCTAssertEqual(outcome.response.statusCode, 200)
    }

    func testRetriesWhenResponseStatusIs206() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)
        let attemptCounter = AttemptCounter()

        MockURLProtocol.handler = { request in
            let currentAttempt = attemptCounter.incrementAndGet()

            let statusCode = currentAttempt < 3 ? 206 : 200
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Retry on 206",
            method: .get,
            url: "https://api.example.com/retry",
            retryOn206Count: 5
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(attemptCounter.value, 3)
        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("HTTP 206 received on attempt 1 of 6. Retrying...") }))
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("HTTP 206 received on attempt 2 of 6. Retrying...") }))
    }

    func test206RetryRunsPreRequestBeforeEachRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)
        let attemptCounter = AttemptCounter()

        MockURLProtocol.handler = { request in
            let currentAttempt = attemptCounter.incrementAndGet()
            let statusCode = currentAttempt < 3 ? 206 : 200
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "Pre-request on 206 retry",
            method: .get,
            url: "https://api.example.com/retry-pre",
            scripts: [
                ScriptDefinition(
                    name: "Count pre-runs",
                    listen: .preRequest,
                    language: "text/javascript",
                    source: """
                    var n = parseInt(pm.environment.get("preRunCount") || "0", 10);
                    if (isNaN(n)) { n = 0; }
                    pm.environment.set("preRunCount", String(n + 1));
                    """
                )
            ],
            retryOn206Count: 5
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: [VariableValue(key: "preRunCount", value: "0", isEnabled: true)]
        )

        XCTAssertEqual(attemptCounter.value, 3)
        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertEqual(outcome.updatedEnvironment.first(where: { $0.key == "preRunCount" })?.value, "3")
    }

    func test206RetryWaitsConfiguredDelayMilliseconds() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)
        let attemptCounter = AttemptCounter()

        MockURLProtocol.handler = { request in
            let currentAttempt = attemptCounter.incrementAndGet()
            let statusCode = currentAttempt < 2 ? 206 : 200
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "206 delay",
            method: .get,
            url: "https://api.example.com/retry-delay",
            retryOn206Count: 5,
            retryOn206DelayMilliseconds: 120
        )

        let started = Date()
        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )
        let elapsedMs = Date().timeIntervalSince(started) * 1_000

        XCTAssertEqual(outcome.response.statusCode, 200)
        XCTAssertTrue(outcome.logs.contains(where: { $0.contains("Waiting 120 ms before retrying after HTTP 206.") }))
        XCTAssertGreaterThanOrEqual(elapsedMs, 115, "Expected delay before second attempt.")
    }

    func testPreRequestJavaScriptPmGenerarqrLogsInlinePngOnly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = RequestExecutionService(session: session)

        MockURLProtocol.handler = { request in
            let data = Data(#"{"ok":true}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let request = APIRequestModel(
            name: "QR log",
            method: .get,
            url: "https://api.example.com/ping",
            scripts: [
                ScriptDefinition(
                    name: "Show QR",
                    listen: .preRequest,
                    language: "javascript",
                    source: """
                    pm.generarqr("contenido-qr-test");
                    """
                ),
            ]
        )

        let outcome = try await service.execute(
            request: request,
            globals: [],
            collectionVariables: [],
            environmentVariables: []
        )

        XCTAssertEqual(outcome.response.statusCode, 200)
        let joined = outcome.logs.joined(separator: "\n")
        XCTAssertFalse(joined.contains("██"), "ASCII QR should not be logged when PNG is used")
        XCTAssertTrue(
            joined.contains(WorkspaceFlowInlineImageLogLine.markerPrefix),
            "expected inline image marker for PNG temp file"
        )
        XCTAssertTrue(joined.contains("QR (pm.generarqr)"), "logs: \(outcome.logs)")
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("Handler not configured")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBodyString(from request: URLRequest) -> String? {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }

    return String(data: data, encoding: .utf8)
}

/// Matches `RequestExecutionService.awsCanonicalURIPathForSigning` for SigV4 canonical requests.
private func awsCanonicalURIPathForLambdaSigningTests(percentEncodedPath: String) -> String {
    let path = percentEncodedPath.isEmpty ? "/" : percentEncodedPath
    if path == "/" {
        return "/"
    }
    return path.replacingOccurrences(of: "%", with: "%25")
}

private func expectedLambdaAuthorizationHeader(
    accessKeyID: String,
    secretAccessKey: String,
    sessionToken: String,
    url: URL,
    amzDate: String,
    httpMethod: String,
    payloadHash: String,
    contentType: String
) -> String {
    let dateStamp = String(amzDate.prefix(8))
    let percentEncodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    let canonicalURI = awsCanonicalURIPathForLambdaSigningTests(percentEncodedPath: percentEncodedPath)
    let canonicalHeaders = [
        ("content-type", canonicalHeaderValue(contentType)),
        ("host", canonicalHeaderValue(url.host ?? "")),
        ("x-amz-content-sha256", canonicalHeaderValue(payloadHash)),
        ("x-amz-date", canonicalHeaderValue(amzDate)),
        ("x-amz-security-token", canonicalHeaderValue(sessionToken)),
    ]
    let canonicalHeadersString = canonicalHeaders
        .map { "\($0.0):\($0.1)\n" }
        .joined()
    let signedHeaders = canonicalHeaders
        .map(\.0)
        .joined(separator: ";")
    let canonicalRequest = [
        httpMethod,
        canonicalURI,
        "",
        canonicalHeadersString,
        signedHeaders,
        payloadHash,
    ].joined(separator: "\n")
    let credentialScope = "\(dateStamp)/us-east-1/lambda/aws4_request"
    let stringToSign = [
        "AWS4-HMAC-SHA256",
        amzDate,
        credentialScope,
        sha256Hex(of: canonicalRequest),
    ].joined(separator: "\n")
    let signingKey = awsSigningKey(
        secretAccessKey: secretAccessKey,
        dateStamp: dateStamp,
        region: "us-east-1",
        service: "lambda"
    )
    let signature = hmacSHA256Hex(message: stringToSign, keyData: signingKey)
    return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
}

private func canonicalHeaderValue(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private func sha256Hex(of value: String) -> String {
    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    return ""
    #endif
}

private func awsSigningKey(secretAccessKey: String, dateStamp: String, region: String, service: String) -> Data {
    let secret = Data(("AWS4" + secretAccessKey).utf8)
    let dateKey = hmacSHA256Data(message: dateStamp, key: secret)
    let regionKey = hmacSHA256Data(message: region, key: dateKey)
    let serviceKey = hmacSHA256Data(message: service, key: regionKey)
    return hmacSHA256Data(message: "aws4_request", key: serviceKey)
}

private func hmacSHA256Data(message: String, key: Data) -> Data {
    #if canImport(CryptoKit)
    let symmetricKey = SymmetricKey(data: key)
    let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
    return Data(digest)
    #else
    return Data()
    #endif
}

private func hmacSHA256Hex(message: String, keyData: Data) -> String {
    #if canImport(CryptoKit)
    let symmetricKey = SymmetricKey(data: keyData)
    let digest = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    return ""
    #endif
}

private func hmacSHA256Hex(message: String, key: String) -> String {
    #if canImport(CryptoKit)
    let messageData = Data(message.utf8)
    let keyData = Data(key.utf8)
    let symmetricKey = SymmetricKey(data: keyData)
    let digest = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    return ""
    #endif
}

private let testRSAPublicKeyPEM = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnDXuoNoUfDmsmuijImY3
AwAeLwe8KeubuFhbN1s2LSawJIvQQh2rALekF2KZSYiIu7lf3V19JOfc/41DdOHL
Cfonn/nhzPagCiEmDv2z5CpkLFlVZjnDHyV65Us5EFPUYodQqufvPHawsZQ+WXUQ
hBaRzxFqJ4k9rDGDLf97Nq7uwFptnX2h94QsB6d7FLKJwhcJUI3KUwoDiwUHfD48
OCp0d2Tlqb9QIbNDwjdBGxcLllXeuiSXu/Z09sYKX2k6jKS/CUtdqx8vMEYhN9qE
Emf7hLRX6TiUSIkG8z8NxxuTaVUt8nEZzRVF73SbeuqTWBNUyoOR3tzD4st+G+n4
DQIDAQAB
-----END PUBLIC KEY-----
"""

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }
}
