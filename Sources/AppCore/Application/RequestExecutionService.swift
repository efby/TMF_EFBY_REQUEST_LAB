import CryptoKit
import Foundation
import Security

public final class RequestExecutionService: Sendable {
    private let session: URLSession
    private let resolver: VariableResolver
    private let scriptEngine: ScriptEngine
    private let lambdaInvokeService = "lambda"
    private let lambdaInvokeAlgorithm = "AWS4-HMAC-SHA256"

    private final class ExpressionEvaluationState {
        var runtime: ScriptRuntimeContext
        var logs: [String] = []

        init(runtime: ScriptRuntimeContext) {
            self.runtime = runtime
        }
    }

    public init(
        session: URLSession = .shared,
        resolver: VariableResolver = VariableResolver(),
        scriptEngine: ScriptEngine = ScriptEngine()
    ) {
        self.session = session
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

    public func execute(
        request: APIRequestModel,
        globals: [VariableValue],
        collectionVariables: [VariableValue],
        environmentVariables: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        utilityLibraries: [WorkspaceScriptUtility] = []
    ) async throws -> ExecutionOutcome {
        var executionLogs: [String] = []
        executionLogs.append("URL plantilla: \(request.url)")
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
                availableEnvironments: workspaceEnvironments,
                fallbackEnvironmentVariables: environmentVariables
            ),
            local: dictionaryAllowingDuplicateKeys(from: request.localVariables)
        )

        var urlRequest = try applyPreRequestScriptsAndBuildURLRequest(
            request: request,
            utilityLibraries: utilityLibraries,
            runtime: &runtime,
            executionLogs: &executionLogs
        )
        if request.isLambdaInvoke {
            if let arn = lambdaARNFromLambdaInvokeRequestURL(urlRequest.url) {
                executionLogs.append("Invoking AWS Lambda \(arn).")
            } else {
                executionLogs.append("Invoking AWS Lambda \(request.url).")
            }
        }
        var rawRequest = rawHTTPRepresentation(for: urlRequest)
        let transport = configuredTransport(for: request)
        executionLogs.append(contentsOf: transport.logs)

