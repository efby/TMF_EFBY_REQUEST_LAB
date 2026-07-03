import Foundation

public enum TLSValidationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case strict
    case insecure

    public var displayName: String {
        switch self {
        case .strict:
            return "Strict"
        case .insecure:
            return "Allow Insecure"
        }
    }
}

public enum TLSMinimumVersionOption: String, Codable, CaseIterable, Hashable, Sendable {
    case systemDefault
    case tls10
    case tls11
    case tls12

    public var displayName: String {
        switch self {
        case .systemDefault:
            return "System Default"
        case .tls10:
            return "TLS 1.0"
        case .tls11:
            return "TLS 1.1"
        case .tls12:
            return "TLS 1.2"
        }
    }
}

public enum HTTPMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
}

public enum RequestTransportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case http
    case webSocket
    case invokeLambda

    public var displayName: String {
        switch self {
        case .http:
            return "HTTP"
        case .webSocket:
            return "WebSocket"
        case .invokeLambda:
            return "Invoke Lambda"
        }
    }
}

public enum HTTPRequestTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case url
    case invokeLambda

    public var displayName: String {
        switch self {
        case .url:
            return "URL"
        case .invokeLambda:
            return "Invoke Lambda"
        }
    }
}

public struct KeyValueEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        key: String = "",
        value: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }
}

public enum RequestBodyKind: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case raw
    case json
    case urlEncoded
    case formData
}

public struct RequestBodyModel: Codable, Hashable, Sendable {
    public var kind: RequestBodyKind
    public var raw: String
    public var parameters: [KeyValueEntry]

    public init(
        kind: RequestBodyKind = .none,
        raw: String = "",
        parameters: [KeyValueEntry] = []
    ) {
        self.kind = kind
        self.raw = raw
        self.parameters = parameters
    }
}

public enum AuthType: String, Codable, CaseIterable, Hashable, Sendable {
    case noAuth
    case basic
    case bearer
    case apiKey
    case oauth2
    case awsTemporaryCredentials

    public var displayName: String {
        switch self {
        case .noAuth:
            return "No Auth"
        case .basic:
            return "Basic"
        case .bearer:
            return "Bearer"
        case .apiKey:
            return "API Key"
        case .oauth2:
            return "OAuth 2"
        case .awsTemporaryCredentials:
            return "AWS Temporary Credentials"
        }
    }
}

public struct AuthConfiguration: Codable, Hashable, Sendable {
    public var type: AuthType
    public var username: String
    public var password: String
    public var token: String
    public var key: String
    public var value: String
    public var addTo: APIKeyPlacement
    public var accessTokenURL: String
    public var clientID: String
    public var clientSecret: String
    public var scopes: String

    public init(
        type: AuthType = .noAuth,
        username: String = "",
        password: String = "",
        token: String = "",
        key: String = "",
        value: String = "",
        addTo: APIKeyPlacement = .header,
        accessTokenURL: String = "",
        clientID: String = "",
        clientSecret: String = "",
        scopes: String = ""
    ) {
        self.type = type
        self.username = username
        self.password = password
        self.token = token
        self.key = key
        self.value = value
        self.addTo = addTo
        self.accessTokenURL = accessTokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }
}

public enum APIKeyPlacement: String, Codable, CaseIterable, Hashable, Sendable {
    case header
    case query
}

public enum ScriptEventType: String, Codable, CaseIterable, Hashable, Sendable {
    case preRequest = "prerequest"
    case test
}

public struct ScriptDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var listen: ScriptEventType
    public var language: String
    public var source: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        listen: ScriptEventType,
        language: String = "mini",
        source: String = ""
    ) {
        self.id = id
        self.name = name
        self.listen = listen
        self.language = language
        self.source = source
    }
}

