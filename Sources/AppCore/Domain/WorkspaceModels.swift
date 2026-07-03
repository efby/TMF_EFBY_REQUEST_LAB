import Foundation

public enum PostmanSchemaVersion: String, Codable, Hashable, Sendable {
    case v2
    case v21
    case unknown

    public var schemaURL: String {
        switch self {
        case .v2:
            return "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"
        case .v21:
            return "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
        case .unknown:
            return "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
        }
    }
}

public enum CollectionSourceFormat: String, Codable, Hashable, Sendable {
    case native
    case postmanV2
    case postmanV21
    case openAPI30
    case openAPI31
}

public struct VariableValue: Identifiable, Codable, Hashable, Sendable {
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

public struct EnvironmentProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var variables: [VariableValue]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        variables: [VariableValue] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.variables = variables
        self.isEnabled = isEnabled
    }
}

public struct CollectionInfoModel: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var schemaVersion: PostmanSchemaVersion

    public init(
        name: String,
        description: String = "",
        schemaVersion: PostmanSchemaVersion = .v21
    ) {
        self.name = name
        self.description = description
        self.schemaVersion = schemaVersion
    }
}

public enum CollectionNodeKind: String, Codable, Hashable, Sendable {
    case folder
    case request
}

public struct CollectionNode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: CollectionNodeKind
    public var request: APIRequestModel?
    public var responses: [SavedResponseModel]
    public var scripts: [ScriptDefinition]
    public var auth: AuthConfiguration
    public var nodeDescription: String
    public var children: [CollectionNode]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: CollectionNodeKind,
        request: APIRequestModel? = nil,
        responses: [SavedResponseModel] = [],
        scripts: [ScriptDefinition] = [],
        auth: AuthConfiguration = AuthConfiguration(),
        nodeDescription: String = "",
        children: [CollectionNode] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.request = request
        self.responses = responses
        self.scripts = scripts
        self.auth = auth
        self.nodeDescription = nodeDescription
        self.children = children
    }
}

public struct CollectionModel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var info: CollectionInfoModel
    public var variables: [VariableValue]
    public var auth: AuthConfiguration
    public var scripts: [ScriptDefinition]
    public var items: [CollectionNode]
    public var sourceFormat: CollectionSourceFormat

    public init(
        id: UUID = UUID(),
        info: CollectionInfoModel,
        variables: [VariableValue] = [],
        auth: AuthConfiguration = AuthConfiguration(),
        scripts: [ScriptDefinition] = [],
        items: [CollectionNode] = [],
        sourceFormat: CollectionSourceFormat = .native
    ) {
        self.id = id
        self.info = info
        self.variables = variables
        self.auth = auth
        self.scripts = scripts
        self.items = items
        self.sourceFormat = sourceFormat
    }
}

public struct WorkspaceScriptUtility: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var language: String
    public var source: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        language: String = "javascript",
        source: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.source = source
        self.isEnabled = isEnabled
    }
}

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var request: APIRequestModel
    public var response: HTTPResponseModel?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        request: APIRequestModel,
        response: HTTPResponseModel?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.request = request
        self.response = response
    }
}

public struct RequestDraftState: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workspaceName: String
    public var tabID: UUID?
    public var collectionID: UUID?
    public var nodeID: UUID?
    public var request: APIRequestModel
    public var selectedEnvironmentID: UUID?
    public var pendingEnvironmentVariables: [VariableValue]?
    public var persistedRequest: APIRequestModel?
    public var persistedSelectedEnvironmentID: UUID?
    public var persistedEnvironmentVariables: [VariableValue]?

    public init(
        id: UUID = UUID(),
        workspaceName: String,
        tabID: UUID? = nil,
        collectionID: UUID? = nil,
        nodeID: UUID? = nil,
        request: APIRequestModel,
        selectedEnvironmentID: UUID? = nil,
        pendingEnvironmentVariables: [VariableValue]? = nil,
        persistedRequest: APIRequestModel? = nil,
        persistedSelectedEnvironmentID: UUID? = nil,
        persistedEnvironmentVariables: [VariableValue]? = nil
    ) {
        self.id = id
        self.workspaceName = workspaceName
        self.tabID = tabID
        self.collectionID = collectionID
        self.nodeID = nodeID
        self.request = request
        self.selectedEnvironmentID = selectedEnvironmentID
        self.pendingEnvironmentVariables = pendingEnvironmentVariables
        self.persistedRequest = persistedRequest
        self.persistedSelectedEnvironmentID = persistedSelectedEnvironmentID
        self.persistedEnvironmentVariables = persistedEnvironmentVariables
    }
}

