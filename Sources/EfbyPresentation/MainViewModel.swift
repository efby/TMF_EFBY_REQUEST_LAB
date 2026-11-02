import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
public final class MainViewModel: ObservableObject {
    public struct GitCredentialPrompt: Identifiable, Equatable {
        public let id = UUID()
        public let remoteInput: String
        public let remoteURL: String
        public let provider: GitProvider
        public let authKind: GitAuthenticationKind
        public let message: String
        public let instructions: String
        public let preferredMode: GitCredentialMode
        public let helpURL: URL?
    }

    public struct GitPullRecoveryPrompt: Identifiable, Equatable {
        public let id = UUID()
        public let changedPaths: [String]
    }

    @Published public var workspace: WorkspaceState = .starter
    @Published public var availableWorkspaceNames: [String] = []
    @Published public var tabs: [RequestTabState] = []
    @Published public var selectedTabID: UUID?
    @Published public var searchText: String = ""
    @Published public var errorMessage: String?
    @Published public var infoMessage: String?
    /// BPMN element ids currently executing during `executeFlow` (for diagram highlighting in the flow editor).
    @Published public internal(set) var flowExecutionHighlightElementIDs: Set<String> = []
    /// One entry per `flow.id` while a background run exists or has recently finished (cleared when a new run starts or `removeFlowRunSessionIfNotRunning` removes a completed session).
    @Published public internal(set) var flowRunSessions: [UUID: WorkspaceFlowRunSession] = [:]
    /// Incremented by `cancelAllRunningFlowExecutions()` so open flow editors can cancel synchronous batch `Task`s.
    @Published public internal(set) var cancelAllRunningFlowsTick: UInt = 0
    /// Last batch-run log lines per `WorkspaceFlowBatchRunCase.id`, keyed by `flow.id`. Stored in the view model so logs survive flow editor sheet refresh.
    @Published public internal(set) var workspaceFlowBatchCaseTranscripts: [UUID: [UUID: [String]]] = [:]

    var flowRunTasks: [UUID: Task<Void, Never>] = [:]
    var editorFlowExecutionTasks: [UUID: (flowID: UUID, task: Task<WorkspaceFlowExecutionResult, any Error>)] = [:]
    /// Límite de líneas en la consola del tab Running. Runs batch largos + resumen por corrida superan fácilmente 500 y borraban el detalle de batches anteriores.
    let flowRunLogLineLimit = 25_000
    @Published public var gitOutput: String?
    @Published public var gitRemoteDescription: String?
    @Published public var isGitBusy = false
    /// Descarga ZIP de Bitbucket (iPad / sin `git`); no usar para el flujo Git CLI en Mac.
    @Published public var isBitbucketArchiveDownloadBusy = false
    @Published public var gitBusyOperation: String?
    @Published public var gitCredentialPrompt: GitCredentialPrompt?
    @Published public var gitPullRecoveryPrompt: GitPullRecoveryPrompt?
    /// Paths with unresolved merge or stash-pop conflicts (`git diff --diff-filter=U`).
    @Published public internal(set) var gitMergeConflictPaths: [String] = []
    /// After `fetch`, Push is allowed only when not behind upstream and there are no unmerged files.
    @Published public internal(set) var canPushToSharedGit = false
    @Published public internal(set) var gitPushDisabledReason: String?
    @Published public internal(set) var isSharedGitMergeInProgress = false
    @Published public var didFinishInitialWorkspaceLoad = false

    @Published public internal(set) var persistedSharedEnvironments: [EnvironmentProfile] = []

    var repositoryDirectoryAccess = SecurityScopedDirectoryAccess()
    var pendingTabCloseTasks: [UUID: Task<Void, Never>] = [:]
    var workspacePersistenceErrorMessage: String?
    var workspaceContextID = UUID()
    var workspaceLoadTask: Task<Void, Never>?
    var isChangingWorkspace = false
    var workspaceTransitionFallback: (workspace: WorkspaceState, environments: [EnvironmentProfile])?
    private let dependencies: AppDependencies
    let persistenceCoordinator: WorkspacePersistenceCoordinator
    let documentImportCoordinator: DocumentImportCoordinator
    let gitSessionCoordinator: GitSessionCoordinator
    let requestTabCoordinator: RequestTabCoordinator
    let webSocketCoordinator: WebSocketExecutionCoordinator
    let flowCoordinator: FlowExecutionCoordinator
    lazy var sharedWorkspaceCoordinator: SharedWorkspaceCoordinator = {
        SharedWorkspaceCoordinator(
            persistenceCoordinator: persistenceCoordinator,
            gitService: dependencies.gitRepositoryService,
            normalizeFlows: { [weak self] flows, collections in
                guard let self else { return flows }
                return self.flowsPortableForPersistence(flows, collections: collections)
            }
        )
    }()
    let environmentCoordinator = EnvironmentCoordinator()
    let requestTabsCoordinator = RequestTabsCoordinator()
    let catalogCoordinator = WorkspaceCatalogCoordinator()
    let bitbucketPadCoordinator = BitbucketPadCoordinator()