public struct APIRequestModel: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var transportKind: RequestTransportKind
    public var httpRequestTargetKind: HTTPRequestTargetKind?
    public var method: HTTPMethod
    public var url: String
    public var queryItems: [KeyValueEntry]
    public var pathVariables: [KeyValueEntry]
    public var headers: [KeyValueEntry]
    public var cookies: [KeyValueEntry]
    public var auth: AuthConfiguration
    public var body: RequestBodyModel
    public var scripts: [ScriptDefinition]
    public var localVariables: [KeyValueEntry]
    public var timeoutSeconds: Double
    public var retryOn206Count: Int
    /// Milliseconds to wait after an HTTP 206 before rebuilding the request (pre-request) and retrying.
    public var retryOn206DelayMilliseconds: Int
    public var tlsValidationMode: TLSValidationMode
    public var minimumTLSVersion: TLSMinimumVersionOption
    public var webSocketSubprotocols: String
    public var webSocketOpenTimeoutSeconds: Double
    public var webSocketReconnectAttempts: Int
    public var webSocketReconnectIntervalMilliseconds: Int
    public var webSocketMaximumMessageSizeMB: Int
    public var webSocketPingIntervalSeconds: Double
    public var webSocketKeepAliveMessage: String
    public var webSocketKeepAliveIntervalSeconds: Double
    /// URL del portal AWS (sesión web / ASWeb). Puede incluir `{{variable}}`; se resuelve al abrir el panel.
    public var awsAccessPortalURLTemplate: String

    public init(
        id: UUID = UUID(),
        name: String = "Untitled Request",
        transportKind: RequestTransportKind = .http,
        httpRequestTargetKind: HTTPRequestTargetKind? = nil,
        method: HTTPMethod = .get,
        url: String = "",
        queryItems: [KeyValueEntry] = [],
        pathVariables: [KeyValueEntry] = [],
        headers: [KeyValueEntry] = [],
        cookies: [KeyValueEntry] = [],
        auth: AuthConfiguration = AuthConfiguration(),
        body: RequestBodyModel = RequestBodyModel(),
        scripts: [ScriptDefinition] = [],
        localVariables: [KeyValueEntry] = [],
        timeoutSeconds: Double = 30,
        retryOn206Count: Int = 5,
        retryOn206DelayMilliseconds: Int = 0,
        tlsValidationMode: TLSValidationMode = .strict,
        minimumTLSVersion: TLSMinimumVersionOption = .systemDefault,
        webSocketSubprotocols: String = "",
        webSocketOpenTimeoutSeconds: Double = 0,
        webSocketReconnectAttempts: Int = 0,
        webSocketReconnectIntervalMilliseconds: Int = 0,
        webSocketMaximumMessageSizeMB: Int = 0,
        webSocketPingIntervalSeconds: Double = 0,
        webSocketKeepAliveMessage: String = "",
        webSocketKeepAliveIntervalSeconds: Double = 0,
        awsAccessPortalURLTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.transportKind = transportKind
        self.httpRequestTargetKind = httpRequestTargetKind
        self.method = method
        self.url = url
        self.queryItems = queryItems
        self.pathVariables = pathVariables
        self.headers = headers
        self.cookies = cookies
        self.auth = auth
        self.body = body
        self.scripts = scripts
        self.localVariables = localVariables
        self.timeoutSeconds = timeoutSeconds
        self.retryOn206Count = retryOn206Count
        self.retryOn206DelayMilliseconds = max(0, retryOn206DelayMilliseconds)
        self.tlsValidationMode = tlsValidationMode
        self.minimumTLSVersion = minimumTLSVersion
        self.webSocketSubprotocols = webSocketSubprotocols
        self.webSocketOpenTimeoutSeconds = webSocketOpenTimeoutSeconds
        self.webSocketReconnectAttempts = max(0, webSocketReconnectAttempts)
        self.webSocketReconnectIntervalMilliseconds = max(0, webSocketReconnectIntervalMilliseconds)
        self.webSocketMaximumMessageSizeMB = max(0, webSocketMaximumMessageSizeMB)
        self.webSocketPingIntervalSeconds = webSocketPingIntervalSeconds
        self.webSocketKeepAliveMessage = webSocketKeepAliveMessage
        self.webSocketKeepAliveIntervalSeconds = webSocketKeepAliveIntervalSeconds
        self.awsAccessPortalURLTemplate = awsAccessPortalURLTemplate
    }

    public var effectiveHTTPRequestTargetKind: HTTPRequestTargetKind {
        if transportKind == .invokeLambda {
            return .invokeLambda
        }
        return httpRequestTargetKind ?? .url
    }

    /// True for Lambda invoke (top-level transport or legacy HTTP + target kind).
    public var isLambdaInvoke: Bool {
        transportKind == .invokeLambda
            || (transportKind == .http && httpRequestTargetKind == .invokeLambda)
    }

    /// Uses the HTTP request executor (URL/Lambda), not the WebSocket client.
    public var usesHTTPTransport: Bool {
        transportKind == .http || transportKind == .invokeLambda
    }
}

