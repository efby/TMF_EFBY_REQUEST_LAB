import Combine
import EfbyApplication
import EfbyDomain
import Foundation

@MainActor
public final class RequestTabState: ObservableObject, Identifiable {
    public let id: UUID
    @Published public var request: APIRequestModel
    @Published public var response: HTTPResponseModel?
    @Published public var rawRequestText: String?
    @Published public var rawResponseText: String?
    @Published public var consoleLogs: [String]
    @Published public var webSocketTranscript: [WebSocketTranscriptEntry]
    @Published public var webSocketPingSentCount: Int
    @Published public var webSocketLastPingSentAt: Date?
    @Published public var webSocketConnectionState: WebSocketConnectionState
    @Published public var isSending: Bool
    @Published public var selectedEnvironmentID: UUID?
    @Published public var pendingEnvironmentVariables: [VariableValue]?
    @Published public var editorRefreshToken: UUID
    @Published public var requestEditorSelectedTabRawValue: String
    @Published public var requestEditorScrollOffsets: [String: Double]
    @Published public var requestScriptsSelectedPanelRawValue: String

    public var persistedRequest: APIRequestModel
    public var persistedSelectedEnvironmentID: UUID?
    public var persistedEnvironmentVariables: [VariableValue]?

    public var sourceCollectionID: UUID?
    public var sourceNodeID: UUID?
    public var task: Task<Void, Never>?
    public var webSocketReceiveTask: Task<Void, Never>?
    public var webSocketPingTask: Task<Void, Never>?
    public var webSocketKeepAliveTask: Task<Void, Never>?
    public var webSocketConnection: (any WebSocketConnectionProtocol)?
    public var webSocketReconnectAttempt: Int = 0

    public init(
        id: UUID = UUID(),
        request: APIRequestModel,
        response: HTTPResponseModel? = nil,
        rawRequestText: String? = nil,
        rawResponseText: String? = nil,
        consoleLogs: [String] = [],
        webSocketTranscript: [WebSocketTranscriptEntry] = [],
        webSocketPingSentCount: Int = 0,
        webSocketLastPingSentAt: Date? = nil,
        webSocketConnectionState: WebSocketConnectionState = .disconnected,
        isSending: Bool = false,
        selectedEnvironmentID: UUID? = nil,
        pendingEnvironmentVariables: [VariableValue]? = nil,
        editorRefreshToken: UUID = UUID(),
        requestEditorSelectedTabRawValue: String = "Body",
        requestEditorScrollOffsets: [String: Double] = [:],
        requestScriptsSelectedPanelRawValue: String = "preRequest",
        persistedRequest: APIRequestModel? = nil,
        persistedSelectedEnvironmentID: UUID? = nil,
        persistedEnvironmentVariables: [VariableValue]? = nil,
        sourceCollectionID: UUID? = nil,
        sourceNodeID: UUID? = nil
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.rawRequestText = rawRequestText
        self.rawResponseText = rawResponseText
        self.consoleLogs = consoleLogs
        self.webSocketTranscript = webSocketTranscript
        self.webSocketPingSentCount = webSocketPingSentCount
        self.webSocketLastPingSentAt = webSocketLastPingSentAt
        self.webSocketConnectionState = webSocketConnectionState
        self.isSending = isSending
        self.selectedEnvironmentID = selectedEnvironmentID
        self.pendingEnvironmentVariables = pendingEnvironmentVariables
        self.editorRefreshToken = editorRefreshToken
        self.requestEditorSelectedTabRawValue = requestEditorSelectedTabRawValue
        self.requestEditorScrollOffsets = requestEditorScrollOffsets
        self.requestScriptsSelectedPanelRawValue = requestScriptsSelectedPanelRawValue
        self.persistedRequest = persistedRequest ?? request
        self.persistedSelectedEnvironmentID = persistedSelectedEnvironmentID ?? selectedEnvironmentID
        self.persistedEnvironmentVariables = persistedEnvironmentVariables ?? pendingEnvironmentVariables
        self.sourceCollectionID = sourceCollectionID
        self.sourceNodeID = sourceNodeID
    }

    deinit {
        task?.cancel()
        webSocketReceiveTask?.cancel()
        webSocketPingTask?.cancel()
        webSocketKeepAliveTask?.cancel()
    }
}
