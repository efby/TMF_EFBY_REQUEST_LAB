import EfbyApplication
import Foundation
import Security

public final class WebSocketExecutionService: Sendable {
    private let resolver: VariableResolver
    private let scriptEngine: ScriptEngine

    private final class ExpressionEvaluationState {
        var runtime: ScriptRuntimeContext
        var logs: [String] = []

        init(runtime: ScriptRuntimeContext) {
            self.runtime = runtime
        }
    }

    public init(
        resolver: VariableResolver = VariableResolver(),
        scriptEngine: ScriptEngine = ScriptEngine()
    ) {
        self.resolver = resolver
        self.scriptEngine = scriptEngine
    }

    private final class RequestSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private let allowInsecureTLS: Bool
        private let lock = NSLock()
        private var lastTLSDiagnosticMessage: String?

        init(allowInsecureTLS: Bool) {
            self.allowInsecureTLS = allowInsecureTLS
        }

        var lastTLSDiagnostic: String? {
            lock.lock()
            defer { lock.unlock() }
            return lastTLSDiagnosticMessage
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handle(challenge: challenge, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            handle(challenge: challenge, completionHandler: completionHandler)
        }

        private func handle(
            challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                recordTLSDiagnostic(for: challenge.protectionSpace)

                if allowInsecureTLS, let trust = challenge.protectionSpace.serverTrust {
                    let relaxedPolicy = SecPolicyCreateSSL(false, nil)
                    SecTrustSetPolicies(trust, relaxedPolicy)
                    completionHandler(.useCredential, URLCredential(trust: trust))
                    return
                }
            }

            completionHandler(.performDefaultHandling, nil)
        }