extension APIRequestModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case transportKind
        case httpRequestTargetKind
        case method
        case url
        case queryItems
        case pathVariables
        case headers
        case cookies
        case auth
        case body
        case scripts
        case localVariables
        case timeoutSeconds
        case retryOn206Count
        case retryOn206DelayMilliseconds
        case tlsValidationMode
        case minimumTLSVersion
        case webSocketSubprotocols
        case webSocketOpenTimeoutSeconds
        case webSocketReconnectAttempts
        case webSocketReconnectIntervalMilliseconds
        case webSocketMaximumMessageSizeMB
        case webSocketPingIntervalSeconds
        case webSocketKeepAliveMessage
        case webSocketKeepAliveIntervalSeconds
        case awsAccessPortalURLTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        transportKind = try container.decode(RequestTransportKind.self, forKey: .transportKind)
        httpRequestTargetKind = try container.decodeIfPresent(HTTPRequestTargetKind.self, forKey: .httpRequestTargetKind)
        method = try container.decode(HTTPMethod.self, forKey: .method)
        url = try container.decode(String.self, forKey: .url)
        queryItems = try container.decodeIfPresent([KeyValueEntry].self, forKey: .queryItems) ?? []
        pathVariables = try container.decodeIfPresent([KeyValueEntry].self, forKey: .pathVariables) ?? []
        headers = try container.decodeIfPresent([KeyValueEntry].self, forKey: .headers) ?? []
        cookies = try container.decodeIfPresent([KeyValueEntry].self, forKey: .cookies) ?? []
        auth = try container.decodeIfPresent(AuthConfiguration.self, forKey: .auth) ?? AuthConfiguration()
        body = try container.decodeIfPresent(RequestBodyModel.self, forKey: .body) ?? RequestBodyModel()
        scripts = try container.decodeIfPresent([ScriptDefinition].self, forKey: .scripts) ?? []
        localVariables = try container.decodeIfPresent([KeyValueEntry].self, forKey: .localVariables) ?? []
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        retryOn206Count = try container.decodeIfPresent(Int.self, forKey: .retryOn206Count) ?? 5
        retryOn206DelayMilliseconds = max(0, try container.decodeIfPresent(Int.self, forKey: .retryOn206DelayMilliseconds) ?? 0)
        tlsValidationMode = try container.decodeIfPresent(TLSValidationMode.self, forKey: .tlsValidationMode) ?? .strict
        minimumTLSVersion = try container.decodeIfPresent(TLSMinimumVersionOption.self, forKey: .minimumTLSVersion) ?? .systemDefault
        webSocketSubprotocols = try container.decodeIfPresent(String.self, forKey: .webSocketSubprotocols) ?? ""
        webSocketOpenTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .webSocketOpenTimeoutSeconds) ?? 0
        webSocketReconnectAttempts = max(0, try container.decodeIfPresent(Int.self, forKey: .webSocketReconnectAttempts) ?? 0)
        webSocketReconnectIntervalMilliseconds = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .webSocketReconnectIntervalMilliseconds) ?? 0
        )
        webSocketMaximumMessageSizeMB = max(0, try container.decodeIfPresent(Int.self, forKey: .webSocketMaximumMessageSizeMB) ?? 0)
        webSocketPingIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .webSocketPingIntervalSeconds) ?? 0
        webSocketKeepAliveMessage = try container.decodeIfPresent(String.self, forKey: .webSocketKeepAliveMessage) ?? ""
        webSocketKeepAliveIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .webSocketKeepAliveIntervalSeconds) ?? 0
        awsAccessPortalURLTemplate = try container.decodeIfPresent(String.self, forKey: .awsAccessPortalURLTemplate) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(transportKind, forKey: .transportKind)
        try container.encodeIfPresent(httpRequestTargetKind, forKey: .httpRequestTargetKind)
        try container.encode(method, forKey: .method)
        try container.encode(url, forKey: .url)
        try container.encode(queryItems, forKey: .queryItems)
        try container.encode(pathVariables, forKey: .pathVariables)
        try container.encode(headers, forKey: .headers)
        try container.encode(cookies, forKey: .cookies)
        try container.encode(auth, forKey: .auth)
        try container.encode(body, forKey: .body)
        try container.encode(scripts, forKey: .scripts)
        try container.encode(localVariables, forKey: .localVariables)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(retryOn206Count, forKey: .retryOn206Count)
        try container.encode(retryOn206DelayMilliseconds, forKey: .retryOn206DelayMilliseconds)
        try container.encode(tlsValidationMode, forKey: .tlsValidationMode)
        try container.encode(minimumTLSVersion, forKey: .minimumTLSVersion)
        try container.encode(webSocketSubprotocols, forKey: .webSocketSubprotocols)
        try container.encode(webSocketOpenTimeoutSeconds, forKey: .webSocketOpenTimeoutSeconds)
        try container.encode(webSocketReconnectAttempts, forKey: .webSocketReconnectAttempts)
        try container.encode(webSocketReconnectIntervalMilliseconds, forKey: .webSocketReconnectIntervalMilliseconds)
        try container.encode(webSocketMaximumMessageSizeMB, forKey: .webSocketMaximumMessageSizeMB)
        try container.encode(webSocketPingIntervalSeconds, forKey: .webSocketPingIntervalSeconds)
        try container.encode(webSocketKeepAliveMessage, forKey: .webSocketKeepAliveMessage)
        try container.encode(webSocketKeepAliveIntervalSeconds, forKey: .webSocketKeepAliveIntervalSeconds)
        try container.encode(awsAccessPortalURLTemplate, forKey: .awsAccessPortalURLTemplate)
    }
}