public struct WorkspaceState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 7

    public var schemaVersion: Int
    public var sharedCollectionsDirectoryPath: String?
    public var sharedCollectionsDirectoryBookmarkData: Data?
    /// Última URL Bitbucket usada en el iPad (descarga / sincronización); no incluye el token.
    public var bitbucketPadCloneHTTPSURL: String?
    public var bitbucketPadBranch: String?
    public var bitbucketPadUsername: String?
    public var activeWorkspaceName: String?
    public var globalVariables: [VariableValue]
    public var collections: [CollectionModel]
    public var flows: [WorkspaceFlowDefinition]
    public var utilityLibraries: [WorkspaceScriptUtility]
    public var environments: [EnvironmentProfile]
    public var activeEnvironmentID: UUID?
    public var history: [HistoryEntry]
    public var requestDrafts: [RequestDraftState]

    public init(
        schemaVersion: Int = WorkspaceState.currentSchemaVersion,
        sharedCollectionsDirectoryPath: String? = nil,
        sharedCollectionsDirectoryBookmarkData: Data? = nil,
        bitbucketPadCloneHTTPSURL: String? = nil,
        bitbucketPadBranch: String? = nil,
        bitbucketPadUsername: String? = nil,
        activeWorkspaceName: String? = nil,
        globalVariables: [VariableValue] = [],
        collections: [CollectionModel] = [],
        flows: [WorkspaceFlowDefinition] = [],
        utilityLibraries: [WorkspaceScriptUtility] = [],
        environments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        history: [HistoryEntry] = [],
        requestDrafts: [RequestDraftState] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sharedCollectionsDirectoryPath = sharedCollectionsDirectoryPath
        self.sharedCollectionsDirectoryBookmarkData = sharedCollectionsDirectoryBookmarkData
        self.bitbucketPadCloneHTTPSURL = bitbucketPadCloneHTTPSURL
        self.bitbucketPadBranch = bitbucketPadBranch
        self.bitbucketPadUsername = bitbucketPadUsername
        self.activeWorkspaceName = activeWorkspaceName
        self.globalVariables = globalVariables
        self.collections = collections
        self.flows = flows
        self.utilityLibraries = utilityLibraries
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
        self.history = history
        self.requestDrafts = requestDrafts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sharedCollectionsDirectoryPath
        case sharedCollectionsDirectoryBookmarkData
        case bitbucketPadCloneHTTPSURL
        case bitbucketPadBranch
        case bitbucketPadUsername
        case activeWorkspaceName
        case globalVariables
        case collections
        case flows
        case utilityLibraries
        case environments
        case activeEnvironmentID
        case history
        case requestDrafts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sharedCollectionsDirectoryPath = try container.decodeIfPresent(String.self, forKey: .sharedCollectionsDirectoryPath)
        sharedCollectionsDirectoryBookmarkData = try container.decodeIfPresent(Data.self, forKey: .sharedCollectionsDirectoryBookmarkData)
        bitbucketPadCloneHTTPSURL = try container.decodeIfPresent(String.self, forKey: .bitbucketPadCloneHTTPSURL)
        bitbucketPadBranch = try container.decodeIfPresent(String.self, forKey: .bitbucketPadBranch)
        bitbucketPadUsername = try container.decodeIfPresent(String.self, forKey: .bitbucketPadUsername)
        activeWorkspaceName = try container.decodeIfPresent(String.self, forKey: .activeWorkspaceName)
        globalVariables = try container.decodeIfPresent([VariableValue].self, forKey: .globalVariables) ?? []
        collections = try container.decodeIfPresent([CollectionModel].self, forKey: .collections) ?? []
        flows = try container.decodeIfPresent([WorkspaceFlowDefinition].self, forKey: .flows) ?? []
        utilityLibraries = try container.decodeIfPresent([WorkspaceScriptUtility].self, forKey: .utilityLibraries) ?? []
        environments = try container.decodeIfPresent([EnvironmentProfile].self, forKey: .environments) ?? []
        activeEnvironmentID = try container.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
        history = try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        requestDrafts = try container.decodeIfPresent([RequestDraftState].self, forKey: .requestDrafts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(sharedCollectionsDirectoryPath, forKey: .sharedCollectionsDirectoryPath)
        try container.encodeIfPresent(sharedCollectionsDirectoryBookmarkData, forKey: .sharedCollectionsDirectoryBookmarkData)
        try container.encodeIfPresent(bitbucketPadCloneHTTPSURL, forKey: .bitbucketPadCloneHTTPSURL)
        try container.encodeIfPresent(bitbucketPadBranch, forKey: .bitbucketPadBranch)
        try container.encodeIfPresent(bitbucketPadUsername, forKey: .bitbucketPadUsername)
        try container.encodeIfPresent(activeWorkspaceName, forKey: .activeWorkspaceName)
        try container.encode(globalVariables, forKey: .globalVariables)
        try container.encode(collections, forKey: .collections)
        try container.encode(flows, forKey: .flows)
        try container.encode(utilityLibraries, forKey: .utilityLibraries)
        try container.encode(environments, forKey: .environments)
        try container.encodeIfPresent(activeEnvironmentID, forKey: .activeEnvironmentID)
        try container.encode(history, forKey: .history)
        try container.encode(requestDrafts, forKey: .requestDrafts)
    }
}

public extension WorkspaceState {
    static var starter: WorkspaceState {
        WorkspaceState(
            globalVariables: [
                VariableValue(key: "baseUrl", value: "https://postman-echo.com"),
            ],
            collections: [
                CollectionModel(
                    info: CollectionInfoModel(
                        name: "Scratchpad",
                        description: "Coleccion local para pruebas rapidas.",
                        schemaVersion: .v21
                    ),
                    items: [
                        CollectionNode(
                            name: "Health Check",
                            kind: .request,
                            request: APIRequestModel(
                                name: "Health Check",
                                method: .get,
                                url: "{{baseUrl}}/get",
                                queryItems: [
                                    KeyValueEntry(key: "source", value: "efby"),
                                ],
                                headers: [
                                    KeyValueEntry(key: "Accept", value: "application/json"),
                                ],
                                scripts: [
                                    ScriptDefinition(
                                        name: "Status 200",
                                        listen: .test,
                                        language: "mini",
                                        source: "assert.status == 200"
                                    ),
                                ]
                            )
                        ),
                    ]
                ),
            ],
            environments: [
                EnvironmentProfile(
                    name: "Local",
                    variables: [
                        VariableValue(key: "apiToken", value: ""),
                    ],
                    isEnabled: true
                ),
            ]
        )
    }
}
