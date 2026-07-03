import EfbyApplication
import EfbyInfrastructure
import Foundation

/// Composition root: ensambla dependencias con implementaciones de producción.
public struct AppDependencies: Sendable {
    public let executeHTTPRequest: ExecuteHTTPRequestUseCase
    public let importPostmanCollection: ImportPostmanCollectionUseCase
    public let importPostmanEnvironment: ImportPostmanEnvironmentUseCase
    public let importOpenAPIDocument: ImportOpenAPIDocumentUseCase
    public let importWorkspaceDocument: ImportWorkspaceDocumentUseCase
    public let exportPostmanCollection: ExportPostmanCollectionUseCase
    public let syncGitWorkspace: SyncGitWorkspaceUseCase
    public let gitPull: GitPullUseCase
    public let gitCommitAndPush: GitCommitAndPushUseCase
    public let loadWorkspace: LoadWorkspaceUseCase
    public let saveWorkspace: SaveWorkspaceUseCase
    public let persistWorkspaceSnapshot: PersistWorkspaceSnapshotUseCase

    public let workspaceRepository: any WorkspaceRepositoryProtocol
    public let sharedCollectionsRepository: any SharedCollectionsRepositoryProtocol
    public let gitRepositoryService: any GitRepositoryServiceProtocol
    public let postmanCodec: any PostmanCollectionCodecProtocol
    public let postmanEnvironmentCodec: any PostmanEnvironmentCodecProtocol
    public let openAPIImporter: any OpenAPIImporterProtocol
    public let httpExecutionService: any HTTPExecutionServiceProtocol
    public let webSocketExecutionService: any WebSocketExecutionServiceProtocol

    public init(
        executeHTTPRequest: ExecuteHTTPRequestUseCase,
        importPostmanCollection: ImportPostmanCollectionUseCase,
        importPostmanEnvironment: ImportPostmanEnvironmentUseCase,
        importOpenAPIDocument: ImportOpenAPIDocumentUseCase,
        importWorkspaceDocument: ImportWorkspaceDocumentUseCase,
        exportPostmanCollection: ExportPostmanCollectionUseCase,
        syncGitWorkspace: SyncGitWorkspaceUseCase,
        gitPull: GitPullUseCase,
        gitCommitAndPush: GitCommitAndPushUseCase,
        loadWorkspace: LoadWorkspaceUseCase,
        saveWorkspace: SaveWorkspaceUseCase,
        persistWorkspaceSnapshot: PersistWorkspaceSnapshotUseCase,
        workspaceRepository: any WorkspaceRepositoryProtocol,
        sharedCollectionsRepository: any SharedCollectionsRepositoryProtocol,
        gitRepositoryService: any GitRepositoryServiceProtocol,
        postmanCodec: any PostmanCollectionCodecProtocol,
        postmanEnvironmentCodec: any PostmanEnvironmentCodecProtocol,
        openAPIImporter: any OpenAPIImporterProtocol,
        httpExecutionService: any HTTPExecutionServiceProtocol,
        webSocketExecutionService: any WebSocketExecutionServiceProtocol
    ) {
        self.executeHTTPRequest = executeHTTPRequest
        self.importPostmanCollection = importPostmanCollection
        self.importPostmanEnvironment = importPostmanEnvironment
        self.importOpenAPIDocument = importOpenAPIDocument
        self.importWorkspaceDocument = importWorkspaceDocument
        self.exportPostmanCollection = exportPostmanCollection
        self.syncGitWorkspace = syncGitWorkspace
        self.gitPull = gitPull
        self.gitCommitAndPush = gitCommitAndPush
        self.loadWorkspace = loadWorkspace
        self.saveWorkspace = saveWorkspace
        self.persistWorkspaceSnapshot = persistWorkspaceSnapshot
        self.workspaceRepository = workspaceRepository
        self.sharedCollectionsRepository = sharedCollectionsRepository
        self.gitRepositoryService = gitRepositoryService
        self.postmanCodec = postmanCodec
        self.postmanEnvironmentCodec = postmanEnvironmentCodec
        self.openAPIImporter = openAPIImporter
        self.httpExecutionService = httpExecutionService
        self.webSocketExecutionService = webSocketExecutionService
    }

    public static func live(
        workspaceRepository: any WorkspaceRepositoryProtocol = WorkspaceRepository(),
        sharedCollectionsRepository: any SharedCollectionsRepositoryProtocol = SharedCollectionsRepository(),
        gitRepositoryService: any GitRepositoryServiceProtocol = GitRepositoryService(),
        postmanCodec: any PostmanCollectionCodecProtocol = PostmanCollectionCodec(),
        postmanEnvironmentCodec: any PostmanEnvironmentCodecProtocol = PostmanEnvironmentCodec(),
        openAPIImporter: any OpenAPIImporterProtocol = OpenAPIImporter(),
        httpService: any HTTPExecutionServiceProtocol = RequestExecutionService(),
        webSocketExecutionService: any WebSocketExecutionServiceProtocol = WebSocketExecutionService()
    ) -> AppDependencies {
        let importPostmanCollection = ImportPostmanCollectionUseCase(codec: postmanCodec)
        let importPostmanEnvironment = ImportPostmanEnvironmentUseCase(codec: postmanEnvironmentCodec)
        let importOpenAPIDocument = ImportOpenAPIDocumentUseCase(importer: openAPIImporter)
        let saveWorkspace = SaveWorkspaceUseCase(repository: workspaceRepository)

        return AppDependencies(
            executeHTTPRequest: ExecuteHTTPRequestUseCase(httpService: httpService),
            importPostmanCollection: importPostmanCollection,
            importPostmanEnvironment: importPostmanEnvironment,
            importOpenAPIDocument: importOpenAPIDocument,
            importWorkspaceDocument: ImportWorkspaceDocumentUseCase(
                importPostmanCollection: importPostmanCollection,
                importOpenAPI: importOpenAPIDocument,
                importPostmanEnvironment: importPostmanEnvironment
            ),
            exportPostmanCollection: ExportPostmanCollectionUseCase(codec: postmanCodec),
            syncGitWorkspace: SyncGitWorkspaceUseCase(gitService: gitRepositoryService),
            gitPull: GitPullUseCase(gitService: gitRepositoryService),
            gitCommitAndPush: GitCommitAndPushUseCase(gitService: gitRepositoryService),
            loadWorkspace: LoadWorkspaceUseCase(repository: workspaceRepository),
            saveWorkspace: saveWorkspace,
            persistWorkspaceSnapshot: PersistWorkspaceSnapshotUseCase(
                saveWorkspace: saveWorkspace,
                sharedRepository: sharedCollectionsRepository
            ),
            workspaceRepository: workspaceRepository,
            sharedCollectionsRepository: sharedCollectionsRepository,
            gitRepositoryService: gitRepositoryService,
            postmanCodec: postmanCodec,
            postmanEnvironmentCodec: postmanEnvironmentCodec,
            openAPIImporter: openAPIImporter,
            httpExecutionService: httpService,
            webSocketExecutionService: webSocketExecutionService
        )
    }
}