public struct HTTPResponseModel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: String
    public var statusCode: Int
    public var statusText: String
    public var headers: [KeyValueEntry]
    public var body: String
    public var durationMilliseconds: Double
    public var sizeBytes: Int
    public var mimeType: String?
    public var receivedAt: Date
    public var suggestedDownloadFilename: String?

    public init(
        id: UUID = UUID(),
        url: String,
        statusCode: Int,
        statusText: String,
        headers: [KeyValueEntry],
        body: String,
        durationMilliseconds: Double,
        sizeBytes: Int,
        mimeType: String?,
        receivedAt: Date = Date(),
        suggestedDownloadFilename: String? = nil
    ) {
        self.id = id
        self.url = url
        self.statusCode = statusCode
        self.statusText = statusText
        self.headers = headers
        self.body = body
        self.durationMilliseconds = durationMilliseconds
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.receivedAt = receivedAt
        self.suggestedDownloadFilename = suggestedDownloadFilename
    }
}

public enum WebSocketConnectionState: String, Codable, Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed

    public var displayName: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting"
        case .failed:
            return "Failed"
        }
    }
}

public enum WebSocketTranscriptDirection: String, Codable, Hashable, Sendable {
    case incoming
    case outgoing
    case system
}

public struct WebSocketTranscriptEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var direction: WebSocketTranscriptDirection
    public var body: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        direction: WebSocketTranscriptDirection,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.body = body
        self.createdAt = createdAt
    }
}

public struct SavedResponseModel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var statusCode: Int
    public var headers: [KeyValueEntry]
    public var body: String

    public init(
        id: UUID = UUID(),
        name: String,
        statusCode: Int,
        headers: [KeyValueEntry] = [],
        body: String = ""
    ) {
        self.id = id
        self.name = name
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}