        let allowedRetries = max(0, request.retryOn206Count)
        var currentAttempt = 0
        var response: HTTPResponseModel!
        while true {
            currentAttempt += 1
            response = try await performSingleHTTPDataExchange(
                urlRequest,
                originalRequest: request,
                session: transport.session,
                delegate: transport.delegate
            )
            if response.statusCode == 206 && currentAttempt <= allowedRetries {
                executionLogs.append(
                    """
                    HTTP 206 received on attempt \(currentAttempt) of \(allowedRetries + 1). Retrying...
                    \(rawHTTPRepresentation(for: response))
                    """
                )
                let delayMs = request.retryOn206DelayMilliseconds
                if delayMs > 0 {
                    executionLogs.append("Waiting \(delayMs) ms before retrying after HTTP 206.")
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
                urlRequest = try applyPreRequestScriptsAndBuildURLRequest(
                    request: request,
                    utilityLibraries: utilityLibraries,
                    runtime: &runtime,
                    executionLogs: &executionLogs
                )
                rawRequest = rawHTTPRepresentation(for: urlRequest)
                continue
            }

            if response.statusCode == 206 && allowedRetries > 0 {
                executionLogs.append(
                    """
                    HTTP 206 received after exhausting \(allowedRetries) retries.
                    \(rawHTTPRepresentation(for: response))
                    """
                )
            }

            break
        }

        let rawResponse = rawHTTPRepresentation(for: response)

        runtime.response = response
        let testReport = scriptEngine.execute(
            scripts: request.scripts,
            event: .test,
            runtime: runtime,
            request: request,
            utilities: utilityLibraries
        )

        return ExecutionOutcome(
            response: response,
            rawRequest: rawRequest,
            rawResponse: rawResponse,
            updatedRequestHeaders: runtime.requestHeaders,
            updatedRequestQueryItems: runtime.requestQueryItems,
            updatedRequestBody: runtime.requestBody,
            updatedGlobals: dictionaryToVariables(testReport.runtime.globals),
            updatedCollection: dictionaryToVariables(testReport.runtime.collection),
            updatedEnvironment: dictionaryToVariables(testReport.runtime.environment),
            updatedEnvironments: testReport.runtime.environments,
            activeEnvironmentID: testReport.runtime.activeEnvironmentID,
            updatedLocal: dictionaryToKeyValues(testReport.runtime.local),
            logs: executionLogs + testReport.logs
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
        availableEnvironments: [EnvironmentProfile],
        fallbackEnvironmentVariables: [VariableValue]
    ) -> UUID? {
        if let requestedActiveEnvironmentID {
            return requestedActiveEnvironmentID
        }

        if let enabledEnvironment = availableEnvironments.first(where: \.isEnabled) {
            return enabledEnvironment.id
        }

        if !fallbackEnvironmentVariables.isEmpty {
            return availableEnvironments.first?.id ?? UUID()
        }

        return availableEnvironments.first?.id
    }

    private func applyPreRequestScriptsAndBuildURLRequest(
        request: APIRequestModel,
        utilityLibraries: [WorkspaceScriptUtility],
        runtime: inout ScriptRuntimeContext,
        executionLogs: inout [String]
    ) throws -> URLRequest {
        let preRequestReport = scriptEngine.execute(
            scripts: request.scripts,
            event: .preRequest,
            runtime: runtime,
            request: request,
            utilities: utilityLibraries
        )
        runtime = preRequestReport.runtime
        executionLogs.append(contentsOf: preRequestReport.logs)

        let variableContext = VariableResolutionContext(
            globals: dictionaryToVariables(runtime.globals),
            collection: dictionaryToVariables(runtime.collection),
            environment: dictionaryToVariables(runtime.environment),
            local: dictionaryToKeyValues(runtime.local)
        )

        let expressionState = ExpressionEvaluationState(runtime: runtime)
        let expressionEvaluator = makeExpressionEvaluator(
            state: expressionState,
            request: request,
            utilityLibraries: utilityLibraries
        )

        let urlRequest = try makeURLRequest(
            request: request,
            requestHeaders: runtime.requestHeaders,
            requestQueryItems: runtime.requestQueryItems,
            requestBody: runtime.requestBody,
            context: variableContext,
            expressionEvaluator: expressionEvaluator
        )
        runtime = expressionState.runtime
        executionLogs.append(contentsOf: expressionState.logs)
        return urlRequest
    }

    private func performSingleHTTPDataExchange(
        _ urlRequest: URLRequest,
        originalRequest: APIRequestModel,
        session: URLSession,
        delegate: RequestSessionDelegate
    ) async throws -> HTTPResponseModel {
        let startedAt = Date()
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await sessionDataRespectingFlowCancellation(for: urlRequest, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw AppError.network(describeNetworkError(error, for: urlRequest, delegate: delegate))
        }
        let duration = Date().timeIntervalSince(startedAt) * 1000

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppError.network("No se pudo interpretar la respuesta HTTP.")
        }

        let headers = httpResponse.allHeaderFields.compactMap { element -> KeyValueEntry? in
            guard let key = element.key as? String else { return nil }
            return KeyValueEntry(key: key, value: String(describing: element.value))
        }
        .sorted { lhs, rhs in
            lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }

        let body = ResponseFormatter.prettyBody(data: data, mimeType: httpResponse.mimeType)
        return HTTPResponseModel(
            url: urlRequest.url?.absoluteString ?? originalRequest.url,
            statusCode: httpResponse.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headers: headers,
            body: body,
            durationMilliseconds: duration,
            sizeBytes: data.count,
            mimeType: httpResponse.mimeType,
            suggestedDownloadFilename: httpResponse.suggestedFilename
        )
    }