    public init(dependencies: AppDependencies = .live(), autoloadWorkspace: Bool = true) {
        self.dependencies = dependencies
        self.persistenceCoordinator = WorkspacePersistenceCoordinator(
            loadWorkspace: dependencies.loadWorkspace,
            saveWorkspace: dependencies.saveWorkspace,
            persistSnapshot: dependencies.persistWorkspaceSnapshot,
            sharedRepository: dependencies.sharedCollectionsRepository
        )
        self.documentImportCoordinator = DocumentImportCoordinator(
            importWorkspaceDocument: dependencies.importWorkspaceDocument,
            exportPostmanCollection: dependencies.exportPostmanCollection
        )
        let gitCoordinator = GitWorkspaceCoordinator(
            syncGitWorkspace: dependencies.syncGitWorkspace,
            gitPull: dependencies.gitPull,
            gitCommitAndPush: dependencies.gitCommitAndPush,
            gitService: dependencies.gitRepositoryService
        )
        self.gitSessionCoordinator = GitSessionCoordinator(
            gitCoordinator: gitCoordinator,
            gitService: dependencies.gitRepositoryService
        )
        self.requestTabCoordinator = RequestTabCoordinator(
            executeHTTPRequest: dependencies.executeHTTPRequest
        )
        self.webSocketCoordinator = WebSocketExecutionCoordinator(
            webSocketService: dependencies.webSocketExecutionService
        )
        self.flowCoordinator = FlowExecutionCoordinator(
            httpRunner: dependencies.httpExecutionService,
            webSocketRunner: dependencies.webSocketExecutionService
        )
        if autoloadWorkspace {
            Task {
                await loadWorkspace()
            }
        }
    }

    public convenience init(
        repository: WorkspaceRepository,
        sharedCollectionsRepository: SharedCollectionsRepository = SharedCollectionsRepository(),
        gitRepositoryService: GitRepositoryService = GitRepositoryService(),
        postmanCodec: PostmanCollectionCodec = PostmanCollectionCodec(),
        postmanEnvironmentCodec: PostmanEnvironmentCodec = PostmanEnvironmentCodec(),
        openAPIImporter: OpenAPIImporter = OpenAPIImporter(),
        executor: RequestExecutionService = RequestExecutionService(),
        webSocketExecutor: WebSocketExecutionService = WebSocketExecutionService(),
        autoloadWorkspace: Bool = true
    ) {
        self.init(
            dependencies: .live(
                workspaceRepository: repository,
                sharedCollectionsRepository: sharedCollectionsRepository,
                gitRepositoryService: gitRepositoryService,
                postmanCodec: postmanCodec,
                postmanEnvironmentCodec: postmanEnvironmentCodec,
                openAPIImporter: openAPIImporter,
                httpService: executor,
                webSocketExecutionService: webSocketExecutor
            ),
            autoloadWorkspace: autoloadWorkspace
        )
    }

    public var activeEnvironment: EnvironmentProfile? {
        workspace.environments.first(where: { $0.id == workspace.activeEnvironmentID && $0.isEnabled })
    }

    public var currentTab: RequestTabState? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    public var sharedRepositoryURL: URL? {
        if let accessibleURL = repositoryDirectoryAccess.url,
           FileManager.default.fileExists(atPath: accessibleURL.path) {
            return accessibleURL
        }

        // Path-only sessions predate saved bookmarks. Bootstrap promotes an accessible
        // path to a restored grant; do not repeatedly resolve failed bookmarks in a view getter.
        guard workspace.sharedCollectionsDirectoryBookmarkData == nil,
              let path = workspace.sharedCollectionsDirectoryPath,
              path.hasPrefix("/") else {
            return nil
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) != nil else { return nil }
        return url
    }

    public var activeWorkspaceDirectoryURL: URL? {
        guard let root = sharedRepositoryURL,
              let activeWorkspaceName = workspace.activeWorkspaceName,
              !activeWorkspaceName.isEmpty else {
            return nil
        }

        return root.appendingPathComponent(activeWorkspaceName, isDirectory: true)
    }

    public var sharedCollectionsDirectoryDescription: String {
        sharedRepositoryURL?.path ?? "No configured repository"
    }

    public var activeWorkspaceDescription: String {
        workspace.activeWorkspaceName ?? "No workspace selected"
    }

    /// Quita el aviso de error global (p. ej. banner en iPad) sin modificar el resto del estado.
    public func dismissErrorMessageBanner() {
        errorMessage = nil
    }

    /// Quita el aviso informativo global (`infoMessage`).
    public func dismissInfoMessageBanner() {
        infoMessage = nil
    }

    public var requiresWorkingDirectorySelection: Bool {
        sharedRepositoryURL == nil
    }

    /// Workspace enlazado a Bitbucket (importación iPad ZIP/REST). Política: solo consumir remoto (actualización pisa el árbol local; no push).
    public var isBitbucketPadMirrorWorkspace: Bool {
        let u = workspace.bitbucketPadCloneHTTPSURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !u.isEmpty
    }

    public var hasPendingEnvironmentStoreChanges: Bool {
        environmentCoordinator.normalizedProfiles(workspace.environments) != environmentCoordinator.normalizedProfiles(persistedSharedEnvironments)
    }

    /// True when any flow has a live session (`isRunning`), including synchronous runs from the Runs tab.
    public var hasAnyFlowExecutionInFlight: Bool {
        flowRunSessions.values.contains(where: \.isRunning)
    }

    public var currentCollection: CollectionModel? {
        guard let collectionID = currentTab?.sourceCollectionID else {
            return workspace.collections.first
        }
        return workspace.collections.first(where: { $0.id == collectionID })
    }
}
