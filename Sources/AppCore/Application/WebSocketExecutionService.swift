import EfbyApplication
import Foundation
import Security

public final class WebSocketExecutionService: Sendable {
    private let resolver: VariableResolver
    private let scriptEngine: ScriptEngine
    typealias SessionFactory = @Sendable (URLSessionConfiguration, any URLSessionDelegate) -> URLSession
    private let sessionFactory: SessionFactory
    private let connectionFactory: (@Sendable (URLRequest) -> WebSocketConnection)?

    private final class ExpressionEvaluationState {
        var runtime: ScriptRuntimeContext
        var logs: [String] = []
        var interruption: ScriptExecutionInterruption?

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
        self.connectionFactory = nil
        self.sessionFactory = { URLSession(configuration: $0, delegate: $1, delegateQueue: nil) }
    }

    init(connectionFactory: @escaping @Sendable (URLRequest) -> WebSocketConnection) {
        self.resolver = VariableResolver()
        self.scriptEngine = ScriptEngine()
        self.connectionFactory = connectionFactory
        self.sessionFactory = { URLSession(configuration: $0, delegate: $1, delegateQueue: nil) }
    }

    init(sessionFactory: @escaping SessionFactory) {
        self.resolver = VariableResolver()
        self.scriptEngine = ScriptEngine()
        self.connectionFactory = nil
        self.sessionFactory = sessionFactory
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
        try Task.checkCancellation()
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
        try preRequestReport.checkInterruption()
        try Task.checkCancellation()
        runtime = preRequestReport.runtime
        logs.append(contentsOf: preRequestReport.logs)

        let context = VariableResolutionContext(
            globals: dictionaryToVariables(runtime.globals),
            collection: dictionaryToVariables(runtime.collection),
            environment: dictionaryToVariables(runtime.environment),
            local: dictionaryToKeyValues(runtime.local)
        )

        let expressionState = ExpressionEvaluationState(runtime: runtime)
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(
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
        } catch {
            try expressionState.interruption?.checkInterruption()
            try Task.checkCancellation()
            throw error
        }
        try expressionState.interruption?.checkInterruption()
        try Task.checkCancellation()
        runtime = expressionState.runtime
        logs.append(contentsOf: expressionState.logs)
        let rawRequest = rawHTTPRepresentation(for: urlRequest)
        logs.append(contentsOf: transportLogs(for: request))

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
        try Task.checkCancellation()
        let connection: WebSocketConnection
        let diagnosticSession: URLSession?
        let diagnosticDelegate: RequestSessionDelegate?
        let nativeTask: URLSessionWebSocketTask?
        if let connectionFactory {
            connection = connectionFactory(prepared.urlRequest)
            diagnosticSession = nil
            diagnosticDelegate = nil
            nativeTask = nil
        } else {
            let transport = configuredTransport(for: request)
            let task = transport.session.webSocketTask(with: prepared.urlRequest)
            connection = WebSocketConnection(session: transport.session, task: task)
            diagnosticSession = transport.session
            diagnosticDelegate = transport.delegate
            nativeTask = task
        }
        do {
            try await connection.open()
            try Task.checkCancellation()
            return connection
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                await connection.disconnect()
                throw CancellationError()
            }
            let diagnostic: String
            if let diagnosticSession, let diagnosticDelegate {
                diagnostic = await describeNetworkError(
                    error,
                    for: prepared.urlRequest,
                    task: nativeTask,
                    session: diagnosticSession,
                    delegate: diagnosticDelegate
                )
            } else {
                diagnostic = error.localizedDescription
            }
            await connection.disconnect()
            try Task.checkCancellation()
            throw AppError.network(diagnostic)
        }
    }

    public func resolveOutgoingMessage(
        from request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) throws -> String {
        try Task.checkCancellation()
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
        let value = resolver.resolve(
            request.body.raw,
            context: context,
            expressionEvaluator: makeExpressionEvaluator(
                state: state,
                request: request,
                utilityLibraries: utilityLibraries
            )
        )
        try state.interruption?.checkInterruption()
        try Task.checkCancellation()
        return value
    }

    public func resolve(
        _ text: String,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        localVariables: [KeyValueEntry],
        request: APIRequestModel? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) throws -> String {
        try Task.checkCancellation()
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
        let value = resolver.resolve(
            text,
            context: context,
            expressionEvaluator: makeExpressionEvaluator(
                state: state,
                request: request,
                utilityLibraries: utilityLibraries
            )
        )
        try state.interruption?.checkInterruption()
        try Task.checkCancellation()
        return value
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
            shouldDisconnect: report.interruption != nil || Task.isCancelled || report.runtime.webSocketShouldDisconnect,
            scriptError: report.interruption?.localizedDescription ?? (Task.isCancelled ? CancellationError().localizedDescription : nil)
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
            shouldDisconnect: report.interruption != nil || Task.isCancelled || report.runtime.webSocketShouldDisconnect,
            scriptError: report.interruption?.localizedDescription ?? (Task.isCancelled ? CancellationError().localizedDescription : nil)
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

        let configuredSession = sessionFactory(configuration, delegate)

        return (configuredSession, delegate, transportLogs(for: request))
    }

    private func transportLogs(for request: APIRequestModel) -> [String] {
        var logs: [String] = []
        if request.tlsValidationMode == .insecure {
            logs.append("Warning: TLS certificate validation is disabled for this request.")
        }
        if request.minimumTLSVersion != .systemDefault {
            logs.append("TLS minimum version forced to \(request.minimumTLSVersion.displayName).")
        }
        return logs
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
            guard state.interruption == nil else { return nil }
            guard let report = self.scriptEngine.evaluateTemplateExpressionReport(
                expression,
                runtime: state.runtime,
                request: request,
                utilities: utilityLibraries
            ) else {
                return nil
            }

            if let interruption = report.interruption {
                state.interruption = interruption
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

/// Callback transport keeps the native operations testable without a server or real network.
struct WebSocketTransport: Sendable {
    let resume: @Sendable () -> Void
    let ping: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void
    let send: @Sendable (String, @escaping @Sendable (Error?) -> Void) -> Void
    let receive: @Sendable (@escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) -> Void
    let cancel: @Sendable (URLSessionWebSocketTask.CloseCode) -> Void
    let invalidate: @Sendable () -> Void
    let closeDescription: @Sendable () -> String
}

private final class WebSocketCallbackState<Value: Sendable>: @unchecked Sendable {
    // Native adapters and test transports may call their completion synchronously.
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func start(
        continuation: CheckedContinuation<Value, Error>,
        operation: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        operation { self.complete($0) }
        lock.unlock()
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class WebSocketLifetime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    let transport: WebSocketTransport
    private var closed = false
    private var pending: [UUID: @Sendable () -> Void] = [:]

    init(transport: WebSocketTransport) { self.transport = transport }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func operation<Value: Sendable>(
        _ start: @escaping @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let identifier = UUID()
        let state = WebSocketCallbackState<Value>()
        defer { removeOperation(identifier) }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startOperation(identifier, state: state, continuation: continuation, start: start)
            }
        } onCancel: {
            state.complete(.failure(CancellationError()))
            self.close(code: .goingAway)
        }
        try Task.checkCancellation()
        if isClosed { throw CancellationError() }
        return value
    }

    private func startOperation<Value: Sendable>(
        _ identifier: UUID,
        state: WebSocketCallbackState<Value>,
        continuation: CheckedContinuation<Value, Error>,
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) {
        lock.lock()
        if closed {
            lock.unlock()
            state.complete(.failure(CancellationError()))
            state.start(continuation: continuation, operation: start)
            return
        }
        pending[identifier] = { state.complete(.failure(CancellationError())) }
        state.start(continuation: continuation, operation: start)
        lock.unlock()
    }

    private func removeOperation(_ identifier: UUID) {
        lock.lock()
        pending.removeValue(forKey: identifier)
        lock.unlock()
    }

    func close(code: URLSessionWebSocketTask.CloseCode) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let operations = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for cancel in operations { cancel() }
        transport.cancel(code)
        transport.invalidate()
    }
}