    private func sessionDataRespectingFlowCancellation(
        for urlRequest: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let registry = WorkspaceFlowExecutionCancellationScope.activeRequestRegistry
        final class DataTaskSlot: @unchecked Sendable {
            var task: URLSessionDataTask?
        }
        let slot = DataTaskSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let dataTask = session.dataTask(with: urlRequest) { data, response, error in
                    if let task = slot.task {
                        registry?.unregisterHTTPDataTask(task)
                    }
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                slot.task = dataTask
                registry?.registerHTTPDataTask(dataTask)
                dataTask.resume()
            }
        } onCancel: {
            slot.task?.cancel()
        }
    }

    private func configuredTransport(for request: APIRequestModel) -> (session: URLSession, delegate: RequestSessionDelegate, logs: [String]) {
        let delegate = RequestSessionDelegate(allowInsecureTLS: request.tlsValidationMode == .insecure)
        let configuration = (session.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral

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

    private func describeNetworkError(_ error: Error, for request: URLRequest, delegate: RequestSessionDelegate) -> String {
        let host = request.url?.host ?? "unknown-host"
        let tlsDiagnostic = delegate.lastTLSDiagnostic

        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed:
                return [
                    """
                TLS/SSL handshake failed for \(host).
                Verify the server certificate chain, local proxy/VPN interception, and that the server supports modern TLS.
                Underlying error: \(urlError.localizedDescription)
                """,
                    tlsDiagnostic,
                ]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            case .serverCertificateHasBadDate:
                return joinErrorAndDiagnostic(
                    "The server certificate for \(host) has an invalid date. Check the server certificate validity and your Mac date/time.",
                    tlsDiagnostic
                )
            case .serverCertificateUntrusted:
                return joinErrorAndDiagnostic(
                    "The server certificate for \(host) is not trusted on this Mac.",
                    tlsDiagnostic
                )
            case .serverCertificateHasUnknownRoot:
                return joinErrorAndDiagnostic(
                    "The server certificate for \(host) was issued by an unknown root CA.",
                    tlsDiagnostic
                )
            case .serverCertificateNotYetValid:
                return joinErrorAndDiagnostic(
                    "The server certificate for \(host) is not valid yet.",
                    tlsDiagnostic
                )
            case .clientCertificateRejected:
                return joinErrorAndDiagnostic(
                    "The server rejected the client certificate for \(host).",
                    tlsDiagnostic
                )
            case .clientCertificateRequired:
                return joinErrorAndDiagnostic(
                    "The server \(host) requires a client certificate (mTLS).",
                    tlsDiagnostic
                )
            case .cannotFindHost:
                return "The host \(host) could not be found."
            case .cannotConnectToHost:
                return "Unable to connect to \(host). Check network connectivity, firewall, proxy, or VPN."
            case .timedOut:
                return "The request to \(host) timed out."
            default:
                return joinErrorAndDiagnostic(urlError.localizedDescription, tlsDiagnostic)
            }
        }

        return joinErrorAndDiagnostic(error.localizedDescription, tlsDiagnostic)
    }

    private func joinErrorAndDiagnostic(_ message: String, _ diagnostic: String?) -> String {
        [message, diagnostic]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private func makeURLRequest(
        request: APIRequestModel,
        requestHeaders: [KeyValueEntry]? = nil,
        requestQueryItems: [KeyValueEntry]? = nil,
        requestBody: RequestBodyModel? = nil,
        context: VariableResolutionContext,
        expressionEvaluator: @escaping (String, VariableResolutionContext) -> String?
    ) throws -> URLRequest {
        if request.isLambdaInvoke {
            return try makeLambdaInvokeRequest(
                request: request,
                requestHeaders: requestHeaders,
                requestQueryItems: requestQueryItems,
                requestBody: requestBody,
                context: context,
                expressionEvaluator: expressionEvaluator
            )
        }

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
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeoutSeconds

        let headers = requestHeaders ?? request.headers
        headers.filter(\.isEnabled).forEach { header in
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

        apply(auth: request.auth, to: &urlRequest, context: context, expressionEvaluator: expressionEvaluator)
        try applyBody(
            for: request,
            requestBody: requestBody,
            to: &urlRequest,
            context: context,
            expressionEvaluator: expressionEvaluator
        )
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

    private func applyBody(
        for request: APIRequestModel,
        requestBody: RequestBodyModel? = nil,
        to urlRequest: inout URLRequest,
        context: VariableResolutionContext,
        expressionEvaluator: @escaping (String, VariableResolutionContext) -> String?
    ) throws {
        let effectiveBody = requestBody ?? request.body

        switch effectiveBody.kind {
        case .none:
            return
        case .raw:
            let body = resolver.resolve(effectiveBody.raw, context: context, expressionEvaluator: expressionEvaluator)
            urlRequest.httpBody = Data(body.utf8)
        case .json:
            let body = resolver.resolve(effectiveBody.raw, context: context, expressionEvaluator: expressionEvaluator)
            urlRequest.httpBody = Data(body.utf8)
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        case .urlEncoded:
            let query = effectiveBody.parameters
                .filter(\.isEnabled)
                .map {
                    let value = resolver.resolve($0.value, context: context, expressionEvaluator: expressionEvaluator)
                    return "\(percentEncode($0.key))=\(percentEncode(value))"
                }
                .joined(separator: "&")
            urlRequest.httpBody = Data(query.utf8)
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .formData:
            let boundary = "Boundary-\(UUID().uuidString)"
            var body = Data()

            for parameter in effectiveBody.parameters where parameter.isEnabled {
                let value = resolver.resolve(parameter.value, context: context, expressionEvaluator: expressionEvaluator)
                body.append(Data("--\(boundary)\r\n".utf8))
                body.append(Data("Content-Disposition: form-data; name=\"\(parameter.key)\"\r\n\r\n".utf8))
                body.append(Data("\(value)\r\n".utf8))
            }

            body.append(Data("--\(boundary)--\r\n".utf8))
            urlRequest.httpBody = body
            urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
    }

    private func makeExpressionEvaluator(
        state: ExpressionEvaluationState,
        request: APIRequestModel,
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

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// Extrae el ARN ya resuelto (tras placeholders y pre-request) de la URL de invocación de Lambda.
    private func lambdaARNFromLambdaInvokeRequestURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        let path = url.path
        let prefix = "/2015-03-31/functions/"
        let suffix = "/invocations"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let inner = path.dropFirst(prefix.count).dropLast(suffix.count)
        let raw = String(inner)
        return raw.removingPercentEncoding ?? raw
    }

    private func makeLambdaInvokeRequest(
        request: APIRequestModel,
        requestHeaders: [KeyValueEntry]? = nil,
        requestQueryItems: [KeyValueEntry]? = nil,
        requestBody: RequestBodyModel? = nil,
        context: VariableResolutionContext,
        expressionEvaluator: @escaping (String, VariableResolutionContext) -> String?
    ) throws -> URLRequest {
        let resolvedARN = resolver.resolve(request.url, context: context, expressionEvaluator: expressionEvaluator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedARN.isEmpty else {
            throw AppError.invalidDocument("Lambda ARN is required for Invoke Lambda.")
        }

        let region = try parseLambdaRegion(from: resolvedARN)
        let encodedARN = percentEncodePathComponent(resolvedARN)
        guard var components = URLComponents(
            string: "https://lambda.\(region).amazonaws.com/2015-03-31/functions/\(encodedARN)/invocations"
        ) else {
            throw AppError.invalidURL("No se pudo construir la URL de Lambda para la region \(region).")
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
            components.queryItems = queryItems
        }

        guard let finalURL = components.url else {
            throw AppError.invalidURL("No se pudo construir la URL final para invocar \(resolvedARN).")
        }

        var urlRequest = URLRequest(url: finalURL)
        urlRequest.httpMethod = HTTPMethod.post.rawValue
        urlRequest.timeoutInterval = request.timeoutSeconds

        let headers = requestHeaders ?? request.headers
        headers.filter(\.isEnabled).forEach { header in
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

        try applyBody(
            for: request,
            requestBody: requestBody,
            to: &urlRequest,
            context: context,
            expressionEvaluator: expressionEvaluator
        )

        let credentialsBlock = resolver.resolve(
            request.auth.token,
            context: context,
            expressionEvaluator: expressionEvaluator
        )
        let credentials = try parseTemporaryAWSCredentials(from: credentialsBlock)
        try signLambdaInvokeRequest(&urlRequest, region: region, credentials: credentials)
        return urlRequest
    }

    private func parseLambdaRegion(from arn: String) throws -> String {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "arn", parts[2] == "lambda" else {
            throw AppError.invalidDocument("Lambda ARN invalido: \(arn)")
        }

        let region = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else {
            throw AppError.invalidDocument("No se pudo obtener la region desde el ARN de Lambda.")
        }
        return region
    }

    private func parseTemporaryAWSCredentials(from rawValue: String) throws -> AWSTemporaryCredentials {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidDocument("AWS credentials are required for Invoke Lambda.")
        }

        var accessKeyID: String?
        var secretAccessKey: String?
        var sessionToken: String?

        for line in trimmed.components(separatedBy: .newlines) {
            let sanitizedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedLine.isEmpty, !sanitizedLine.hasPrefix("[") else {
                continue
            }

            let assignmentLine = Self.lineAfterOptionalExportPrefix(sanitizedLine)
            let parts = assignmentLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = Self.unquoteCredentialValue(String(parts[1]))

            switch key {
            case "aws_access_key_id", "AWS_ACCESS_KEY_ID":
                accessKeyID = value
            case "aws_secret_access_key", "AWS_SECRET_ACCESS_KEY":
                secretAccessKey = value
            case "aws_session_token", "AWS_SESSION_TOKEN":
                sessionToken = value
            default:
                continue
            }
        }

        guard let accessKeyID, !accessKeyID.isEmpty else {
            throw AppError.invalidDocument(
                "Missing AWS access key (aws_access_key_id or AWS_ACCESS_KEY_ID)."
            )
        }
        guard let secretAccessKey, !secretAccessKey.isEmpty else {
            throw AppError.invalidDocument(
                "Missing AWS secret key (aws_secret_access_key or AWS_SECRET_ACCESS_KEY)."
            )
        }
        guard let sessionToken, !sessionToken.isEmpty else {
            throw AppError.invalidDocument(
                "Missing AWS session token (aws_session_token or AWS_SESSION_TOKEN)."
            )
        }

        return AWSTemporaryCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }

    /// Strips a leading `export` shell keyword so the same parser accepts INI-style and `export VAR=value` pastes.
    private static func lineAfterOptionalExportPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"^export\s+"#, options: [.regularExpression, .caseInsensitive]) else {
            return trimmed
        }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unquoteCredentialValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(";") {
            value = String(value.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.count >= 2 else {
            return value
        }
        let first = value.first!
        let last = value.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func signLambdaInvokeRequest(
        _ request: inout URLRequest,
        region: String,
        credentials: AWSTemporaryCredentials,
        now: Date = Date()
    ) throws {
        guard let url = request.url else {
            throw AppError.invalidURL("No se pudo firmar la invocacion Lambda porque la URL final es invalida.")
        }

        let amzDate = awsTimestamp.string(from: now)
        let dateStamp = awsDateStamp.string(from: now)
        let payloadHash = sha256Hex(request.httpBody ?? Data())
        request.setValue(url.host ?? "", forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(credentials.sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        let canonicalRequest = canonicalRequestString(for: request, payloadHash: payloadHash)
        let credentialScope = "\(dateStamp)/\(region)/\(lambdaInvokeService)/aws4_request"
        let stringToSign = [
            lambdaInvokeAlgorithm,
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = awsSigningKey(
            secretAccessKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: lambdaInvokeService
        )
        let signature = hexString(hmacSHA256(Data(stringToSign.utf8), key: signingKey))
        let signedHeaders = signedHeadersString(for: request)
        let authorizationHeader = "\(lambdaInvokeAlgorithm) Credential=\(credentials.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }

    /// SigV4 requires the canonical URI path to double-encode percent signs (e.g. `%3A` → `%253A`).
    /// The wire URL stays single-encoded; only the string-to-sign uses this path.
    /// See https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
    private func awsCanonicalURIPathForSigning(percentEncodedPath: String) -> String {
        let path = percentEncodedPath.isEmpty ? "/" : percentEncodedPath
        if path == "/" {
            return "/"
        }
        return path.replacingOccurrences(of: "%", with: "%25")
    }

    private func canonicalRequestString(for request: URLRequest, payloadHash: String) -> String {
        let method = request.httpMethod ?? HTTPMethod.post.rawValue
        let percentEncodedPath = URLComponents(
            url: request.url ?? URL(string: "about:blank")!,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath ?? ""
        let canonicalURI = awsCanonicalURIPathForSigning(percentEncodedPath: percentEncodedPath)
        let canonicalQuery = canonicalQueryString(for: request.url)
        let canonicalHeaders = canonicalHeadersString(for: request)
        let signedHeaders = signedHeadersString(for: request)

        return [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
    }

    private func canonicalQueryString(for url: URL?) -> String {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              !items.isEmpty else {
            return ""
        }

        return items
            .map { item in
                let name = percentEncodeAWSQueryComponent(item.name)
                let value = percentEncodeAWSQueryComponent(item.value ?? "")
                return (name: name, value: value)
            }
            .sorted {
                if $0.name == $1.name {
                    return $0.value < $1.value
                }
                return $0.name < $1.name
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "&")
    }

    private func canonicalHeadersString(for request: URLRequest) -> String {
        let headers = canonicalHeaderEntries(for: request)
        return headers
            .map { "\($0.name):\($0.value)\n" }
            .joined()
    }

    private func signedHeadersString(for request: URLRequest) -> String {
        canonicalHeaderEntries(for: request)
            .map(\.name)
            .joined(separator: ";")
    }

    private func canonicalHeaderEntries(for request: URLRequest) -> [(name: String, value: String)] {
        var headers = request.allHTTPHeaderFields ?? [:]
        if headers["Host"] == nil, let host = request.url?.host {
            headers["Host"] = host
        }

        return headers
            .filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
            .map { key, value in
                (
                    name: key.lowercased(),
                    value: normalizedAWSHeaderValue(value)
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func normalizedAWSHeaderValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func percentEncodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func percentEncodeAWSQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func sha256Hex(_ data: Data) -> String {
        hexString(Data(SHA256.hash(data: data)))
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(_ data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(authenticationCode)
    }

    private func awsSigningKey(secretAccessKey: String, dateStamp: String, region: String, service: String) -> Data {
        let secret = Data(("AWS4" + secretAccessKey).utf8)
        let dateKey = hmacSHA256(Data(dateStamp.utf8), key: secret)
        let regionKey = hmacSHA256(Data(region.utf8), key: dateKey)
        let serviceKey = hmacSHA256(Data(service.utf8), key: regionKey)
        return hmacSHA256(Data("aws4_request".utf8), key: serviceKey)
    }

    private var awsTimestamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }

    private var awsDateStamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
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

        if let body = request.httpBody, !body.isEmpty {
            lines.append("")
            lines.append(String(data: body, encoding: .utf8) ?? body.base64EncodedString())
        }

        return lines.joined(separator: "\n")
    }

    private func rawHTTPRepresentation(for response: HTTPResponseModel) -> String {
        var lines = ["HTTP/1.1 \(response.statusCode) \(response.statusText)"]

        for header in response.headers {
            lines.append("\(header.key): \(header.value)")
        }

        if !response.body.isEmpty {
            lines.append("")
            lines.append(response.body)
        }

        return lines.joined(separator: "\n")
    }
}

public enum ResponseFormatter {
    public static func prettyBody(data: Data, mimeType: String?) -> String {
        guard !data.isEmpty else {
            return ""
        }

        if let mimeType, mimeType.contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }

        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        return data.base64EncodedString()
    }
}

private struct AWSTemporaryCredentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String
}