        private func recordTLSDiagnostic(for protectionSpace: URLProtectionSpace) {
            var parts: [String] = []
            parts.append("TLS protection space host: \(protectionSpace.host)")
            parts.append("Port: \(protectionSpace.port)")
            parts.append("Authentication method: \(protectionSpace.authenticationMethod)")

            if let trust = protectionSpace.serverTrust {
                let certificateCount = SecTrustGetCertificateCount(trust)
                parts.append("Certificate chain length: \(certificateCount)")

                if let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                   let summary = SecCertificateCopySubjectSummary(certificate) as String? {
                    parts.append("Leaf certificate: \(summary)")
                }

                var trustError: CFError?
                let trustIsValid = SecTrustEvaluateWithError(trust, &trustError)
                parts.append("Trust evaluation passed: \(trustIsValid ? "yes" : "no")")
                if let trustError {
                    parts.append("Trust evaluation detail: \(trustError)")
                }
            } else {
                parts.append("No server trust object was provided by the challenge.")
            }

            lock.lock()
            lastTLSDiagnosticMessage = parts.joined(separator: "\n")
            lock.unlock()
        }
    }

    public func prepareConnection(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) throws -> WebSocketPreparationOutcome {
        var logs: [String] = []
        logs.append("URL plantilla: \(request.url)")
        var runtime = ScriptRuntimeContext(
            globals: dictionaryAllowingDuplicateKeys(from: globals),
            collection: dictionaryAllowingDuplicateKeys(from: collectionVariables),
            environment: dictionaryAllowingDuplicateKeys(from: environmentVariables),
            environments: hydratedEnvironments(
                from: workspaceEnvironments,
                activeEnvironmentID: activeEnvironmentID,
                fallbackEnvironment: environmentVariables
            ),
            activeEnvironmentID: resolvedActiveEnvironmentID(
                requestedActiveEnvironmentID: activeEnvironmentID,
                availableEnvironments: workspaceEnvironments
            ),
            local: dictionaryAllowingDuplicateKeys(from: request.localVariables)
        )

        let preRequestReport = scriptEngine.execute(
            scripts: request.scripts,
            event: .preRequest,
            runtime: runtime,
            request: request,
            utilities: utilityLibraries
        )
        runtime = preRequestReport.runtime
        logs.append(contentsOf: preRequestReport.logs)

        let context = VariableResolutionContext(
            globals: dictionaryToVariables(runtime.globals),
            collection: dictionaryToVariables(runtime.collection),
            environment: dictionaryToVariables(runtime.environment),
            local: dictionaryToKeyValues(runtime.local)
        )

        let expressionState = ExpressionEvaluationState(runtime: runtime)
        let urlRequest = try makeURLRequest(
            request: request,
            requestHeaders: runtime.requestHeaders,
            requestQueryItems: runtime.requestQueryItems,
            context: context,
            expressionEvaluator: makeExpressionEvaluator(
                state: expressionState,
                request: request,
                utilityLibraries: utilityLibraries
            )
        )
        runtime = expressionState.runtime
        logs.append(contentsOf: expressionState.logs)
        let rawRequest = rawHTTPRepresentation(for: urlRequest)
        let transport = configuredTransport(for: request)
        logs.append(contentsOf: transport.logs)

        return WebSocketPreparationOutcome(
            urlRequest: urlRequest,
            rawRequest: rawRequest,
            updatedRequestHeaders: runtime.requestHeaders,
            updatedRequestQueryItems: runtime.requestQueryItems,
            updatedRequestBody: runtime.requestBody,
            updatedGlobals: dictionaryToVariables(runtime.globals),
            updatedCollection: dictionaryToVariables(runtime.collection),
            updatedEnvironment: dictionaryToVariables(runtime.environment),
            updatedEnvironments: runtime.environments,
            activeEnvironmentID: runtime.activeEnvironmentID,
            updatedLocal: dictionaryToKeyValues(runtime.local),
            logs: logs
        )
    }

    public func connect(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol {
        let transport = configuredTransport(for: request)
        let webSocketTask = transport.session.webSocketTask(with: prepared.urlRequest)
        webSocketTask.resume()

        do {
            try await sendPing(using: webSocketTask)
        } catch {
            let diagnostic = await describeNetworkError(
                error,
                for: prepared.urlRequest,
                task: webSocketTask,
                session: transport.session,
                delegate: transport.delegate
            )
            webSocketTask.cancel(with: .goingAway, reason: nil)
            transport.session.invalidateAndCancel()
            throw AppError.network(diagnostic)
        }

        return WebSocketConnection(
            session: transport.session,
            task: webSocketTask
        )
    }

    private func sendPing(using task: URLSessionWebSocketTask) async throws {
        try await sendPingSafely(using: task)
    }

    public func resolveOutgoingMessage(
        from request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) -> String {
        let context = VariableResolutionContext(
            globals: globals.filter(\.isEnabled),
            collection: collectionVariables.filter(\.isEnabled),
            environment: environmentVariables.filter(\.isEnabled),
            local: request.localVariables.filter(\.isEnabled).map {
                KeyValueEntry(key: $0.key, value: $0.value, isEnabled: $0.isEnabled)
            }
        )
        let state = ExpressionEvaluationState(
            runtime: ScriptRuntimeContext(
                globals: dictionaryAllowingDuplicateKeys(from: globals),
                collection: dictionaryAllowingDuplicateKeys(from: collectionVariables),
                environment: dictionaryAllowingDuplicateKeys(from: environmentVariables),
                local: dictionaryAllowingDuplicateKeys(from: request.localVariables)
            )
        )
        return resolver.resolve(
            request.body.raw,
            context: context,
            expressionEvaluator: makeExpressionEvaluator(
                state: state,
                request: request,
                utilityLibraries: utilityLibraries
            )
        )
    }

    public func resolve(
        _ text: String,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        localVariables: [KeyValueEntry],
        request: APIRequestModel? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) -> String {
        let context = VariableResolutionContext(
            globals: globals.filter(\.isEnabled),
            collection: collectionVariables.filter(\.isEnabled),
            environment: environmentVariables.filter(\.isEnabled),
            local: localVariables.filter(\.isEnabled)
        )
        let state = ExpressionEvaluationState(
            runtime: ScriptRuntimeContext(
                globals: dictionaryAllowingDuplicateKeys(from: globals),
                collection: dictionaryAllowingDuplicateKeys(from: collectionVariables),
                environment: dictionaryAllowingDuplicateKeys(from: environmentVariables),
                local: dictionaryAllowingDuplicateKeys(from: localVariables)
            )
        )
        return resolver.resolve(
            text,
            context: context,
            expressionEvaluator: makeExpressionEvaluator(
                state: state,
                request: request,
                utilityLibraries: utilityLibraries
            )
        )
    }

    public func executeIncomingMessageScripts(
        message: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) -> WebSocketMessageScriptOutcome {
        let runtime = ScriptRuntimeContext(
            globals: dictionaryAllowingDuplicateKeys(from: globals),
            collection: dictionaryAllowingDuplicateKeys(from: collectionVariables),
            environment: dictionaryAllowingDuplicateKeys(from: environmentVariables),
            environments: hydratedEnvironments(
                from: workspaceEnvironments,
                activeEnvironmentID: activeEnvironmentID,
                fallbackEnvironment: environmentVariables
            ),
            activeEnvironmentID: resolvedActiveEnvironmentID(
                requestedActiveEnvironmentID: activeEnvironmentID,
                availableEnvironments: workspaceEnvironments
            ),
            local: dictionaryAllowingDuplicateKeys(from: request.localVariables),
            webSocketMessage: message
        )

        let report = scriptEngine.execute(
            scripts: request.scripts,
            event: .test,
            runtime: runtime,
            request: request,
            utilities: utilityLibraries
        )

        return WebSocketMessageScriptOutcome(
            updatedGlobals: dictionaryToVariables(report.runtime.globals),
            updatedCollection: dictionaryToVariables(report.runtime.collection),
            updatedEnvironment: dictionaryToVariables(report.runtime.environment),
            updatedEnvironments: report.runtime.environments,
            activeEnvironmentID: report.runtime.activeEnvironmentID,
            updatedLocal: dictionaryToKeyValues(report.runtime.local),
            logs: report.logs,
            shouldDisconnect: report.runtime.webSocketShouldDisconnect
        )
    }

    public func executeDoneScripts(
        cause: String,
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) -> WebSocketMessageScriptOutcome {
        let runtime = ScriptRuntimeContext(
            globals: dictionaryAllowingDuplicateKeys(from: globals),
            collection: dictionaryAllowingDuplicateKeys(from: collectionVariables),
            environment: dictionaryAllowingDuplicateKeys(from: environmentVariables),
            environments: hydratedEnvironments(
                from: workspaceEnvironments,
                activeEnvironmentID: activeEnvironmentID,
                fallbackEnvironment: environmentVariables
            ),
            activeEnvironmentID: resolvedActiveEnvironmentID(
                requestedActiveEnvironmentID: activeEnvironmentID,
                availableEnvironments: workspaceEnvironments
            ),
            local: dictionaryAllowingDuplicateKeys(from: request.localVariables),
            webSocketDoneCause: cause
        )

        let report = scriptEngine.execute(
            scripts: request.scripts,
            event: .test,
            runtime: runtime,
            request: request,
            utilities: utilityLibraries
        )

        return WebSocketMessageScriptOutcome(
            updatedGlobals: dictionaryToVariables(report.runtime.globals),
            updatedCollection: dictionaryToVariables(report.runtime.collection),
            updatedEnvironment: dictionaryToVariables(report.runtime.environment),
            updatedEnvironments: report.runtime.environments,
            activeEnvironmentID: report.runtime.activeEnvironmentID,
            updatedLocal: dictionaryToKeyValues(report.runtime.local),
            logs: report.logs,
            shouldDisconnect: report.runtime.webSocketShouldDisconnect
        )
    }

    private func hydratedEnvironments(
        from environments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        fallbackEnvironment: [VariableValue]
    ) -> [EnvironmentProfile] {
        if !environments.isEmpty {
            return environments
        }

        guard !fallbackEnvironment.isEmpty else {
            return []
        }

        return [
            EnvironmentProfile(
                id: activeEnvironmentID ?? UUID(),
                name: "Script Environment",
                variables: fallbackEnvironment
            ),
        ]
    }

    private func resolvedActiveEnvironmentID(
        requestedActiveEnvironmentID: UUID?,
        availableEnvironments: [EnvironmentProfile]
    ) -> UUID? {
        requestedActiveEnvironmentID ?? availableEnvironments.first(where: \.isEnabled)?.id ?? availableEnvironments.first?.id
    }

    private func configuredTransport(for request: APIRequestModel) -> (session: URLSession, delegate: RequestSessionDelegate, logs: [String]) {
        let delegate = RequestSessionDelegate(allowInsecureTLS: request.tlsValidationMode == .insecure)
        let configuration = URLSessionConfiguration.ephemeral

        switch request.minimumTLSVersion {
        case .systemDefault:
            break
        case .tls10:
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
        case .tls11:
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv11
        case .tls12:
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        }

        let configuredSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        var logs: [String] = []
        if request.tlsValidationMode == .insecure {
            logs.append("Warning: TLS certificate validation is disabled for this request.")
        }
        if request.minimumTLSVersion != .systemDefault {
            logs.append("TLS minimum version forced to \(request.minimumTLSVersion.displayName).")
        }

        return (configuredSession, delegate, logs)
    }

    private func describeNetworkError(
        _ error: Error,
        for request: URLRequest,
        task: URLSessionTask? = nil,
        session: URLSession,
        delegate: RequestSessionDelegate
    ) async -> String {
        let host = request.url?.host ?? "unknown-host"
        let tlsDiagnostic = delegate.lastTLSDiagnostic
        let responseDiagnostic = handshakeResponseDiagnostic(task: task, error: error)
        let contextDiagnostic = networkErrorContext(error)
        let outgoingRequestDiagnostic = handshakeRequestDiagnostic(for: request)
        let probeDiagnostic = await probeHandshakeFailureBodyIfPossible(
            using: session,
            request: request,
            error: error
        )

        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed:
                return joinErrorSections(
                    """
                    TLS/SSL handshake failed for \(host).
                    Verify the server certificate chain, local proxy/VPN interception, and that the server supports modern TLS.
                    Underlying error: \(urlError.localizedDescription)
                    """,
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .serverCertificateHasBadDate:
                return joinErrorSections(
                    "The server certificate for \(host) has an invalid date. Check the server certificate validity and your Mac date/time.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .serverCertificateUntrusted:
                return joinErrorSections(
                    "The server certificate for \(host) is not trusted on this Mac.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .serverCertificateHasUnknownRoot:
                return joinErrorSections(
                    "The server certificate for \(host) was issued by an unknown root CA.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .serverCertificateNotYetValid:
                return joinErrorSections(
                    "The server certificate for \(host) is not valid yet.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .clientCertificateRejected:
                return joinErrorSections(
                    "The server rejected the client certificate for \(host).",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .clientCertificateRequired:
                return joinErrorSections(
                    "The server \(host) requires a client certificate (mTLS).",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .cannotFindHost:
                return joinErrorSections(
                    "The host \(host) could not be found.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .cannotConnectToHost:
                return joinErrorSections(
                    "Unable to connect to \(host). Check network connectivity, firewall, proxy, or VPN.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .timedOut:
                return joinErrorSections(
                    "The request to \(host) timed out.",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            case .badServerResponse:
                return joinErrorSections(
                    "The server returned an invalid WebSocket handshake response for \(host).",
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            default:
                return joinErrorSections(
                    urlError.localizedDescription,
                    contextDiagnostic,
                    outgoingRequestDiagnostic,
                    responseDiagnostic,
                    probeDiagnostic,
                    tlsDiagnostic
                )
            }
        }

        return joinErrorSections(
            error.localizedDescription,
            contextDiagnostic,
            outgoingRequestDiagnostic,
            responseDiagnostic,
            probeDiagnostic,
            tlsDiagnostic
        )
    }

    private func joinErrorSections(_ sections: String?...) -> String {
        sections
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func networkErrorContext(_ error: Error) -> String? {
        let nsError = error as NSError
        var parts = [
            "Error domain: \(nsError.domain)",
            "Error code: \(nsError.code)",
        ]

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("Failing URL: \(failingURL.absoluteString)")
        } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            parts.append("Failing URL: \(failingURLString)")
        }

        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            parts.append("Failure reason: \(reason)")
        }

        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            parts.append("Recovery suggestion: \(suggestion)")
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(
                "Underlying NSError: \(underlyingError.domain) (\(underlyingError.code)) - \(underlyingError.localizedDescription)"
            )
        }

        return parts.joined(separator: "\n")
    }

    private func handshakeRequestDiagnostic(for request: URLRequest) -> String {
        var lines = ["Outgoing WebSocket handshake request:"]
        lines.append(rawHTTPRepresentation(for: request))
        lines.append("Connection: Upgrade (system-managed)")
        lines.append("Upgrade: websocket (system-managed)")
        lines.append("Sec-WebSocket-Version: 13 (system-managed)")
        lines.append("Sec-WebSocket-Key: <system-generated> (system-managed)")
        return lines.joined(separator: "\n")
    }

    private func handshakeResponseDiagnostic(task: URLSessionTask?, error: Error) -> String? {
        let nsError = error as NSError
        let urlResponse = task?.response

        guard let urlResponse else {
            if let underlyingResponse = nsError.userInfo["NSErrorFailingURLResponseKey"] as? URLResponse {
                return formatHandshakeResponseDiagnostic(underlyingResponse)
            }
            return nil
        }

        return formatHandshakeResponseDiagnostic(urlResponse)
    }

    private func formatHandshakeResponseDiagnostic(_ urlResponse: URLResponse) -> String {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            return "Handshake response type: \(String(describing: type(of: urlResponse)))"
        }

        var parts = ["Handshake HTTP status: \(httpResponse.statusCode)"]

        if let url = httpResponse.url?.absoluteString, !url.isEmpty {
            parts.append("Handshake response URL: \(url)")
        }

        let headerLines = httpResponse.allHeaderFields
            .map { "\($0.key): \($0.value)" }
            .sorted()

        if !headerLines.isEmpty {
            parts.append("Handshake response headers:")
            parts.append(contentsOf: headerLines)
        }

        return parts.joined(separator: "\n")
    }

    private func probeHandshakeFailureBodyIfPossible(
        using session: URLSession,
        request: URLRequest,
        error: Error
    ) async -> String? {
        guard shouldAttemptHandshakeProbe(for: error) else {
            return nil
        }

        guard let probeURL = diagnosticHTTPURL(from: request.url) else {
            return nil
        }

        var probeRequest = request
        probeRequest.url = probeURL
        probeRequest.httpMethod = "GET"
        probeRequest.timeoutInterval = min(max(request.timeoutInterval, 3), 8)
        probeRequest.setValue("Upgrade", forHTTPHeaderField: "Connection")
        probeRequest.setValue("websocket", forHTTPHeaderField: "Upgrade")
        probeRequest.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        probeRequest.setValue("MDEyMzQ1Njc4OUFCQ0RFRg==", forHTTPHeaderField: "Sec-WebSocket-Key")

        do {
            let (data, response) = try await session.data(for: probeRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            var parts = ["Diagnostic HTTPS probe status: \(httpResponse.statusCode)"]
            if let url = httpResponse.url?.absoluteString, !url.isEmpty {
                parts.append("Diagnostic HTTPS probe URL: \(url)")
            }

            let headerLines = httpResponse.allHeaderFields
                .map { "\($0.key): \($0.value)" }
                .sorted()
            if !headerLines.isEmpty {
                parts.append("Diagnostic HTTPS probe headers:")
                parts.append(contentsOf: headerLines)
            }

            if !data.isEmpty {
                let body = ResponseFormatter.prettyBody(data: data, mimeType: httpResponse.mimeType)
                if !body.isEmpty {
                    parts.append("Diagnostic HTTPS probe body:")
                    parts.append(body)
                }
            }

            return parts.joined(separator: "\n")
        } catch {
            return "Diagnostic HTTPS probe failed: \(error.localizedDescription)"
        }
    }

    private func shouldAttemptHandshakeProbe(for error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .badServerResponse, .userAuthenticationRequired:
            return true
        default:
            return false
        }
    }

    private func diagnosticHTTPURL(from url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            break
        }

        return components.url
    }

    private func makeURLRequest(
        request: APIRequestModel,
        requestHeaders: [KeyValueEntry]? = nil,
        requestQueryItems: [KeyValueEntry]? = nil,
        context: VariableResolutionContext,
        expressionEvaluator: @escaping (String, VariableResolutionContext) -> String?
    ) throws -> URLRequest {
        var baseURL = resolver.resolve(request.url, context: context, expressionEvaluator: expressionEvaluator)
        request.pathVariables.filter(\.isEnabled).forEach { entry in
            let value = resolver.resolve(entry.value, context: context, expressionEvaluator: expressionEvaluator)
            baseURL = baseURL.replacingOccurrences(of: "{\(entry.key)}", with: value)
            baseURL = baseURL.replacingOccurrences(of: ":\(entry.key)", with: value)
        }

        guard var components = URLComponents(string: baseURL) else {
            throw AppError.invalidURL("URL invalida: \(baseURL)")
        }

        let queryItems = (requestQueryItems ?? request.queryItems)
            .filter(\.isEnabled)
            .map {
                URLQueryItem(
                    name: $0.key,
                    value: resolver.resolve($0.value, context: context, expressionEvaluator: expressionEvaluator)
                )
            }

        if !queryItems.isEmpty {
            let existing = components.queryItems ?? []
            components.queryItems = existing + queryItems
        }

        guard let finalURL = components.url else {
            throw AppError.invalidURL("No se pudo construir la URL: \(baseURL)")
        }

        var urlRequest = URLRequest(url: finalURL)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = request.timeoutSeconds

        (requestHeaders ?? request.headers).filter(\.isEnabled).forEach { header in
            urlRequest.setValue(
                resolver.resolve(header.value, context: context, expressionEvaluator: expressionEvaluator),
                forHTTPHeaderField: header.key
            )
        }

        if !request.cookies.filter(\.isEnabled).isEmpty {
            let cookieHeader = request.cookies
                .filter(\.isEnabled)
                .map {
                    "\($0.key)=\(resolver.resolve($0.value, context: context, expressionEvaluator: expressionEvaluator))"
                }
                .joined(separator: "; ")
            urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let protocols = request.webSocketSubprotocols
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !protocols.isEmpty {
            urlRequest.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        apply(auth: request.auth, to: &urlRequest, context: context, expressionEvaluator: expressionEvaluator)
        return urlRequest
    }

    private func apply(
        auth: AuthConfiguration,
        to request: inout URLRequest,
        context: VariableResolutionContext,
        expressionEvaluator: @escaping (String, VariableResolutionContext) -> String?
    ) {
        switch auth.type {
        case .noAuth:
            return
        case .basic:
            let username = resolver.resolve(auth.username, context: context, expressionEvaluator: expressionEvaluator)
            let password = resolver.resolve(auth.password, context: context, expressionEvaluator: expressionEvaluator)
            let value = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        case .bearer:
            let token = resolver.resolve(auth.token, context: context, expressionEvaluator: expressionEvaluator)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            let key = resolver.resolve(auth.key, context: context, expressionEvaluator: expressionEvaluator)
            let value = resolver.resolve(auth.value, context: context, expressionEvaluator: expressionEvaluator)
            switch auth.addTo {
            case .header:
                request.setValue(value, forHTTPHeaderField: key)
            case .query:
                if let url = request.url,
                   var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    var items = components.queryItems ?? []
                    items.append(URLQueryItem(name: key, value: value))
                    components.queryItems = items
                    request.url = components.url
                }
            }
        case .oauth2:
            let token = resolver.resolve(auth.token, context: context, expressionEvaluator: expressionEvaluator)
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .awsTemporaryCredentials:
            return
        }
    }

    private func makeExpressionEvaluator(
        state: ExpressionEvaluationState,
        request: APIRequestModel?,
        utilityLibraries: [WorkspaceScriptUtility]
    ) -> (String, VariableResolutionContext) -> String? {
        { expression, _ in
            guard let report = self.scriptEngine.evaluateTemplateExpressionReport(
                expression,
                runtime: state.runtime,
                request: request,
                utilities: utilityLibraries
            ) else {
                return nil
            }

            state.runtime = report.runtime
            state.logs.append(contentsOf: report.logs)
            return report.value
        }
    }

    private func dictionaryToVariables(_ values: [String: String]) -> [VariableValue] {
        values.keys.sorted().map { VariableValue(key: $0, value: values[$0] ?? "") }
    }

    private func dictionaryToKeyValues(_ values: [String: String]) -> [KeyValueEntry] {
        values.keys.sorted().map { KeyValueEntry(key: $0, value: values[$0] ?? "") }
    }

    private func dictionaryAllowingDuplicateKeys(from variables: [VariableValue]) -> [String: String] {
        variables
            .filter(\.isEnabled)
            .reduce(into: [String: String]()) { partialResult, variable in
                partialResult[variable.key] = variable.value
            }
    }

    private func dictionaryAllowingDuplicateKeys(from entries: [KeyValueEntry]) -> [String: String] {
        entries
            .filter(\.isEnabled)
            .reduce(into: [String: String]()) { partialResult, entry in
                partialResult[entry.key] = entry.value
            }
    }

    private func rawHTTPRepresentation(for request: URLRequest) -> String {
        let url = request.url ?? URL(string: "about:blank")!
        let method = request.httpMethod ?? "GET"
        let path = request.url.flatMap { url in
            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query, !query.isEmpty {
                path += "?\(query)"
            }
            return path
        } ?? "/"

        var lines = ["\(method) \(path) HTTP/1.1"]
        lines.append("Host: \(url.host ?? "unknown-host")")

        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

        for header in headers {
            lines.append("\(header.key): \(header.value)")
        }

        return lines.joined(separator: "\n")
    }
}

private func sendPingSafely(using task: URLSessionWebSocketTask) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let oneShot = PingContinuationBox(continuation)
        task.sendPing { error in
            if let error {
                oneShot.resume(with: .failure(error))
            } else {
                oneShot.resume(with: .success(()))
            }
        }
    }
}

private final class PingContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

public actor WebSocketConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var isClosed = false

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    public func startReceiving(
        onEvent: @escaping @Sendable (WebSocketReceiveEvent) async -> Void
    ) -> Task<Void, Never> {
        Task {
            while let event = await receiveNextEvent() {
                await onEvent(event)
                switch event {
                case .closed, .failure:
                    return
                case .entry:
                    continue
                }
            }
        }
    }

    public func receiveNextEvent() async -> WebSocketReceiveEvent? {
        guard !Task.isCancelled && !isClosed else {
            return nil
        }

        do {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                return .entry(WebSocketTranscriptEntry(direction: .incoming, body: text))
            case .data(let data):
                let payload = "Binary message (\(data.count) bytes)\n\(data.base64EncodedString())"
                return .entry(WebSocketTranscriptEntry(direction: .incoming, body: payload))
            @unknown default:
                return .entry(WebSocketTranscriptEntry(direction: .system, body: "Received an unsupported WebSocket frame."))
            }
        } catch {
            if Task.isCancelled || isClosed {
                return nil
            }

            let closeNote = closeDescription()
            await disconnect(closeCode: .goingAway)
            if !closeNote.isEmpty {
                return .closed(closeNote)
            }
            return .failure(error.localizedDescription)
        }
    }

    public func send(text: String) async throws {
        guard !isClosed else {
            throw AppError.network("The WebSocket connection is already closed.")
        }
        try await task.send(.string(text))
    }

    public func sendPing() async throws {
        guard !isClosed else {
            throw AppError.network("The WebSocket connection is already closed.")
        }

        try await sendPingSafely(using: task)
    }

    public func disconnect() async {
        await disconnect(closeCode: .normalClosure)
    }

    public func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) async {
        guard !isClosed else { return }
        isClosed = true
        task.cancel(with: closeCode, reason: nil)
        session.invalidateAndCancel()
    }

    private func closeDescription() -> String {
        let closeCode = task.closeCode
        guard closeCode != .invalid else {
            return ""
        }

        let reason: String
        if let closeReason = task.closeReason,
           let text = String(data: closeReason, encoding: .utf8),
           !text.isEmpty {
            reason = " - \(text)"
        } else {
            reason = ""
        }

        return "Connection closed (\(closeCode.rawValue)\(reason))"
    }
}