public actor WebSocketConnection {
    private let lifetime: WebSocketLifetime

    init(transport: WebSocketTransport) {
        self.lifetime = WebSocketLifetime(transport: transport)
    }

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.lifetime = WebSocketLifetime(transport: WebSocketTransport(
            resume: { task.resume() },
            ping: { task.sendPing(pongReceiveHandler: $0) },
            send: { text, completion in task.send(.string(text), completionHandler: completion) },
            receive: { task.receive(completionHandler: $0) },
            cancel: { task.cancel(with: $0, reason: nil) },
            invalidate: { session.invalidateAndCancel() },
            closeDescription: {
                guard task.closeCode != .invalid else { return "" }
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return "Connection closed (\(task.closeCode.rawValue)\(reason.isEmpty ? "" : " - " + reason))"
            }
        ))
    }

    deinit { lifetime.close(code: .goingAway) }

    func open() async throws {
        let transport = lifetime.transport
        let _: Void = try await lifetime.operation { completion in
            transport.resume()
            transport.ping { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    public func startReceiving(
        onEvent: @escaping @Sendable (WebSocketReceiveEvent) async -> Void
    ) -> Task<Void, Never> {
        Task {
            while let event = await receiveNextEvent() {
                guard !Task.isCancelled else { return }
                await onEvent(event)
                switch event {
                case .closed, .failure: return
                case .entry: continue
                }
            }
        }
    }

    public func receiveNextEvent() async -> WebSocketReceiveEvent? {
        guard !Task.isCancelled && !lifetime.isClosed else { return nil }
        do {
            let transport = lifetime.transport
            let message = try await lifetime.operation { completion in transport.receive(completion) }
            guard !Task.isCancelled && !lifetime.isClosed else { return nil }
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
            if Task.isCancelled || lifetime.isClosed { return nil }
            let closeNote = lifetime.transport.closeDescription()
            lifetime.close(code: .goingAway)
            return closeNote.isEmpty ? .failure(error.localizedDescription) : .closed(closeNote)
        }
    }

    public func send(text: String) async throws {
        let transport = lifetime.transport
        let _: Void = try await lifetime.operation { completion in
            transport.send(text) { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    public func sendPing() async throws {
        let transport = lifetime.transport
        let _: Void = try await lifetime.operation { completion in
            transport.ping { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    public func disconnect() async { lifetime.close(code: .normalClosure) }

    public func disconnect(closeCode: URLSessionWebSocketTask.CloseCode) async { lifetime.close(code: closeCode) }
}
