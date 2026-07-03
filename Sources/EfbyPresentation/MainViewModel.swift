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
    @Published public private(set) var flowExecutionHighlightElementIDs: Set<String> = []
    /// One entry per `flow.id` while a background run exists or has recently finished (cleared when a new run starts or `removeFlowRunSessionIfNotRunning` removes a completed session).
    @Published public private(set) var flowRunSessions: [UUID: WorkspaceFlowRunSession] = [:]
    /// Incremented by `cancelAllRunningFlowExecutions()` so open flow editors can cancel synchronous batch `Task`s.
    @Published public private(set) var cancelAllRunningFlowsTick: UInt = 0
    /// Last batch-run log lines per `WorkspaceFlowBatchRunCase.id`, keyed by `flow.id`. Stored in the view model so logs survive flow editor sheet refresh.
    @Published public private(set) var workspaceFlowBatchCaseTranscripts: [UUID: [UUID: [String]]] = [:]

    private var flowRunTasks: [UUID: Task<Void, Never>] = [:]
    /// Límite de líneas en la consola del tab Running. Runs batch largos + resumen por corrida superan fácilmente 500 y borraban el detalle de batches anteriores.
    private let flowRunLogLineLimit = 25_000
    @Published public var gitOutput: String?
    @Published public var gitRemoteDescription: String?
    @Published public var isGitBusy = false
    /// Descarga ZIP de Bitbucket (iPad / sin `git`); no usar para el flujo Git CLI en Mac.
    @Published public var isBitbucketArchiveDownloadBusy = false
    @Published public var gitBusyOperation: String?
    @Published public var gitCredentialPrompt: GitCredentialPrompt?
    @Published public var gitPullRecoveryPrompt: GitPullRecoveryPrompt?
    /// Paths with unresolved merge or stash-pop conflicts (`git diff --diff-filter=U`).
    @Published public private(set) var gitMergeConflictPaths: [String] = []
    /// After `fetch`, Push is allowed only when not behind upstream and there are no unmerged files.
    @Published public private(set) var canPushToSharedGit = false
    @Published public private(set) var gitPushDisabledReason: String?
    @Published public private(set) var isSharedGitMergeInProgress = false
    @Published public var didFinishInitialWorkspaceLoad = false

    @Published public private(set) var persistedSharedEnvironments: [EnvironmentProfile] = []

    private var repositoryDirectoryAccess = SecurityScopedDirectoryAccess()
    private var pendingWorkspacePersistenceTask: Task<Void, Never>?
    private let dependencies: AppDependencies
    private let persistenceCoordinator: WorkspacePersistenceCoordinator
    private let documentImportCoordinator: DocumentImportCoordinator
    private let gitSessionCoordinator: GitSessionCoordinator
    private let requestTabCoordinator: RequestTabCoordinator
    private let webSocketCoordinator: WebSocketExecutionCoordinator
    private let flowCoordinator: FlowExecutionCoordinator
    private lazy var sharedWorkspaceCoordinator: SharedWorkspaceCoordinator = {
        SharedWorkspaceCoordinator(
            persistenceCoordinator: persistenceCoordinator,
            gitService: dependencies.gitRepositoryService,
            normalizeFlows: { [weak self] flows, collections in
                guard let self else { return flows }
                return self.flowsPortableForPersistence(flows, collections: collections)
            }
        )
    }()
    private let environmentCoordinator = EnvironmentCoordinator()
    private let requestTabsCoordinator = RequestTabsCoordinator()
    private let catalogCoordinator = WorkspaceCatalogCoordinator()
    private let bitbucketPadCoordinator = BitbucketPadCoordinator()

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
        if let scopedURL = repositoryDirectoryAccess.url,
           repositoryDirectoryAccess.hasActiveAccess,
           FileManager.default.fileExists(atPath: scopedURL.path) {
            return scopedURL
        }

        // Legacy workspaces may only have a path on disk; avoid using it once a bookmark exists
        // because macOS will keep prompting for permission delegation on every file access.
        guard workspace.sharedCollectionsDirectoryBookmarkData == nil,
              let path = workspace.sharedCollectionsDirectoryPath,
              !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    public func loadWorkspace() async {
        do {
            workspace = try await persistenceCoordinator.loadLocal()
            restoreSharedRepositoryAccessIfNeeded()
            persistedSharedEnvironments = workspace.environments
            if workspace.activeEnvironmentID == nil {
                workspace.activeEnvironmentID = workspace.environments.first(where: \.isEnabled)?.id
            }
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)
            restoreDraftTabsIfNeeded()
            openFirstRequestIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
        didFinishInitialWorkspaceLoad = true
    }

    /// En iPad, si el workspace tiene Bitbucket guardado y token en llavero, vuelve a descargar y sustituye el almacenamiento compartido; si no, recarga solo desde disco.
    public func reloadWorkspaceResyncingBitbucketIfNeeded() async {
        if isBitbucketPadMirrorWorkspace,
           sharedRepositoryURL != nil,
           let token = BitbucketPadCredentialStore.loadAPIToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            let effectiveURL = (workspace.bitbucketPadCloneHTTPSURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !effectiveURL.isEmpty else {
                await loadWorkspace()
                return
            }
            switch bitbucketPadCoordinator.planResync(
                cloneHTTPSURL: effectiveURL,
                branch: workspace.bitbucketPadBranch ?? "",
                bitbucketUsername: workspace.bitbucketPadUsername ?? "",
                bitbucketAppPassword: token,
                hasSharedRepository: true,
                savedCloneHTTPSURL: workspace.bitbucketPadCloneHTTPSURL,
                savedBranch: workspace.bitbucketPadBranch,
                savedUsername: workspace.bitbucketPadUsername
            ) {
            case .failure(let error):
                errorMessage = error.message
                await loadWorkspace()
            case .success(let plan):
                await executeBitbucketPadImport(plan)
            }
            return
        }
        await loadWorkspace()
    }

    public func refreshSharedData(forceInfoMessage: Bool = true) {
        Task {
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: forceInfoMessage)
            await MainActor.run {
                self.restoreDraftTabsIfNeeded()
                self.openFirstRequestIfNeeded()
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    public func hasPendingRequestChanges(for tab: RequestTabState) -> Bool {
        hasPendingRequestEditorChanges(for: tab)
    }

    public func hasPendingRequestEditorChanges(for tab: RequestTabState) -> Bool {
        !requestsEquivalentForPersistence(tab.persistedRequest, tab.request)
    }

    public func hasPendingEnvironmentChanges(for tab: RequestTabState) -> Bool {
        !environmentCoordinator.variablesEquivalent(tab.pendingEnvironmentVariables, tab.persistedEnvironmentVariables)
    }

    public var hasPendingEnvironmentStoreChanges: Bool {
        environmentCoordinator.normalizedProfiles(workspace.environments) != environmentCoordinator.normalizedProfiles(persistedSharedEnvironments)
    }

    public func newRequest() {
        let tab = RequestTabState(
            request: APIRequestModel(
                name: "Untitled Request",
                method: .get,
                url: "https://postman-echo.com/get"
            ),
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistPendingChanges(for: tab)
    }

    public func suggestedCollectionName() -> String {
        catalogCoordinator.suggestedCollectionName(collections: workspace.collections)
    }

    public func suggestedCollectionCloneName(for collection: CollectionModel) -> String {
        catalogCoordinator.suggestedCollectionName(
            collections: workspace.collections,
            baseName: "\(collection.info.name) Copy"
        )
    }

    public func suggestedUtilityLibraryName() -> String {
        catalogCoordinator.suggestedUtilityLibraryName(utilityLibraries: workspace.utilityLibraries)
    }

    public func suggestedFlowName() -> String {
        catalogCoordinator.suggestedFlowName(flows: workspace.flows)
    }

    public func suggestedFlowCloneName(for flow: WorkspaceFlowDefinition) -> String {
        catalogCoordinator.suggestedFlowCloneName(for: flow, flows: workspace.flows)
    }

    public func suggestedEnvironmentCloneName(for profile: EnvironmentProfile) -> String {
        environmentCoordinator.suggestedCloneName(
            for: profile,
            existingNames: Set(workspace.environments.map { $0.name.lowercased() })
        )
    }

    public func collectionNameValidationMessage(_ rawName: String, excluding excludedCollectionID: UUID? = nil) -> String? {
        catalogCoordinator.collectionNameValidationMessage(
            rawName,
            collections: workspace.collections,
            excluding: excludedCollectionID
        )
    }

    public func utilityLibraryNameValidationMessage(_ rawName: String, excluding excludedUtilityID: UUID? = nil) -> String? {
        catalogCoordinator.utilityLibraryNameValidationMessage(
            rawName,
            utilityLibraries: workspace.utilityLibraries,
            excluding: excludedUtilityID
        )
    }

    public func flowNameValidationMessage(_ rawName: String, excluding excludedFlowID: UUID? = nil) -> String? {
        catalogCoordinator.flowNameValidationMessage(
            rawName,
            flows: workspace.flows,
            excluding: excludedFlowID
        )
    }

    public func utilityLibrarySourceValidationMessage(_ rawSource: String, excluding excludedUtilityID: UUID? = nil) -> String? {
        catalogCoordinator.utilityLibrarySourceValidationMessage(
            rawSource,
            utilityLibraries: workspace.utilityLibraries,
            excluding: excludedUtilityID
        )
    }

    @discardableResult
    public func addUtilityLibrary(named rawName: String) -> WorkspaceScriptUtility? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? suggestedUtilityLibraryName() : trimmedName

        if let validationMessage = utilityLibraryNameValidationMessage(name) {
            errorMessage = validationMessage
            return nil
        }

        let utility = catalogCoordinator.makeDefaultUtilityLibrary(named: name)
        if let validationMessage = utilityLibrarySourceValidationMessage(utility.source) {
            errorMessage = validationMessage
            return nil
        }
        workspace.utilityLibraries.append(utility)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: true
        )
        return utility
    }

    @discardableResult
    public func addFlow(named rawName: String) -> WorkspaceFlowDefinition? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? suggestedFlowName() : trimmedName

        if let validationMessage = flowNameValidationMessage(name) {
            errorMessage = validationMessage
            return nil
        }

        let flow = WorkspaceFlowDefinition(name: name)
        workspace.flows.append(flow)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
        return flow
    }

    @discardableResult
    public func updateUtilityLibrary(_ utility: WorkspaceScriptUtility) -> Bool {
        if let validationMessage = utilityLibraryNameValidationMessage(utility.name, excluding: utility.id)
            ?? utilityLibrarySourceValidationMessage(utility.source, excluding: utility.id) {
            errorMessage = validationMessage
            return false
        }

        guard let index = workspace.utilityLibraries.firstIndex(where: { $0.id == utility.id }) else {
            return false
        }
        workspace.utilityLibraries[index] = utility
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: true
        )
        return true
    }

    @discardableResult
    public func updateFlow(_ flow: WorkspaceFlowDefinition) -> Bool {
        if let validationMessage = flowNameValidationMessage(flow.name, excluding: flow.id) {
            errorMessage = validationMessage
            return false
        }

        guard let index = workspace.flows.firstIndex(where: { $0.id == flow.id }) else {
            return false
        }

        var updated = flow
        updated.updatedAt = Date()
        updated = normalizeFlowTaskBindingsForExecution(updated)
        workspace.flows[index] = updated
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
        return true
    }

    public func renameFlow(_ flow: WorkspaceFlowDefinition, to rawName: String) {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = workspace.flows.firstIndex(where: { $0.id == flow.id }) else { return }
        guard flowNameValidationMessage(trimmedName, excluding: flow.id) == nil else {
            errorMessage = flowNameValidationMessage(trimmedName, excluding: flow.id)
            return
        }
        workspace.flows[index].name = trimmedName
        workspace.flows[index].updatedAt = Date()
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
    }

    /// Deep-copies BPMN, bindings, viewport, and batch cases with a new id and persisted name.
    @discardableResult
    public func cloneFlow(_ flow: WorkspaceFlowDefinition, named rawName: String) -> WorkspaceFlowDefinition? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? suggestedFlowCloneName(for: flow) : trimmedName
        if let validationMessage = flowNameValidationMessage(name) {
            errorMessage = validationMessage
            return nil
        }

        var copy = catalogCoordinator.makeClonedFlow(from: flow, named: name)
        copy = normalizeFlowTaskBindingsForExecution(copy)
        workspace.flows.append(copy)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
        infoMessage = "Flow '\(name)' cloned."
        return copy
    }

    public func deleteFlow(_ flow: WorkspaceFlowDefinition) {
        cancelFlowExecution(flowID: flow.id)
        workspace.flows.removeAll { $0.id == flow.id }
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: true,
            syncSharedUtilities: false
        )
    }

    public func availableFlowRequests() -> [WorkspaceFlowRequestReference] {
        catalogCoordinator.flowRequestReferences(in: workspace.collections)
    }

    private func availableFlowRequests(forCollections collections: [CollectionModel]) -> [WorkspaceFlowRequestReference] {
        catalogCoordinator.flowRequestReferences(in: collections)
    }

    public func validateFlow(
        _ flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot
    ) -> WorkspaceFlowValidationResult {
        flowCoordinator.validate(
            flow: flow,
            graph: flowCoordinator.executionGraph(for: flow, editorGraph: graph),
            availableRequests: availableFlowRequests()
        )
    }

    public func executeFlow(
        _ flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        onLog: (@Sendable (String) async -> Void)? = nil,
        executionEnvironmentID: UUID? = nil
    ) async throws -> WorkspaceFlowExecutionResult {
        let validation = validateFlow(flow, graph: graph)
        if !validation.isValid {
            let messages = validation.issues
                .filter { $0.severity == .error }
                .map(\.message)
                .joined(separator: "\n")
            throw AppError.invalidDocument(messages.isEmpty ? "The flow is not valid." : messages)
        }
        let executionGraph = flowCoordinator.executionGraph(for: flow, editorGraph: graph)
        return try await performFlowExecutionCore(
            flow: flow,
            graph: executionGraph,
            onLog: onLog,
            executionEnvironmentID: executionEnvironmentID
        )
    }

    public func flowRunSession(for flowID: UUID) -> WorkspaceFlowRunSession? {
        flowRunSessions[flowID]
    }

    public func hasActiveFlowRun(for flowID: UUID) -> Bool {
        flowCoordinator.hasActiveRun(in: flowRunSessions, flowID: flowID)
    }

    /// True when any flow has a live session (`isRunning`), including synchronous runs from the Runs tab.
    public var hasAnyFlowExecutionInFlight: Bool {
        flowRunSessions.values.contains(where: \.isRunning)
    }

    /// Cancels every `startBackgroundFlowExecution` task and bumps `cancelAllRunningFlowsTick` so editors stop synchronous `executeFlow` batch tasks.
    public func cancelAllRunningFlowExecutions() {
        for id in Array(flowRunTasks.keys) {
            flowRunTasks[id]?.cancel()
        }
        cancelAllRunningFlowsTick &+= 1
    }

    /// Marks the session as cooperatively cancelled (same as task cancellation outcome).
    public func markFlowRunCancelled(flowID: UUID) {
        markFlowRunSessionCancelled(flowID: flowID)
    }

    /// Removes a **completed** session so the flow editor can show batch-only logs without mixing in an older background run.
    public func removeFlowRunSessionIfNotRunning(flowID: UUID) {
        guard let session = flowRunSessions[flowID], !session.isRunning else { return }
        var copy = flowRunSessions
        copy.removeValue(forKey: flowID)
        flowRunSessions = copy
    }

    public func recordWorkspaceFlowBatchCaseTranscript(flowID: UUID, caseID: UUID, lines: [String]) {
        var outer = workspaceFlowBatchCaseTranscripts
        var byCase = outer[flowID] ?? [:]
        byCase[caseID] = lines
        outer[flowID] = byCase
        workspaceFlowBatchCaseTranscripts = outer
    }

    public func removeWorkspaceFlowBatchCaseTranscript(flowID: UUID, caseID: UUID) {
        guard var byCase = workspaceFlowBatchCaseTranscripts[flowID] else { return }
        byCase.removeValue(forKey: caseID)
        var outer = workspaceFlowBatchCaseTranscripts
        if byCase.isEmpty {
            outer.removeValue(forKey: flowID)
        } else {
            outer[flowID] = byCase
        }
        workspaceFlowBatchCaseTranscripts = outer
    }

    public func clearWorkspaceFlowBatchCaseTranscripts(for flowID: UUID) {
        var outer = workspaceFlowBatchCaseTranscripts
        outer.removeValue(forKey: flowID)
        workspaceFlowBatchCaseTranscripts = outer
    }

    public func workspaceFlowBatchCaseTranscript(flowID: UUID, caseID: UUID) -> [String] {
        workspaceFlowBatchCaseTranscripts[flowID]?[caseID] ?? []
    }

    /// Starts a fresh **running** session for a synchronous `executeFlow` from the flow editor (batch / sequential). Cancels any detached task for the same `flowID`.
    public func beginEditorSynchronousFlowRun(flowID: UUID) {
        flowRunTasks[flowID]?.cancel()
        flowRunTasks[flowID] = nil
        replaceFlowRunSession(flowID, WorkspaceFlowRunSession(flowID: flowID, logs: [], isRunning: true))
    }

    public func appendEditorSynchronousFlowRunLog(flowID: UUID, line: String) {
        appendFlowRunLog(flowID: flowID, line: line)
    }

    public func finishEditorSynchronousFlowRun(flowID: UUID, result: WorkspaceFlowExecutionResult) {
        completeFlowRunSession(flowID: flowID, result: result)
    }

    public func markEditorSynchronousFlowRunFailed(flowID: UUID, error: Error) {
        markFlowRunSessionFailed(flowID: flowID, error: error)
    }

    /// Desconecta el WebSocket de una pestaña concreta (iPad).
    public func disconnectWebSocket(forTabID tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        disconnectWebSocket(tab: tab)
    }

    /// Ejecuta un caso de batch del flow (misma lógica que el editor Mac: entorno + `executeFlow` síncrono).
    public func runPadFlowBatchSingleCase(flowID: UUID, caseID: UUID, executionEnvironmentID: UUID? = nil) async {
        guard let flow = workspace.flows.first(where: { $0.id == flowID }),
              let rows = flow.batchRunCases,
              let index = rows.firstIndex(where: { $0.id == caseID })
        else { return }

        cancelFlowExecution(flowID: flowID)

        let graph: WorkspaceFlowGraphSnapshot
        do {
            graph = try WorkspaceFlowBPMNParser().parse(xml: flow.bpmnXML)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        beginEditorSynchronousFlowRun(flowID: flowID)
        do {
            let result = try await performPadFlowBatchRunCase(
                flow: flow,
                allRows: rows,
                runCase: rows[index],
                caseIndex: index,
                graph: graph,
                executionEnvironmentID: executionEnvironmentID
            )
            finishEditorSynchronousFlowRun(flowID: flowID, result: result)
        } catch is CancellationError {
            markFlowRunCancelled(flowID: flowID)
        } catch {
            markEditorSynchronousFlowRunFailed(flowID: flowID, error: error)
            errorMessage = error.localizedDescription
        }
    }

    /// Ejecuta todos los casos batch en orden. Cancela con `Task.cancel()` en la tarea que invoque este método.
    public func runPadFlowBatchAllCasesSequentially(flowID: UUID, executionEnvironmentID: UUID? = nil) async {
        guard let flow = workspace.flows.first(where: { $0.id == flowID }),
              let rows = flow.batchRunCases,
              !rows.isEmpty
        else { return }

        cancelFlowExecution(flowID: flowID)

        let graph: WorkspaceFlowGraphSnapshot
        do {
            graph = try WorkspaceFlowBPMNParser().parse(xml: flow.bpmnXML)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        beginEditorSynchronousFlowRun(flowID: flowID)
        var lastCompletedResult: WorkspaceFlowExecutionResult?
        var aborted = false
        let orderedIDs = rows.map(\.id)
        for (offset, caseID) in orderedIDs.enumerated() {
            if Task.isCancelled {
                aborted = true
                markFlowRunCancelled(flowID: flowID)
                break
            }

            appendEditorSynchronousFlowRunLog(
                flowID: flowID,
                line: "——— Batch \(offset + 1) / \(orderedIDs.count) ———"
            )

            guard let index = rows.firstIndex(where: { $0.id == caseID }) else { continue }
            do {
                let result = try await performPadFlowBatchRunCase(
                    flow: flow,
                    allRows: rows,
                    runCase: rows[index],
                    caseIndex: index,
                    graph: graph,
                    executionEnvironmentID: executionEnvironmentID
                )
                lastCompletedResult = result
            } catch is CancellationError {
                aborted = true
                markFlowRunCancelled(flowID: flowID)
                break
            } catch {
                aborted = true
                errorMessage = error.localizedDescription
                markEditorSynchronousFlowRunFailed(flowID: flowID, error: error)
                break
            }
        }

        if !aborted, let result = lastCompletedResult {
            finishEditorSynchronousFlowRun(flowID: flowID, result: result)
        }
    }

    private func performPadFlowBatchRunCase(
        flow: WorkspaceFlowDefinition,
        allRows: [WorkspaceFlowBatchRunCase],
        runCase: WorkspaceFlowBatchRunCase,
        caseIndex: Int,
        graph: WorkspaceFlowGraphSnapshot,
        executionEnvironmentID: UUID?
    ) async throws -> WorkspaceFlowExecutionResult {
        let caseID = runCase.id
        let title = runCase.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Run \(caseIndex + 1)"
            : runCase.name

        let collector = FlowBatchTranscriptCollector()
        let headerApplying = "=== \(title): applying JSON to active environment ==="
        appendEditorSynchronousFlowRunLog(flowID: flow.id, line: headerApplying)
        await collector.append(headerApplying)

        let keysToRemove = allTopLevelKeysFromFlowBatchRunCases(allRows)
        let keysSorted = keysToRemove.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let keysListForLog: String = {
            guard !keysSorted.isEmpty else { return "(ninguna clave en los JSON del batch)" }
            let joined = keysSorted.joined(separator: ", ")
            if joined.count <= 400 { return joined }
            return String(joined.prefix(397)) + "…"
        }()
        let scrubLine = "Batch env: quitando \(keysToRemove.count) clave(s) definidas en alguna fila del batch → [\(keysListForLog)]"
        appendEditorSynchronousFlowRunLog(flowID: flow.id, line: scrubLine)
        await collector.append(scrubLine)

        try removeActiveEnvironmentVariables(withKeys: keysToRemove, targetEnvironmentID: executionEnvironmentID)
        try upsertActiveEnvironmentVariablesFromFlowBatchParametersJSON(
            runCase.parametersJSON,
            targetEnvironmentID: executionEnvironmentID
        )

        let headerExecuting = "=== \(title): executing flow ==="
        appendEditorSynchronousFlowRunLog(flowID: flow.id, line: headerExecuting)
        await collector.append(headerExecuting)

        let onLog: (@Sendable (String) async -> Void) = { [weak self] line in
            await collector.append(line)
            await MainActor.run {
                self?.appendEditorSynchronousFlowRunLog(flowID: flow.id, line: line)
            }
        }

        let result = try await executeFlow(flow, graph: graph, onLog: onLog, executionEnvironmentID: executionEnvironmentID)
        let combined = await collector.lines()
        recordWorkspaceFlowBatchCaseTranscript(flowID: flow.id, caseID: caseID, lines: combined)
        return result
    }

    /// Starts a validated flow run in a detached task. Cooperative cancellation via `cancelFlowExecution(flowID:)`.
    /// At most one active run per `flow.id` is allowed.
    public func startBackgroundFlowExecution(
        _ flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        executionEnvironmentID: UUID? = nil
    ) throws {
        let validation = validateFlow(flow, graph: graph)
        if !validation.isValid {
            let messages = validation.issues
                .filter { $0.severity == .error }
                .map(\.message)
                .joined(separator: "\n")
            throw AppError.invalidDocument(messages.isEmpty ? "The flow is not valid." : messages)
        }

        let flowID = flow.id
        if flowRunSessions[flowID]?.isRunning == true {
            throw AppError.invalidDocument("Este flow ya tiene una ejecución en curso.")
        }

        flowRunTasks[flowID]?.cancel()

        let session = WorkspaceFlowRunSession(flowID: flowID)
        replaceFlowRunSession(flowID, session)

        let capturedFlow = flow
        let capturedGraph = flowCoordinator.executionGraph(for: flow, editorGraph: graph)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.performFlowExecutionCore(
                    flow: capturedFlow,
                    graph: capturedGraph,
                    onLog: { line in
                        await MainActor.run {
                            self.appendFlowRunLog(flowID: flowID, line: line)
                        }
                    },
                    executionEnvironmentID: executionEnvironmentID
                )
                await MainActor.run {
                    self.flowRunTasks[flowID] = nil
                    self.completeFlowRunSession(flowID: flowID, result: result)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.flowRunTasks[flowID] = nil
                    self.markFlowRunSessionCancelled(flowID: flowID)
                }
            } catch {
                await MainActor.run {
                    self.flowRunTasks[flowID] = nil
                    self.markFlowRunSessionFailed(flowID: flowID, error: error)
                }
            }
        }
        flowRunTasks[flowID] = task
    }

    public func cancelFlowExecution(flowID: UUID) {
        flowRunTasks[flowID]?.cancel()
    }

    private func replaceFlowRunSession(_ flowID: UUID, _ session: WorkspaceFlowRunSession) {
        var copy = flowRunSessions
        copy[flowID] = session
        flowRunSessions = copy
    }

    private func appendFlowRunLog(flowID: UUID, line: String) {
        guard var session = flowRunSessions[flowID] else { return }
        session.logs.append(line)
        if session.logs.count > flowRunLogLineLimit {
            session.logs.removeFirst(session.logs.count - flowRunLogLineLimit)
        }
        replaceFlowRunSession(flowID, session)
    }

    private func completeFlowRunSession(flowID: UUID, result: WorkspaceFlowExecutionResult) {
        flowExecutionHighlightElementIDs.removeAll()
        guard var session = flowRunSessions[flowID] else { return }
        session.isRunning = false
        session.lastResult = result
        session.lastErrorDescription = nil
        replaceFlowRunSession(flowID, session)
    }

    private func markFlowRunSessionCancelled(flowID: UUID) {
        flowExecutionHighlightElementIDs.removeAll()
        guard var session = flowRunSessions[flowID] else { return }
        session.isRunning = false
        session.lastErrorDescription = "Cancelled"
        replaceFlowRunSession(flowID, session)
    }

    private func markFlowRunSessionFailed(flowID: UUID, error: Error) {
        flowExecutionHighlightElementIDs.removeAll()
        guard var session = flowRunSessions[flowID] else { return }
        session.isRunning = false
        session.lastErrorDescription = error.localizedDescription
        replaceFlowRunSession(flowID, session)
    }

    private func performFlowExecutionCore(
        flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        onLog: (@Sendable (String) async -> Void)? = nil,
        executionEnvironmentID: UUID? = nil
    ) async throws -> WorkspaceFlowExecutionResult {
        let executionFlow = normalizeFlowTaskBindingsForExecution(flow)
        let resolvedRequests = try resolveRequests(for: executionFlow)
        let effectiveEnvironmentID = executionEnvironmentID ?? workspace.activeEnvironmentID
        let environmentVariables = environmentCoordinator.variables(for: effectiveEnvironmentID, in: workspace.environments) ?? []

        if let onLog {
            let envLabel: String = {
                guard let effectiveEnvironmentID,
                      let env = workspace.environments.first(where: { $0.id == effectiveEnvironmentID }) else {
                    return "ninguno (sin variables de entorno)"
                }
                return "\(env.name) [\(environmentVariables.count) vars, perfil \(env.isEnabled ? "activo" : "desactivado en workspace")]"
            }()
            await onLog("Entorno de ejecución del flow: \(envLabel)")
        }

        flowExecutionHighlightElementIDs.removeAll()
        defer {
            flowExecutionHighlightElementIDs.removeAll()
        }

        let onHighlight: @Sendable (WorkspaceFlowExecutionHighlightEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.applyFlowExecutionHighlight(event)
            }
        }

        let onVariableCheckpoint: @Sendable (WorkspaceFlowExecutionVariableCheckpoint) async -> Void = { [weak self] checkpoint in
            await MainActor.run {
                guard let self else { return }
                self.applyFlowExecutionVariableUpdates(
                    WorkspaceFlowExecutionResult(
                        logs: [],
                        taskResults: [],
                        updatedGlobals: checkpoint.updatedGlobals,
                        updatedEnvironment: checkpoint.updatedEnvironment,
                        updatedEnvironments: checkpoint.updatedEnvironments,
                        activeEnvironmentID: checkpoint.activeEnvironmentID,
                        updatedCollections: checkpoint.updatedCollections
                    ),
                    persistToDisk: false
                )
            }
        }

        var mergedResult = try await flowCoordinator.execute(
            flow: executionFlow,
            graph: graph,
            globals: workspace.globalVariables,
            environment: environmentVariables,
            workspaceEnvironments: workspace.environments,
            activeEnvironmentID: effectiveEnvironmentID,
            utilityLibraries: workspace.utilityLibraries,
            resolvedRequests: resolvedRequests,
            onLog: onLog,
            onHighlight: onHighlight,
            onVariableCheckpoint: onVariableCheckpoint
        )

        let summaryFooter = mergedResult.taskResultsSummaryLogLines()
        for line in summaryFooter {
            mergedResult.logs.append(line)
            if let onLog {
                await onLog(line)
            }
        }

        applyFlowExecutionVariableUpdates(mergedResult, persistToDisk: false)
        return mergedResult
    }

    /// Parses a JSON object and upserts each top-level key into the **active** environment profile (string values). Persists workspace.
    public func upsertActiveEnvironmentVariablesFromFlowBatchParametersJSON(
        _ json: String,
        targetEnvironmentID: UUID? = nil
    ) throws {
        let updates = try environmentCoordinator.parseFlowBatchParameterUpdates(from: json)
        let environmentID = targetEnvironmentID ?? workspace.activeEnvironmentID
        guard let environmentID,
              let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID && $0.isEnabled }) else {
            throw AppError.invalidDocument("Selecciona un entorno activo antes de aplicar parámetros del run.")
        }

        let previous = workspace.environments[environmentIndex].variables
        let merged = environmentCoordinator.merge(existing: previous, with: updates)
        workspace.environments[environmentIndex].variables = merged
        persistedSharedEnvironments = workspace.environments

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environmentID,
            previousVariables: previous,
            updatedVariables: merged,
            excluding: UUID()
        )

        persistWorkspace(
            syncSharedCollections: true,
            syncSharedEnvironments: true,
            syncSharedFlows: true,
            syncSharedUtilities: true
        )
    }

    /// Claves de primer nivel de un `parametersJSON` de batch (objeto raíz; trim, sin vacías). No objeto o JSON inválido → conjunto vacío.
    public func topLevelKeysFromFlowBatchParametersJSON(_ json: String) -> Set<String> {
        environmentCoordinator.topLevelKeysFromFlowBatchParametersJSON(json)
    }

    /// Recorre el JSON de cada caso (`parametersJSON` como objeto raíz) y devuelve la unión de claves de primer nivel **únicas** (trim, sin vacías). Se usa antes de cada run batch (individual o secuencial): se quitan todas esas claves del entorno activo y luego se aplica solo el JSON de la fila en ejecución.
    public func allTopLevelKeysFromFlowBatchRunCases(_ cases: [WorkspaceFlowBatchRunCase]) -> Set<String> {
        cases.reduce(into: Set<String>()) { partial, runCase in
            partial.formUnion(topLevelKeysFromFlowBatchParametersJSON(runCase.parametersJSON))
        }
    }

    /// Quita del perfil de entorno **activo** todas las variables cuyo `key` esté en `keys`. Persiste el workspace como en el upsert de batch.
    public func removeActiveEnvironmentVariables(withKeys keys: Set<String>, targetEnvironmentID: UUID? = nil) throws {
        guard !keys.isEmpty else { return }
        let environmentID = targetEnvironmentID ?? workspace.activeEnvironmentID
        guard let environmentID,
              let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID && $0.isEnabled }) else {
            throw AppError.invalidDocument("Selecciona un entorno activo antes de aplicar parámetros del run.")
        }

        let previous = workspace.environments[environmentIndex].variables
        let filtered = previous.filter { variable in
            let k = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
            return !keys.contains(k)
        }

        workspace.environments[environmentIndex].variables = filtered
        persistedSharedEnvironments = workspace.environments

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environmentID,
            previousVariables: previous,
            updatedVariables: filtered,
            excluding: UUID()
        )

        persistWorkspace(
            syncSharedCollections: true,
            syncSharedEnvironments: true,
            syncSharedFlows: true,
            syncSharedUtilities: true
        )
    }

    @MainActor
    private func applyFlowExecutionHighlight(_ event: WorkspaceFlowExecutionHighlightEvent) {
        switch event {
        case .enter(let id):
            flowExecutionHighlightElementIDs.insert(id)
        case .leave(let id):
            flowExecutionHighlightElementIDs.remove(id)
        case .clearAll:
            flowExecutionHighlightElementIDs.removeAll()
        }
    }

    public func renameUtilityLibrary(_ utility: WorkspaceScriptUtility, to rawName: String) {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let validationMessage = utilityLibraryNameValidationMessage(trimmedName, excluding: utility.id) else {
            guard let index = workspace.utilityLibraries.firstIndex(where: { $0.id == utility.id }) else { return }
            workspace.utilityLibraries[index].name = trimmedName
            persistWorkspace(
                syncSharedCollections: false,
                syncSharedEnvironments: false,
                syncSharedFlows: false,
                syncSharedUtilities: true
            )
            return
        }

        errorMessage = validationMessage
    }

    public func deleteUtilityLibrary(_ utility: WorkspaceScriptUtility) {
        workspace.utilityLibraries.removeAll { $0.id == utility.id }
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: true
        )
    }

    public func addCollection() {
        addCollection(named: suggestedCollectionName())
    }

    public func addCollection(named rawName: String) {
        Task {
            do {
                try await ensureActiveWorkspaceExistsIfNeeded()
                let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmedName.isEmpty ? suggestedCollectionName() : trimmedName
                let collection = catalogCoordinator.makeNewCollection(named: name)

                workspace.collections.append(collection)
                persistWorkspace()
                infoMessage = "Collection '\(name)' created."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func duplicateCollection(_ collection: CollectionModel, named rawName: String) {
        Task {
            do {
                try await ensureActiveWorkspaceExistsIfNeeded()
                let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

                if let validationMessage = collectionNameValidationMessage(trimmedName) {
                    errorMessage = validationMessage
                    return
                }

                var duplicatedCollection = catalogCoordinator.cloneCollection(collection)
                duplicatedCollection.info.name = trimmedName
                workspace.collections.append(duplicatedCollection)
                persistWorkspace(syncSharedCollections: true, syncSharedEnvironments: false)
                infoMessage = "Collection '\(trimmedName)' cloned."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func newRequest(in collection: CollectionModel) {
        guard let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        let request = APIRequestModel(
            name: "New Request",
            method: .get,
            url: "https://postman-echo.com/get"
        )
        let node = CollectionNode(
            name: request.name,
            kind: .request,
            request: request
        )

        workspace.collections[collectionIndex].items.append(node)

        let tab = RequestTabState(
            request: request,
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedRequest: request,
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            sourceCollectionID: collection.id,
            sourceNodeID: node.id
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistWorkspace()
    }

    public func duplicateCurrentRequest() {
        guard let currentTab else { return }
        let duplicated = RequestTabState(
            request: APIRequestModel(
                name: "\(currentTab.request.name) Copy",
                transportKind: currentTab.request.transportKind,
                httpRequestTargetKind: currentTab.request.httpRequestTargetKind,
                method: currentTab.request.method,
                url: currentTab.request.url,
                queryItems: currentTab.request.queryItems,
                pathVariables: currentTab.request.pathVariables,
                headers: currentTab.request.headers,
                cookies: currentTab.request.cookies,
                auth: currentTab.request.auth,
                body: currentTab.request.body,
                scripts: currentTab.request.scripts,
                localVariables: currentTab.request.localVariables,
                timeoutSeconds: currentTab.request.timeoutSeconds,
                retryOn206Count: currentTab.request.retryOn206Count,
                retryOn206DelayMilliseconds: currentTab.request.retryOn206DelayMilliseconds,
                tlsValidationMode: currentTab.request.tlsValidationMode,
                minimumTLSVersion: currentTab.request.minimumTLSVersion,
                webSocketSubprotocols: currentTab.request.webSocketSubprotocols,
                webSocketOpenTimeoutSeconds: currentTab.request.webSocketOpenTimeoutSeconds,
                webSocketReconnectAttempts: currentTab.request.webSocketReconnectAttempts,
                webSocketReconnectIntervalMilliseconds: currentTab.request.webSocketReconnectIntervalMilliseconds,
                webSocketMaximumMessageSizeMB: currentTab.request.webSocketMaximumMessageSizeMB,
                webSocketPingIntervalSeconds: currentTab.request.webSocketPingIntervalSeconds,
                webSocketKeepAliveMessage: currentTab.request.webSocketKeepAliveMessage,
                webSocketKeepAliveIntervalSeconds: currentTab.request.webSocketKeepAliveIntervalSeconds,
                awsAccessPortalURLTemplate: currentTab.request.awsAccessPortalURLTemplate
            ),
            selectedEnvironmentID: currentTab.selectedEnvironmentID,
            pendingEnvironmentVariables: currentTab.pendingEnvironmentVariables,
            persistedRequest: APIRequestModel(
                name: "\(currentTab.request.name) Copy",
                transportKind: currentTab.request.transportKind,
                httpRequestTargetKind: currentTab.request.httpRequestTargetKind,
                method: currentTab.request.method,
                url: currentTab.request.url,
                queryItems: currentTab.request.queryItems,
                pathVariables: currentTab.request.pathVariables,
                headers: currentTab.request.headers,
                cookies: currentTab.request.cookies,
                auth: currentTab.request.auth,
                body: currentTab.request.body,
                scripts: currentTab.request.scripts,
                localVariables: currentTab.request.localVariables,
                timeoutSeconds: currentTab.request.timeoutSeconds,
                retryOn206Count: currentTab.request.retryOn206Count,
                retryOn206DelayMilliseconds: currentTab.request.retryOn206DelayMilliseconds,
                tlsValidationMode: currentTab.request.tlsValidationMode,
                minimumTLSVersion: currentTab.request.minimumTLSVersion,
                webSocketSubprotocols: currentTab.request.webSocketSubprotocols,
                webSocketOpenTimeoutSeconds: currentTab.request.webSocketOpenTimeoutSeconds,
                webSocketReconnectAttempts: currentTab.request.webSocketReconnectAttempts,
                webSocketReconnectIntervalMilliseconds: currentTab.request.webSocketReconnectIntervalMilliseconds,
                webSocketMaximumMessageSizeMB: currentTab.request.webSocketMaximumMessageSizeMB,
                webSocketPingIntervalSeconds: currentTab.request.webSocketPingIntervalSeconds,
                webSocketKeepAliveMessage: currentTab.request.webSocketKeepAliveMessage,
                webSocketKeepAliveIntervalSeconds: currentTab.request.webSocketKeepAliveIntervalSeconds,
                awsAccessPortalURLTemplate: currentTab.request.awsAccessPortalURLTemplate
            ),
            persistedSelectedEnvironmentID: currentTab.selectedEnvironmentID,
            persistedEnvironmentVariables: currentTab.pendingEnvironmentVariables,
            sourceCollectionID: currentTab.sourceCollectionID
        )
        tabs.append(duplicated)
        selectedTabID = duplicated.id
        persistPendingChanges(for: duplicated)
    }

    public func closeTab(_ tab: RequestTabState) {
        cancelWebSocketTasks(for: tab)
        tab.task?.cancel()
        if let connection = tab.webSocketConnection {
            Task {
                await connection.disconnect()
            }
            tab.webSocketConnection = nil
        }
        if let collectionID = tab.sourceCollectionID,
           let nodeID = tab.sourceNodeID {
            removeDraft(nodeID: nodeID, collectionID: collectionID)
        } else {
            removeStandaloneDraft(tabID: tab.id)
        }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id {
            selectedTabID = tabs.last?.id
        }
        if tabs.isEmpty {
            newRequest()
        } else {
            persistWorkspace()
        }
    }

    public func open(request node: CollectionNode, in collection: CollectionModel) async {
        await refreshPersistedVariableStoresFromDisk()
        openRequestImmediately(node, in: collection)
    }

    private func openRequestImmediately(_ node: CollectionNode, in collection: CollectionModel) {
        guard var request = node.request else { return }
        let draft = draftState(for: node.id, collectionID: collection.id)
        if let draft {
            request = draft.request
        }
        request.scripts = CollectionScriptSupport.mergeScripts(node.scripts, request.scripts)

        let savedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)

        if let existing = tabs.first(where: { $0.sourceNodeID == node.id }) {
            selectedTabID = existing.id
            return
        }

        let selectedEnvironmentID = draft?.selectedEnvironmentID ?? workspace.activeEnvironmentID
        let persistedSelectedEnvironmentID = draft?.persistedSelectedEnvironmentID
            ?? draft?.selectedEnvironmentID
            ?? workspace.activeEnvironmentID

        let tab = RequestTabState(
            request: request,
            selectedEnvironmentID: selectedEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments),
            persistedRequest: draft?.persistedRequest ?? savedRequest,
            persistedSelectedEnvironmentID: persistedSelectedEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: persistedSelectedEnvironmentID, in: workspace.environments),
            sourceCollectionID: collection.id,
            sourceNodeID: node.id
        )
        tabs.append(tab)
        selectedTabID = tab.id
    }

    public func open(history entry: HistoryEntry) {
        let tab = RequestTabState(
            request: entry.request,
            response: entry.response,
            consoleLogs: ["Loaded from history: \(entry.createdAt.formatted())"],
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedRequest: entry.request,
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments)
        )
        tabs.append(tab)
        selectedTabID = tab.id
    }

    public func saveCurrentRequest() {
        guard let tab = currentTab else { return }
        persistRequestToWorkspace(for: tab, preferredCollectionID: nil)
    }

    private func persistRequestToWorkspace(for tab: RequestTabState, preferredCollectionID: UUID?) {
        var targetCollectionID = tab.sourceCollectionID
        let previousNodeID = tab.sourceNodeID

        if targetCollectionID == nil {
            targetCollectionID = preferredCollectionID ?? workspace.collections.first?.id
        }

        guard let collectionID = targetCollectionID,
              let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collectionID }) else {
            tab.persistedRequest = tab.request
            tab.persistedSelectedEnvironmentID = tab.selectedEnvironmentID
            tab.persistedEnvironmentVariables = tab.pendingEnvironmentVariables
            persistDraft(for: tab, syncNow: true)
            return
        }

        let node = CollectionNode(
            id: tab.sourceNodeID ?? UUID(),
            name: tab.request.name,
            kind: .request,
            request: tab.request,
            responses: [],
            scripts: tab.request.scripts,
            auth: tab.request.auth
        )

        if let sourceNodeID = tab.sourceNodeID,
           workspace.collections[collectionIndex].items.contains(where: { contains(nodeID: sourceNodeID, in: $0) }) {
            workspace.collections[collectionIndex].items = workspace.collections[collectionIndex].items.map {
                update(nodeID: sourceNodeID, in: $0, with: node)
            }
        } else {
            workspace.collections[collectionIndex].items.append(node)
            tab.sourceNodeID = node.id
            tab.sourceCollectionID = collectionID
        }

        removeDraft(nodeID: previousNodeID, collectionID: collectionID)
        removeDraft(nodeID: tab.sourceNodeID, collectionID: collectionID)
        removeStandaloneDraft(tabID: tab.id)
        tab.persistedRequest = tab.request
        tab.persistedSelectedEnvironmentID = tab.selectedEnvironmentID
        tab.persistedEnvironmentVariables = tab.pendingEnvironmentVariables
        persistDraft(for: tab, syncNow: true)
        persistWorkspace()
    }

    public func saveCurrentEnvironmentChanges() {
        persistedSharedEnvironments = workspace.environments
        tabs.forEach { persistDraft(for: $0, syncNow: true) }
        persistWorkspace()
    }

    public func sendCurrentRequest() {
        guard let tabID = currentTab?.id else { return }
        sendRequest(forTabID: tabID)
    }

    /// Envía la petición HTTP/Lambda o inicia conexión WebSocket de la **pestaña indicada** (p. ej. iPad con varias pestañas sin depender solo de `selectedTabID`).
    public func sendRequest(forTabID tabID: UUID) {
        #if os(macOS)
        if NSApp != nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        #endif

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPersistedVariableStoresFromDisk()
            guard let tab = self.tabs.first(where: { $0.id == tabID }) else {
                return
            }
            self.refreshTabEnvironmentSnapshotFromWorkspace(for: tab)

            switch tab.request.transportKind {
            case .http, .invokeLambda:
                self.send(tab: tab)
            case .webSocket:
                self.connectWebSocket(tab: tab)
            }
        }
    }

    private func send(tab: RequestTabState) {
        tab.task?.cancel()
        tab.isSending = true
        persistDraft(for: tab, syncNow: true)
        let methodLabel = tab.request.isLambdaInvoke ? HTTPMethod.post.rawValue : tab.request.method.rawValue
        let envLine = "Entorno: \(executionEnvironmentDisplayName(for: tab))"
        tab.consoleLogs = [envLine, "URL plantilla: \(tab.request.url)", "Enviando \(methodLabel)…"]

        let collection = collection(for: tab)
        let effectiveRequest = CollectionScriptSupport.enrichedRequest(
            from: tab.request,
            collection: collection,
            sourceNodeID: tab.sourceNodeID
        )
        ensureEnvironmentExistsIfRequired(for: tab, collection: collection, request: effectiveRequest)
        let globals = workspace.globalVariables
        let environment = environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments)
        let collectionVariables = collection?.variables ?? []

        tab.task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }

            do {
                let outcome = try await requestTabCoordinator.execute(
                    request: effectiveRequest,
                    globals: globals,
                    collectionVariables: collectionVariables,
                    environmentVariables: environment,
                    workspaceEnvironments: self.workspace.environments,
                    activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                    utilityLibraries: self.workspace.utilityLibraries
                )

                if Task.isCancelled { return }

                tab.response = outcome.response
                tab.rawRequestText = outcome.rawRequest
                tab.rawResponseText = outcome.rawResponse
                if let updatedRequestHeaders = outcome.updatedRequestHeaders {
                    tab.request.headers = updatedRequestHeaders
                }
                if let updatedRequestQueryItems = outcome.updatedRequestQueryItems {
                    tab.request.queryItems = updatedRequestQueryItems
                }
                if let updatedRequestBody = outcome.updatedRequestBody {
                    tab.request.body = updatedRequestBody
                }
                let tail = outcome.logs.isEmpty ? ["Request completed successfully."] : outcome.logs
                tab.consoleLogs = [envLine] + tail
                tab.isSending = false
                self.applyExecutionVariableUpdates(
                    to: tab,
                    updatedGlobals: outcome.updatedGlobals,
                    updatedCollection: outcome.updatedCollection,
                    updatedEnvironment: outcome.updatedEnvironment,
                    updatedEnvironments: outcome.updatedEnvironments,
                    activeEnvironmentID: outcome.activeEnvironmentID,
                    updatedLocal: outcome.updatedLocal
                )
                self.workspace.history.insert(
                    HistoryEntry(request: tab.request, response: outcome.response),
                    at: 0
                )
                self.workspace.history = Array(self.workspace.history.prefix(100))
                self.persistWorkspace(syncSharedData: false)
            } catch is CancellationError {
                tab.consoleLogs = [envLine, "URL plantilla: \(tab.request.url)", "Request cancelled."]
                tab.isSending = false
            } catch {
                tab.consoleLogs = [envLine, "URL plantilla: \(tab.request.url)", "Error: \(error.localizedDescription)"]
                tab.isSending = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func connectWebSocket(
        tab: RequestTabState,
        reconnectAttempt: Int = 0,
        resetSessionHistory: Bool = true
    ) {
        cancelWebSocketTasks(for: tab)
        if let connection = tab.webSocketConnection {
            Task {
                await connection.disconnect()
            }
            tab.webSocketConnection = nil
        }

        tab.task?.cancel()
        tab.response = nil
        tab.rawResponseText = nil
        tab.isSending = true
        tab.webSocketConnectionState = .connecting
        tab.webSocketReconnectAttempt = reconnectAttempt
        let wsEnvLine = "Entorno: \(executionEnvironmentDisplayName(for: tab))"
        if resetSessionHistory {
            tab.consoleLogs = [
                wsEnvLine,
                "URL plantilla: \(tab.request.url)",
                "Conectando WebSocket…",
            ]
            tab.webSocketTranscript = [WebSocketTranscriptEntry(direction: .system, body: "Opening WebSocket connection...")]
            tab.webSocketPingSentCount = 0
            tab.webSocketLastPingSentAt = nil
        } else {
            tab.consoleLogs.append(wsEnvLine)
            tab.consoleLogs.append("URL plantilla: \(tab.request.url)")
            tab.consoleLogs.append("Reconnecting WebSocket…")
            appendWebSocketTranscript(
                WebSocketTranscriptEntry(direction: .system, body: "Opening WebSocket connection (attempt \(reconnectAttempt))..."),
                to: tab
            )
        }
        persistDraft(for: tab, syncNow: true)

        let collection = collection(for: tab)
        let effectiveRequest = CollectionScriptSupport.enrichedRequest(
            from: tab.request,
            collection: collection,
            sourceNodeID: tab.sourceNodeID
        )
        ensureEnvironmentExistsIfRequired(for: tab, collection: collection, request: effectiveRequest)
        let globals = workspace.globalVariables
        let environment = environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments)
        let collectionVariables = collection?.variables ?? []

        tab.task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }

            var preparedOutcome: WebSocketPreparationOutcome?

            do {
                let prepared = try self.webSocketCoordinator.prepareConnection(
                    request: effectiveRequest,
                    globals: globals,
                    collectionVariables: collectionVariables,
                    environmentVariables: environment,
                    workspaceEnvironments: self.workspace.environments,
                    activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                    utilityLibraries: self.workspace.utilityLibraries
                )
                preparedOutcome = prepared
                let connection = try await self.connectWebSocketWithTimeout(
                    prepared: prepared,
                    request: effectiveRequest
                )

                if Task.isCancelled {
                    await connection.disconnect()
                    return
                }

                tab.webSocketConnection = connection
                tab.rawRequestText = prepared.rawRequest
                if let updatedRequestHeaders = prepared.updatedRequestHeaders {
                    tab.request.headers = updatedRequestHeaders
                }
                if let updatedRequestQueryItems = prepared.updatedRequestQueryItems {
                    tab.request.queryItems = updatedRequestQueryItems
                }
                if let updatedRequestBody = prepared.updatedRequestBody {
                    tab.request.body = updatedRequestBody
                }
                if resetSessionHistory {
                    tab.consoleLogs = [wsEnvLine] + prepared.logs + ["WebSocket connected."]
                } else {
                    tab.consoleLogs.append(contentsOf: prepared.logs)
                    tab.consoleLogs.append("WebSocket reconnected.")
                }
                tab.webSocketConnectionState = .connected
                tab.isSending = false
                tab.webSocketReconnectAttempt = 0
                self.applyExecutionVariableUpdates(
                    to: tab,
                    updatedGlobals: prepared.updatedGlobals,
                    updatedCollection: prepared.updatedCollection,
                    updatedEnvironment: prepared.updatedEnvironment,
                    updatedEnvironments: prepared.updatedEnvironments,
                    activeEnvironmentID: prepared.activeEnvironmentID,
                    updatedLocal: prepared.updatedLocal
                )
                self.appendWebSocketTranscript(
                    WebSocketTranscriptEntry(
                        direction: .system,
                        body: resetSessionHistory
                            ? "Connected to \(effectiveRequest.url)"
                            : "Reconnected to \(effectiveRequest.url)"
                    ),
                    to: tab
                )
                self.startWebSocketAutomationTasks(for: tab, request: effectiveRequest, connection: connection)
                self.persistWorkspace(syncSharedData: false)

                tab.webSocketReceiveTask = await connection.startReceiving { [weak self, weak tab] event in
                    guard let self, let tab else { return }
                    await MainActor.run {
                        switch event {
                        case .entry(let entry):
                            if self.messageExceedsConfiguredLimit(entry.body, for: tab.request) {
                                let limit = tab.request.webSocketMaximumMessageSizeMB
                                let note = "Incoming message ignored because it exceeded the configured limit of \(limit) MB."
                                self.appendWebSocketTranscript(
                                    WebSocketTranscriptEntry(direction: .system, body: note),
                                    to: tab
                                )
                                tab.consoleLogs.append(note)
                                return
                            }
                            self.appendWebSocketTranscript(entry, to: tab)
                            let collection = self.collection(for: tab)
                            let outcome = self.webSocketCoordinator.executeIncomingMessageScripts(
                                message: entry.body,
                                request: tab.request,
                                globals: self.workspace.globalVariables,
                                collectionVariables: collection?.variables ?? [],
                                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                                workspaceEnvironments: self.workspace.environments,
                                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                                utilityLibraries: self.workspace.utilityLibraries
                            )
                            self.applyExecutionVariableUpdates(
                                to: tab,
                                updatedGlobals: outcome.updatedGlobals,
                                updatedCollection: outcome.updatedCollection,
                                updatedEnvironment: outcome.updatedEnvironment,
                                updatedEnvironments: outcome.updatedEnvironments,
                                activeEnvironmentID: outcome.activeEnvironmentID,
                                updatedLocal: outcome.updatedLocal
                            )
                            self.persistWorkspace(syncSharedData: false)
                            if !outcome.logs.isEmpty {
                                tab.consoleLogs.append(contentsOf: outcome.logs)
                            }
                            if outcome.shouldDisconnect {
                                tab.consoleLogs.append("WebSocket disconnect requested by script.")
                                self.disconnectWebSocket(
                                    tab: tab,
                                    doneCause: "Disconnected by script.",
                                    consoleMessage: "WebSocket disconnected by script."
                                )
                            }
                        case .closed(let message):
                            self.appendWebSocketTranscript(
                                WebSocketTranscriptEntry(direction: .system, body: message),
                                to: tab
                            )
                            let collection = self.collection(for: tab)
                            let outcome = self.webSocketCoordinator.executeDoneScripts(
                                cause: message,
                                request: tab.request,
                                globals: self.workspace.globalVariables,
                                collectionVariables: collection?.variables ?? [],
                                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                                workspaceEnvironments: self.workspace.environments,
                                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                                utilityLibraries: self.workspace.utilityLibraries
                            )
                            self.applyExecutionVariableUpdates(
                                to: tab,
                                updatedGlobals: outcome.updatedGlobals,
                                updatedCollection: outcome.updatedCollection,
                                updatedEnvironment: outcome.updatedEnvironment,
                                updatedEnvironments: outcome.updatedEnvironments,
                                activeEnvironmentID: outcome.activeEnvironmentID,
                                updatedLocal: outcome.updatedLocal
                            )
                            self.persistWorkspace(syncSharedData: false)
                            tab.consoleLogs.append(message)
                            if !outcome.logs.isEmpty {
                                tab.consoleLogs.append(contentsOf: outcome.logs)
                            }
                            self.cancelWebSocketTasks(for: tab)
                            tab.webSocketConnection = nil
                            tab.isSending = false
                            tab.task = nil
                            if !self.scheduleWebSocketReconnectIfPossible(for: tab, reason: message) {
                                tab.webSocketReconnectAttempt = 0
                                tab.webSocketConnectionState = .disconnected
                            }
                        case .failure(let message):
                            self.appendWebSocketTranscript(
                                WebSocketTranscriptEntry(direction: .system, body: "Receive error: \(message)"),
                                to: tab
                            )
                            let collection = self.collection(for: tab)
                            let outcome = self.webSocketCoordinator.executeDoneScripts(
                                cause: message,
                                request: tab.request,
                                globals: self.workspace.globalVariables,
                                collectionVariables: collection?.variables ?? [],
                                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                                workspaceEnvironments: self.workspace.environments,
                                activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                                utilityLibraries: self.workspace.utilityLibraries
                            )
                            self.applyExecutionVariableUpdates(
                                to: tab,
                                updatedGlobals: outcome.updatedGlobals,
                                updatedCollection: outcome.updatedCollection,
                                updatedEnvironment: outcome.updatedEnvironment,
                                updatedEnvironments: outcome.updatedEnvironments,
                                activeEnvironmentID: outcome.activeEnvironmentID,
                                updatedLocal: outcome.updatedLocal
                            )
                            self.persistWorkspace(syncSharedData: false)
                            tab.consoleLogs.append("Receive error: \(message)")
                            if !outcome.logs.isEmpty {
                                tab.consoleLogs.append(contentsOf: outcome.logs)
                            }
                            self.cancelWebSocketTasks(for: tab)
                            tab.webSocketConnection = nil
                            tab.isSending = false
                            tab.task = nil
                            if !self.scheduleWebSocketReconnectIfPossible(for: tab, reason: message) {
                                tab.webSocketReconnectAttempt = 0
                                tab.webSocketConnectionState = .failed
                                self.errorMessage = message
                            }
                        }
                    }
                }
            } catch is CancellationError {
                tab.consoleLogs = ["WebSocket connection cancelled."]
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .disconnected
                tab.isSending = false
            } catch {
                if let preparedOutcome {
                    tab.rawRequestText = preparedOutcome.rawRequest
                    if let updatedRequestHeaders = preparedOutcome.updatedRequestHeaders {
                        tab.request.headers = updatedRequestHeaders
                    }
                    if let updatedRequestQueryItems = preparedOutcome.updatedRequestQueryItems {
                        tab.request.queryItems = updatedRequestQueryItems
                    }
                    if let updatedRequestBody = preparedOutcome.updatedRequestBody {
                        tab.request.body = updatedRequestBody
                    }
                    self.applyExecutionVariableUpdates(
                        to: tab,
                        updatedGlobals: preparedOutcome.updatedGlobals,
                        updatedCollection: preparedOutcome.updatedCollection,
                        updatedEnvironment: preparedOutcome.updatedEnvironment,
                        updatedEnvironments: preparedOutcome.updatedEnvironments,
                        activeEnvironmentID: preparedOutcome.activeEnvironmentID,
                        updatedLocal: preparedOutcome.updatedLocal
                    )
                    tab.consoleLogs = preparedOutcome.logs + ["Error: \(error.localizedDescription)"]
                    self.appendWebSocketTranscript(
                        WebSocketTranscriptEntry(direction: .system, body: "Connection error: \(error.localizedDescription)"),
                        to: tab
                    )
                } else {
                    tab.consoleLogs = ["Error: \(error.localizedDescription)"]
                }
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .failed
                tab.isSending = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func sendCurrentWebSocketMessage() {
        guard let tabID = currentTab?.id else { return }
        sendWebSocketMessage(forTabID: tabID)
    }

    /// Envía el mensaje saliente WebSocket usando el cuerpo/mensaje de la petición de la pestaña indicada.
    public func sendWebSocketMessage(forTabID tabID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let tab = self.tabs.first(where: { $0.id == tabID }) else { return }
            guard tab.request.transportKind == .webSocket else { return }
            guard tab.webSocketConnectionState == .connected,
                let connection = tab.webSocketConnection
            else {
                self.errorMessage = "Connect the WebSocket before sending messages."
                return
            }

            await self.refreshPersistedVariableStoresFromDisk()
            self.refreshTabEnvironmentSnapshotFromWorkspace(for: tab)

            let collection = self.collection(for: tab)
            let collectionVariables = collection?.variables ?? []
            let payload = self.webSocketCoordinator.resolveOutgoingMessage(
                from: tab.request,
                globals: self.workspace.globalVariables,
                collectionVariables: collectionVariables,
                environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                utilityLibraries: self.workspace.utilityLibraries
            )

            guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.errorMessage = "The outgoing WebSocket message is empty."
                return
            }

            self.sendWebSocketMessage(
                payload,
                on: connection,
                for: tab,
                transcriptDirection: .outgoing,
                consoleMessage: "Sent WebSocket message (\(payload.count) chars)."
            )
        }
    }

    private func sendWebSocketMessage(
        _ payload: String,
        on connection: any WebSocketConnectionProtocol,
        for tab: RequestTabState,
        transcriptDirection: WebSocketTranscriptDirection,
        consoleMessage: String
    ) {
        Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                try await connection.send(text: payload)
                await MainActor.run {
                    self.appendWebSocketTranscript(
                        WebSocketTranscriptEntry(direction: transcriptDirection, body: payload),
                        to: tab
                    )
                    tab.consoleLogs.append(consoleMessage)
                }
            } catch {
                await MainActor.run {
                    tab.consoleLogs.append("Send error: \(error.localizedDescription)")
                    tab.webSocketConnectionState = .failed
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func disconnectCurrentWebSocket() {
        guard let currentTab else { return }
        disconnectWebSocket(tab: currentTab)
    }

    private func disconnectWebSocket(
        tab: RequestTabState,
        doneCause: String = "Disconnected.",
        consoleMessage: String = "WebSocket disconnected."
    ) {
        guard tab.webSocketConnectionState != .disconnecting else {
            return
        }
        cancelWebSocketTasks(for: tab)
        tab.task?.cancel()
        guard let connection = tab.webSocketConnection else {
            tab.webSocketReconnectAttempt = 0
            tab.webSocketConnectionState = .disconnected
            tab.isSending = false
            return
        }

        tab.webSocketConnectionState = .disconnecting
        tab.isSending = false

        Task { [weak tab] in
            await connection.disconnect()
            await MainActor.run {
                guard let tab else { return }
                let collection = self.collection(for: tab)
                let outcome = self.webSocketCoordinator.executeDoneScripts(
                    cause: doneCause,
                    request: tab.request,
                    globals: self.workspace.globalVariables,
                    collectionVariables: collection?.variables ?? [],
                    environmentVariables: self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
                    workspaceEnvironments: self.workspace.environments,
                    activeEnvironmentID: tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID,
                    utilityLibraries: self.workspace.utilityLibraries
                )
                self.applyExecutionVariableUpdates(
                    to: tab,
                    updatedGlobals: outcome.updatedGlobals,
                    updatedCollection: outcome.updatedCollection,
                    updatedEnvironment: outcome.updatedEnvironment,
                    updatedLocal: outcome.updatedLocal
                )
                self.persistWorkspace(syncSharedData: false)
                tab.webSocketConnection = nil
                tab.task = nil
                tab.webSocketReconnectAttempt = 0
                tab.webSocketConnectionState = .disconnected
                tab.consoleLogs.append(consoleMessage)
                if !outcome.logs.isEmpty {
                    tab.consoleLogs.append(contentsOf: outcome.logs)
                }
                self.appendWebSocketTranscript(
                    WebSocketTranscriptEntry(direction: .system, body: doneCause),
                    to: tab
                )
            }
        }
    }

    private func scheduleWebSocketReconnectIfPossible(for tab: RequestTabState, reason: String) -> Bool {
        let maxAttempts = max(0, tab.request.webSocketReconnectAttempts)
        guard maxAttempts > 0 else {
            return false
        }

        let nextAttempt = tab.webSocketReconnectAttempt + 1
        guard nextAttempt <= maxAttempts else {
            return false
        }

        let delayMilliseconds = max(0, tab.request.webSocketReconnectIntervalMilliseconds)
        let reconnectMessage = delayMilliseconds > 0
            ? "Scheduling reconnect in \(delayMilliseconds) ms (attempt \(nextAttempt) of \(maxAttempts))."
            : "Scheduling reconnect now (attempt \(nextAttempt) of \(maxAttempts))."

        tab.webSocketReconnectAttempt = nextAttempt
        tab.webSocketConnectionState = .connecting
        tab.consoleLogs.append(reconnectMessage)
        appendWebSocketTranscript(
            WebSocketTranscriptEntry(direction: .system, body: "\(reason)\n\(reconnectMessage)"),
            to: tab
        )

        tab.task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }

            if delayMilliseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }

            await MainActor.run {
                guard tab.webSocketConnectionState == .connecting else { return }
                self.connectWebSocket(
                    tab: tab,
                    reconnectAttempt: nextAttempt,
                    resetSessionHistory: false
                )
            }
        }

        return true
    }

    private func messageExceedsConfiguredLimit(_ message: String, for request: APIRequestModel) -> Bool {
        let limitMB = max(0, request.webSocketMaximumMessageSizeMB)
        guard limitMB > 0 else {
            return false
        }

        let sizeInBytes = message.lengthOfBytes(using: .utf8)
        let allowedBytes = limitMB * 1_024 * 1_024
        return sizeInBytes > allowedBytes
    }

    public func cancelCurrentRequest() {
        guard let currentTab else { return }
        cancelRequest(forTabID: currentTab.id)
    }

    /// Cancela envío HTTP en curso o desconecta WebSocket de la pestaña indicada (misma semántica que en Mac).
    public func cancelRequest(forTabID tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        switch tab.request.transportKind {
        case .http, .invokeLambda:
            guard tab.isSending else { return }
            tab.task?.cancel()
        case .webSocket:
            disconnectWebSocket(tab: tab)
        }
    }

    public func importDocument(from url: URL) async {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            switch try documentImportCoordinator.importData(data, fileExtension: url.pathExtension) {
            case .environment(let importedEnvironment):
                upsertEnvironment(importedEnvironment)
                persistWorkspace(syncSharedData: false)
                infoMessage = "Environment '\(importedEnvironment.name)' imported successfully."
            case .collection(let imported):
                workspace.collections.append(imported)
                persistWorkspace()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Descarga el archivo fuente `.zip` de Bitbucket Cloud y configura esa carpeta como almacenamiento compartido.
    /// Repos públicos: deja usuario y contraseña/token vacíos. Repos privados: username Bitbucket + **app password** (token de Bitbucket) u otra credencial que la API acepte en Basic Auth — solo el valor del token, sin HTML.
    public func downloadBitbucketHTTPSRepositoryAndConfigure(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String
    ) {
        switch bitbucketPadCoordinator.planInitialDownload(
            cloneHTTPSURL: cloneHTTPSURL,
            branch: branch,
            bitbucketUsername: bitbucketUsername,
            bitbucketAppPassword: bitbucketAppPassword
        ) {
        case .failure(let error):
            errorMessage = error.message
        case .success(let plan):
            Task { await executeBitbucketPadImport(plan) }
        }
    }

    /// Vuelve a descargar el mismo repo Bitbucket y actualiza el almacenamiento compartido (URL/rama/usuario desde el formulario o desde la última descarga; token vacío en pantalla usa el guardado en llavero).
    public func resyncBitbucketSharedFromBitbucket(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String
    ) {
        switch bitbucketPadCoordinator.planResync(
            cloneHTTPSURL: cloneHTTPSURL,
            branch: branch,
            bitbucketUsername: bitbucketUsername,
            bitbucketAppPassword: bitbucketAppPassword,
            hasSharedRepository: sharedRepositoryURL != nil,
            savedCloneHTTPSURL: workspace.bitbucketPadCloneHTTPSURL,
            savedBranch: workspace.bitbucketPadBranch,
            savedUsername: workspace.bitbucketPadUsername
        ) {
        case .failure(let error):
            errorMessage = error.message
        case .success(let plan):
            Task { await executeBitbucketPadImport(plan) }
        }
    }

    private func executeBitbucketPadImport(_ plan: BitbucketPadCoordinator.ImportPlan) async {
        isBitbucketArchiveDownloadBusy = true
        errorMessage = nil
        defer { isBitbucketArchiveDownloadBusy = false }

        do {
            let result = try await bitbucketPadCoordinator.download(plan: plan) { [persistenceCoordinator] root in
                try await persistenceCoordinator.ensureWorkdirMarker(in: root)
            }
            bitbucketPadCoordinator.applyMetadata(from: result, to: &workspace)
            configureSharedCollectionsDirectory(result.repositoryRoot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func configureSharedCollectionsDirectory(_ url: URL) {
        do {
            try validateRepositoryDirectory(url, requireEmpty: sharedRepositoryURL == nil)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        guard repositoryDirectoryAccess.grantAccess(to: url) else {
            errorMessage = "macOS did not grant access to the selected folder. Try choosing it again."
            return
        }

        guard let bookmarkData = repositoryDirectoryAccess.makeBookmarkData(for: url) else {
            repositoryDirectoryAccess.releaseAccess()
            errorMessage = "Could not save folder permission for the selected directory. Try choosing it again."
            return
        }

        workspace.sharedCollectionsDirectoryPath = url.path
        workspace.sharedCollectionsDirectoryBookmarkData = bookmarkData
        Task {
            do {
                try await self.persistenceCoordinator.ensureWorkdirMarker(in: url)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: true)
        }
        persistWorkspace(syncSharedData: false)
        infoMessage = "Shared storage configured: \(url.path)"
    }

    public func connectGitRepository(using remoteInput: String) {
        guard let repositoryRoot = sharedRepositoryURL else {
            errorMessage = "Select the shared storage folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "connect"
        gitOutput = ""
        Task {
            do {
                let result = try await gitSessionCoordinator.connectFlow(
                    at: repositoryRoot,
                    remoteInput: remoteInput,
                    credentials: nil,
                    onOutput: makeGitOutputHandler()
                )
                switch result.state {
                case .connected:
                    await completeConnectedGitFlow(
                        at: repositoryRoot,
                        remoteURL: result.remoteURL,
                        connectOutput: result.output,
                        successMessage: "Git configured, synchronized, and refreshed without deleting the current workspaces."
                    )
                case .authenticationRequired:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        if result.authKind == .https {
                            self.gitCredentialPrompt = GitCredentialPrompt(
                                remoteInput: remoteInput,
                                remoteURL: result.remoteURL ?? remoteInput,
                                provider: result.provider,
                                authKind: result.authKind,
                                message: result.output,
                                instructions: result.credentialInstructions ?? "Enter the credentials required by your Git provider to continue.",
                                preferredMode: result.preferredCredentialMode ?? .token,
                                helpURL: result.helpURL
                            )
                            self.infoMessage = "Git needs credentials. Complete the form to connect this repository."
                        } else {
                            if let helpURL = result.helpURL {
                                Self.openExternalURL(helpURL)
                            }
                            self.errorMessage = "Git needs authentication with \(result.provider.displayName). The browser was opened with the recommended setup page."
                        }
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                case .gitMissing:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        if let helpURL = result.helpURL {
                            Self.openExternalURL(helpURL)
                        }
                        self.errorMessage = "Git is not installed. The browser was opened with the install page for macOS."
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGitBusy = false
                    self.gitBusyOperation = nil
                }
            }
        }
    }

    public func submitGitCredentials(mode: GitCredentialMode, username: String, secret: String) {
        guard let repositoryRoot = sharedRepositoryURL,
              let prompt = gitCredentialPrompt else {
            errorMessage = "Start the Git connection flow first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "credentials"
        gitOutput = ""
        Task {
            do {
                let result = try await gitSessionCoordinator.connectFlow(
                    at: repositoryRoot,
                    remoteInput: prompt.remoteInput,
                    credentials: GitCredentialInput(mode: mode, username: username, secret: secret),
                    onOutput: makeGitOutputHandler()
                )

                switch result.state {
                case .connected:
                    await completeConnectedGitFlow(
                        at: repositoryRoot,
                        remoteURL: result.remoteURL,
                        connectOutput: result.output,
                        successMessage: "Git authenticated, synchronized, and refreshed successfully."
                    )
                case .authenticationRequired:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        self.gitCredentialPrompt = GitCredentialPrompt(
                            remoteInput: prompt.remoteInput,
                            remoteURL: result.remoteURL ?? prompt.remoteURL,
                            provider: result.provider,
                            authKind: result.authKind,
                            message: result.output,
                            instructions: result.credentialInstructions ?? prompt.instructions,
                            preferredMode: result.preferredCredentialMode ?? prompt.preferredMode,
                            helpURL: result.helpURL ?? prompt.helpURL
                        )
                        self.errorMessage = "The provided credentials were not accepted. Review the form and try again."
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                case .gitMissing:
                    await MainActor.run {
                        self.gitOutput = result.output
                        self.gitRemoteDescription = result.remoteURL
                        self.gitCredentialPrompt = nil
                        self.errorMessage = "Git is not installed. The browser was opened with the install page for macOS."
                        self.isGitBusy = false
                        self.gitBusyOperation = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGitBusy = false
                    self.gitBusyOperation = nil
                }
            }
        }
    }

    public func cancelGitCredentialPrompt() {
        gitCredentialPrompt = nil
    }

    public func createWorkspace(named name: String) {
        guard let repositoryRoot = sharedRepositoryURL else {
            errorMessage = "Configure the Git repository folder first."
            return
        }

        Task {
            do {
                let createdName = try await persistenceCoordinator.createWorkspace(named: name, in: repositoryRoot)
                await MainActor.run {
                    self.workspace.activeWorkspaceName = createdName
                }
                await refreshWorkspacesAndLoadCurrent(forceInfoMessage: true)
                await MainActor.run {
                    self.infoMessage = "Workspace '\(createdName)' created."
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func selectWorkspace(named name: String) {
        workspace.activeWorkspaceName = name
        tabs.removeAll()
        selectedTabID = nil
        persistWorkspace(syncSharedData: false)
        Task {
            await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: true)
            await MainActor.run {
                self.restoreDraftTabsIfNeeded()
                self.openFirstRequestIfNeeded()
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    public func importCollectionsFromFolder(_ url: URL) {
        Task {
            do {
                let imported = try await persistenceCoordinator.importCollections(from: url)
                guard !imported.isEmpty else {
                    await MainActor.run {
                        self.errorMessage = "No valid Postman collection JSON files were found in the selected folder."
                    }
                    return
                }

                let existingNames = Set(self.workspace.collections.map(\.info.name))
                let newCollections = imported.filter { !existingNames.contains($0.info.name) }
                self.workspace.collections.append(contentsOf: newCollections)
                self.persistWorkspace()
                self.infoMessage = "Imported \(newCollections.count) collections from \(url.lastPathComponent)."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func loadCollectionsFromSharedDirectory() {
        Task {
            await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: true)
        }
    }

    public func exportCollectionsToSharedDirectory() {
        Task {
            do {
                guard let workspaceRoot = activeWorkspaceDirectoryURL else {
                    throw AppError.persistence("Select a workspace inside the shared repository first.")
                }
                var exportSnapshot = workspace
                exportSnapshot.flows = flowsPortableForPersistence(workspace.flows, collections: workspace.collections)
                try await persistenceCoordinator.saveSharedGitSnapshot(
                    collections: workspace.collections,
                    environments: workspace.environments,
                    utilities: workspace.utilityLibraries,
                    flows: exportSnapshot.flows,
                    snapshot: exportSnapshot,
                    to: workspaceRoot
                )
                self.infoMessage = "Workspace exported to \(workspaceRoot.path)."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func gitStatus() {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "status"
        gitOutput = ""
        Task {
            do {
                let result = try await gitSessionCoordinator.status(
                    at: root,
                    onOutput: makeGitOutputHandler()
                )
                await MainActor.run {
                    if result.output.isEmpty {
                        self.appendGitOutput("Working tree clean.\n")
                    }
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func gitPull() {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        gitSessionCoordinator.resetStashFlags()
        isGitBusy = true
        gitBusyOperation = "pull"
        gitOutput = ""
        Task {
            do {
                if self.isBitbucketPadMirrorWorkspace {
                    self.gitSessionCoordinator.resetStashFlags()
                    self.gitPullRecoveryPrompt = nil
                    try await self.applyPullOutcome(
                        try await self.gitSessionCoordinator.performHardResetPull(
                            at: root,
                            onOutput: self.makeGitOutputHandler()
                        ),
                        at: root
                    )
                    return
                }

                let gate = await evaluateSharedGitPushGate(at: root)
                await MainActor.run {
                    self.applyPushGate(gate)
                }

                let changedPaths = try await gitSessionCoordinator.localChangesForPull(at: root)
                if !changedPaths.isEmpty {
                    await MainActor.run {
                        self.gitPullRecoveryPrompt = GitPullRecoveryPrompt(changedPaths: changedPaths)
                        self.finishGitBusyState()
                    }
                    return
                }

                try await applyPullOutcome(
                    try await gitSessionCoordinator.performPull(
                        at: root,
                        restoringDeletedPaths: nil,
                        stashPopWhenDone: false,
                        onOutput: makeGitOutputHandler()
                    ),
                    at: root
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func confirmGitPullRecoverDeletedFiles() {
        guard let root = sharedRepositoryURL,
              gitPullRecoveryPrompt != nil else {
            return
        }

        gitPullRecoveryPrompt = nil
        gitSessionCoordinator.resetStashFlags()
        isGitBusy = true
        gitBusyOperation = "pull"
        gitOutput = ""
        Task {
            do {
                let revertResult = try await gitSessionCoordinator.revertLocalChanges(at: root)
                if !revertResult.output.isEmpty {
                    await MainActor.run {
                        self.appendGitOutput(revertResult.output)
                        self.appendGitOutput("\n")
                    }
                }
                try await applyPullOutcome(
                    try await gitSessionCoordinator.performPull(
                        at: root,
                        restoringDeletedPaths: nil,
                        stashPopWhenDone: false,
                        onOutput: makeGitOutputHandler()
                    ),
                    at: root
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func continueGitPullWithoutRecoveringDeletedFiles() {
        gitPullRecoveryPrompt = nil
    }

    public func cancelGitPullRecoveryPrompt() {
        gitPullRecoveryPrompt = nil
    }

    private func evaluateSharedGitPushGate(at root: URL) async -> GitWorkspaceCoordinator.SharedGitPushGate {
        await gitSessionCoordinator.evaluatePushGate(at: root, isReadOnlyMirror: isBitbucketPadMirrorWorkspace)
    }

    private func applyPushGate(_ gate: GitWorkspaceCoordinator.SharedGitPushGate) {
        canPushToSharedGit = gate.canPush
        gitPushDisabledReason = gate.reason
        isSharedGitMergeInProgress = gate.mergeInProgress
    }

    private func finishGitBusyState() {
        isGitBusy = false
        gitBusyOperation = nil
    }

    public func refreshSharedGitPushAvailability() {
        guard let root = sharedRepositoryURL else {
            canPushToSharedGit = false
            gitPushDisabledReason = "Configure the shared Git repository folder first."
            isSharedGitMergeInProgress = false
            return
        }

        if isBitbucketPadMirrorWorkspace {
            canPushToSharedGit = false
            gitPushDisabledReason =
                "Este workspace está vinculado a Bitbucket en solo lectura: no se suben cambios al remoto."
            isSharedGitMergeInProgress = false
            return
        }

        Task {
            let gate = await evaluateSharedGitPushGate(at: root)
            await MainActor.run {
                self.applyPushGate(gate)
            }
        }
    }

    public func confirmGitPullStashAndUpdate() {
        guard let root = sharedRepositoryURL,
              gitPullRecoveryPrompt != nil else {
            return
        }

        gitPullRecoveryPrompt = nil
        gitSessionCoordinator.markPendingStashPopAfterPull(true)
        isGitBusy = true
        gitBusyOperation = "pull"
        gitOutput = ""
        Task {
            do {
                let stashResult = try await gitSessionCoordinator.stashPushForUpdate(
                    at: root,
                    onOutput: makeGitOutputHandler()
                )
                if !stashResult.output.isEmpty {
                    await MainActor.run {
                        self.appendGitOutput(stashResult.output)
                        self.appendGitOutput("\n")
                    }
                }
                guard stashResult.exitCode == 0 else {
                    await MainActor.run {
                        self.errorMessage = stashResult.output.isEmpty ? "Git stash failed." : stashResult.output
                        self.gitSessionCoordinator.resetStashFlags()
                        self.finishGitBusyState()
                    }
                    await MainActor.run {
                        self.refreshSharedGitPushAvailability()
                    }
                    return
                }
                try await applyPullOutcome(
                    try await gitSessionCoordinator.performPull(
                        at: root,
                        restoringDeletedPaths: nil,
                        stashPopWhenDone: true,
                        onOutput: makeGitOutputHandler()
                    ),
                    at: root
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.gitSessionCoordinator.resetStashFlags()
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func gitResolveMergeConflict(path: String, keepLocal: Bool) {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "pull"
        Task {
            do {
                let outcome = try await gitSessionCoordinator.resolveMergeConflict(
                    path: path,
                    keepLocal: keepLocal,
                    at: root,
                    onOutput: makeGitOutputHandler()
                )

                if let mergeCommitOutput = outcome.mergeCommitOutput {
                    await MainActor.run {
                        self.appendGitOutput(mergeCommitOutput)
                        self.appendGitOutput("\n")
                    }
                }
                if outcome.shouldRefreshWorkspace {
                    await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)
                }
                if let stashDropOutput = outcome.stashDropOutput {
                    await MainActor.run {
                        self.appendGitOutput(stashDropOutput)
                        self.appendGitOutput("\n")
                    }
                }
                if outcome.stalledAfterStashPop {
                    await MainActor.run {
                        self.gitMergeConflictPaths = outcome.remainingConflicts
                        self.appendGitOutput("Resolve stash pop conflicts below.\n")
                        self.finishGitBusyState()
                    }
                    refreshSharedGitPushAvailability()
                    return
                }
                if let conflictsResolvedMessage = outcome.conflictsResolvedMessage {
                    await MainActor.run {
                        self.appendGitOutput(conflictsResolvedMessage)
                    }
                }

                await MainActor.run {
                    self.gitMergeConflictPaths = outcome.remainingConflicts
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            }
        }
    }

    public func gitAbortSharedMerge() {
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        isGitBusy = true
        gitBusyOperation = "pull"
        Task {
            do {
                try await gitSessionCoordinator.abortMerge(at: root, onOutput: makeGitOutputHandler())
                await MainActor.run {
                    self.gitMergeConflictPaths = []
                    self.appendGitOutput("Merge aborted.\n")
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                refreshSharedGitPushAvailability()
            }
        }
    }

    public func gitCommitAndPush() {
#if !os(macOS)
        errorMessage =
            "En iPhone e iPad la app no crea commits ni hace push al remoto Git. Publica cambios desde la app para Mac."
        return
#endif
        guard let root = sharedRepositoryURL else {
            errorMessage = "Configure the cloned Git repository folder first."
            return
        }

        if isBitbucketPadMirrorWorkspace {
            errorMessage =
                "Este workspace está vinculado a Bitbucket en solo lectura: no se suben cambios al remoto."
            return
        }

        isGitBusy = true
        gitBusyOperation = "push"
        gitOutput = ""
        Task {
            do {
                let gate = await evaluateSharedGitPushGate(at: root)
                if !gate.canPush {
                    await MainActor.run {
                        self.errorMessage = gate.reason
                            ?? "Push is blocked until the remote is merged locally (run Update) and the working tree is clean."
                        self.applyPushGate(gate)
                        self.finishGitBusyState()
                    }
                    return
                }

                await MainActor.run {
                    self.canPushToSharedGit = true
                    self.gitPushDisabledReason = nil
                    self.isSharedGitMergeInProgress = gate.mergeInProgress
                }

                guard let workspaceRoot = activeWorkspaceDirectoryURL else {
                    throw AppError.persistence("Select a workspace before pushing.")
                }
                var gitSnapshot = workspace
                gitSnapshot.flows = flowsPortableForPersistence(workspace.flows, collections: workspace.collections)
                try await persistenceCoordinator.saveSharedGitSnapshot(
                    collections: pushableCollectionsSnapshot(),
                    environments: pushableEnvironmentsSnapshot(),
                    utilities: workspace.utilityLibraries,
                    flows: gitSnapshot.flows,
                    snapshot: gitSnapshot,
                    to: workspaceRoot
                )
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
                let workspaceName = workspace.activeWorkspaceName ?? "workspace"
                let message = "Update \(workspaceName) \(formatter.string(from: Date()))"
                let result = try await gitSessionCoordinator.commitAndPush(
                    at: root,
                    message: message,
                    onOutput: makeGitOutputHandler()
                )
                await MainActor.run {
                    if result.output.isEmpty {
                        self.appendGitOutput("Commit and push completed.\n")
                    }
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.finishGitBusyState()
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
            }
        }
    }

    public func exportCurrentCollection() -> (name: String, data: Data)? {
        guard let collection = currentCollection else { return nil }

        do {
            return try documentImportCoordinator.exportCollection(collection)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func activateEnvironment(_ environment: EnvironmentProfile?) {
        workspace.activeEnvironmentID = environment?.id
        persistWorkspace(syncSharedData: false)
    }

    @discardableResult
    public func addEnvironment() -> EnvironmentProfile {
        let environment = EnvironmentProfile(name: "New Environment")
        workspace.environments.append(environment)
        workspace.activeEnvironmentID = environment.id
        persistWorkspace(syncSharedData: false)
        return environment
    }

    public func deleteEnvironment(_ environment: EnvironmentProfile) {
        workspace.environments.removeAll { $0.id == environment.id }
        if workspace.activeEnvironmentID == environment.id {
            workspace.activeEnvironmentID = workspace.environments.first?.id
        }
        var drafts = workspace.requestDrafts
        environmentCoordinator.clearReferences(
            to: environment.id,
            tabs: tabs,
            drafts: &drafts
        )
        workspace.requestDrafts = drafts
        persistWorkspace(syncSharedData: false)
    }

    public func updateEnvironment(_ environment: EnvironmentProfile) {
        guard let index = workspace.environments.firstIndex(where: { $0.id == environment.id }) else { return }
        let previousVariables = workspace.environments[index].variables
        workspace.environments[index] = environment
        persistedSharedEnvironments = workspace.environments

        for tab in tabs where (tab.selectedEnvironmentID ?? workspace.activeEnvironmentID) == environment.id {
            tab.pendingEnvironmentVariables = environment.variables
            tab.persistedEnvironmentVariables = environment.variables
            persistDraft(for: tab, syncNow: true)
        }

        for draftIndex in workspace.requestDrafts.indices {
            let draftEnvironmentID = workspace.requestDrafts[draftIndex].selectedEnvironmentID
                ?? workspace.requestDrafts[draftIndex].persistedSelectedEnvironmentID
                ?? workspace.activeEnvironmentID
            guard draftEnvironmentID == environment.id else { continue }
            workspace.requestDrafts[draftIndex].pendingEnvironmentVariables = environment.variables
            workspace.requestDrafts[draftIndex].persistedEnvironmentVariables = environment.variables
        }

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environment.id,
            previousVariables: previousVariables,
            updatedVariables: environment.variables,
            excluding: UUID()
        )

        persistWorkspace()
    }

    public func selectEnvironment(_ environment: EnvironmentProfile?, for tab: RequestTabState) {
        tab.selectedEnvironmentID = environment?.id
        tab.pendingEnvironmentVariables = environmentCoordinator.variables(for: environment?.id, in: workspace.environments)
        tab.persistedEnvironmentVariables = environmentCoordinator.variables(for: environment?.id, in: workspace.environments)
        tab.persistedSelectedEnvironmentID = environment?.id
        if let environment {
            workspace.activeEnvironmentID = environment.id
        }
        persistDraft(for: tab, syncNow: true)
    }

    /// Nombre del entorno cuyas variables se usan al ejecutar esta pestaña (selección de la pestaña o, si es `nil`, el activo del workspace).
    public func executionEnvironmentDisplayName(for tab: RequestTabState) -> String {
        environmentCoordinator.executionDisplayName(
            for: tab,
            environments: workspace.environments,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
    }

    /// Misma semántica que el `Picker` de entorno en Mac: al cambiar, actualiza variables en memoria y el entorno activo del workspace.
    public func environmentPickerBinding(for tab: RequestTabState) -> Binding<UUID?> {
        Binding(
            get: {
                let selectedID = tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID
                guard let selectedID else { return nil }
                return self.workspace.environments.contains(where: { $0.id == selectedID }) ? selectedID : nil
            },
            set: { newValue in
                let environment = newValue.flatMap { id in self.workspace.environments.first(where: { $0.id == id }) }
                self.selectEnvironment(environment, for: tab)
            }
        )
    }

    public func revertPendingChanges(for tab: RequestTabState) {
        tab.request = tab.persistedRequest
        tab.editorRefreshToken = UUID()
        persistDraft(for: tab, syncNow: true)
    }

    public func revertPendingEnvironmentChanges(for tab: RequestTabState) {
        let environmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID
        let currentEnvironmentVariablesBeforeRevert = environmentCoordinator.variables(for: environmentID, in: workspace.environments)

        tab.pendingEnvironmentVariables = tab.persistedEnvironmentVariables

        if let environmentID,
           let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID }) {
            let revertedEnvironmentVariables = tab.persistedEnvironmentVariables ?? []
            workspace.environments[environmentIndex].variables = revertedEnvironmentVariables
            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environmentID,
                previousVariables: currentEnvironmentVariablesBeforeRevert,
                updatedVariables: revertedEnvironmentVariables,
                excluding: tab.id
            )
        }

        persistDraft(for: tab, syncNow: true)
    }

    public func deleteCollection(_ collection: CollectionModel) {
        workspace.collections.removeAll { $0.id == collection.id }
        if let activeWorkspaceName = workspace.activeWorkspaceName {
            workspace.requestDrafts.removeAll {
                $0.workspaceName == activeWorkspaceName && $0.collectionID == collection.id
            }
        }
        tabs.removeAll { $0.sourceCollectionID == collection.id }

        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.last?.id
        }

        if tabs.isEmpty {
            openFirstRequestIfNeeded()
        }

        persistWorkspace(syncSharedData: false)
    }

    public func renameCollection(_ collection: CollectionModel, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        workspace.collections[index].info.name = trimmed
        persistWorkspace()
    }

    /// Duplica un request en la colección (mismo árbol; nuevo id de nodo y de request) e inserta la copia justo debajo del original.
    public func duplicateRequestNode(_ node: CollectionNode, in collection: CollectionModel) {
        guard node.kind == .request, node.request != nil else { return }
        guard let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }
        guard let newNode = makeDuplicatedRequestCollectionNode(from: node) else { return }

        var items = workspace.collections[collectionIndex].items
        if !insertCollectionNode(newNode, afterSiblingID: node.id, in: &items) {
            items.append(newNode)
        }
        workspace.collections[collectionIndex].items = items

        guard let request = newNode.request else { return }
        let tab = RequestTabState(
            request: request,
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedRequest: request,
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            sourceCollectionID: collection.id,
            sourceNodeID: newNode.id
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistWorkspace()
    }

    /// Crea un entorno nuevo copiando variables (y `isEnabled`) del perfil dado. El nombre se recorta; vacío usa nombre sugerido único.
    @discardableResult
    public func duplicateEnvironment(_ profile: EnvironmentProfile, named rawName: String) -> EnvironmentProfile {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? suggestedEnvironmentCloneName(for: profile)
            : environmentCoordinator.makeUniqueName(
                baseName: trimmed,
                existingNames: Set(workspace.environments.map { $0.name.lowercased() })
            )
        let variables = profile.variables.map { VariableValue(key: $0.key, value: $0.value, isEnabled: $0.isEnabled) }
        let copy = EnvironmentProfile(name: name, variables: variables, isEnabled: profile.isEnabled)
        workspace.environments.append(copy)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: true,
            syncSharedFlows: false,
            syncSharedUtilities: false
        )
        infoMessage = "Entorno '\(name)' clonado."
        return copy
    }

    public func deleteRequestNode(_ node: CollectionNode, from collection: CollectionModel) {
        guard let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        workspace.collections[collectionIndex].items = remove(nodeID: node.id, from: workspace.collections[collectionIndex].items)
        removeDraft(nodeID: node.id, collectionID: collection.id)
        tabs.removeAll { $0.sourceNodeID == node.id }

        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.last?.id
        }

        if tabs.isEmpty {
            openFirstRequestIfNeeded()
        }

        persistWorkspace()
    }

    public func renameRequestNode(_ node: CollectionNode, in collection: CollectionModel, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        workspace.collections[collectionIndex].items = workspace.collections[collectionIndex].items.map {
            rename(nodeID: node.id, in: $0, to: trimmed)
        }

        for tab in tabs where tab.sourceNodeID == node.id {
            tab.request.name = trimmed
        }

        persistWorkspace()
    }

    public func deleteHistoryEntry(_ entry: HistoryEntry) {
        workspace.history.removeAll { $0.id == entry.id }
        persistWorkspace(syncSharedData: false)
    }

    public func clearHistory() {
        workspace.history.removeAll()
        persistWorkspace(syncSharedData: false)
    }

    public var currentCollection: CollectionModel? {
        guard let collectionID = currentTab?.sourceCollectionID else {
            return workspace.collections.first
        }
        return workspace.collections.first(where: { $0.id == collectionID })
    }

    public func filteredCollections() -> [CollectionModel] {
        guard !searchText.isEmpty else {
            return workspace.collections
        }

        return workspace.collections.compactMap { collection in
            let filteredItems = filter(nodes: collection.items, with: searchText)
            if collection.info.name.localizedCaseInsensitiveContains(searchText) || !filteredItems.isEmpty {
                var copy = collection
                copy.items = filteredItems.isEmpty ? collection.items : filteredItems
                return copy
            }
            return nil
        }
    }

    public func saveResponseToDisk() {
        #if os(macOS)
        guard let tab = currentTab else { return }

        if tab.request.transportKind == .webSocket {
            let transcript = tab.webSocketTranscript
                .map { "[\($0.createdAt.formatted(date: .omitted, time: .standard))] \($0.direction.rawValue.uppercased()): \($0.body)" }
                .joined(separator: "\n\n")
            guard !transcript.isEmpty else { return }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "websocket-transcript.txt"

            if panel.runModal() == .OK, let url = panel.url {
                do {
                    try transcript.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        guard let response = tab.response else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = response.suggestedDownloadFilename ?? "response.txt"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try response.body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        #else
        errorMessage = "Saving responses to disk is not available in this build. Use the Mac app for now."
        #endif
    }

    @MainActor
    private static func openExternalURL(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }

    private func openFirstRequestIfNeeded() {
        guard tabs.isEmpty else { return }
        if let pair = firstRequestNode() {
            openRequestImmediately(pair.node, in: pair.collection)
        } else {
            newRequest()
        }
    }

    private func firstRequestNode() -> (collection: CollectionModel, node: CollectionNode)? {
        for collection in workspace.collections {
            if let node = firstRequest(in: collection.items) {
                return (collection, node)
            }
        }
        return nil
    }

    private func normalizeFlowTaskBindings(
        _ flow: WorkspaceFlowDefinition,
        availableRequests: [WorkspaceFlowRequestReference]
    ) -> WorkspaceFlowDefinition {
        var copy = flow
        copy.taskBindings = flow.taskBindings.map { binding in
            var updated = binding
            guard let resolved = updated.resolvedRequestID(matching: availableRequests) else {
                return updated
            }
            updated.requestID = resolved
            if let ref = availableRequests.first(where: { $0.requestID == resolved }) {
                updated.boundCollectionName = ref.collectionName
                updated.boundRequestName = ref.requestName
                updated.boundTransportKind = ref.transportKind
            }
            return updated
        }
        return copy
    }

    private func normalizeFlowTaskBindingsForExecution(_ flow: WorkspaceFlowDefinition) -> WorkspaceFlowDefinition {
        normalizeFlowTaskBindings(flow, availableRequests: availableFlowRequests())
    }

    /// Rewrites task bindings with portable metadata and local request UUIDs using the given collections (must match the flows being saved).
    private func flowsPortableForPersistence(_ flows: [WorkspaceFlowDefinition], collections: [CollectionModel]) -> [WorkspaceFlowDefinition] {
        let available = availableFlowRequests(forCollections: collections)
        return flows.map { normalizeFlowTaskBindings($0, availableRequests: available) }
    }

    private func resolveRequests(for flow: WorkspaceFlowDefinition) throws -> [WorkspaceFlowResolvedRequest] {
        let available = availableFlowRequests()
        let requestIDs = Set(flow.taskBindings.compactMap { $0.resolvedRequestID(matching: available) })

        return try requestIDs.map { requestID in
            guard let resolved = resolveRequestReference(for: requestID) else {
                throw AppError.invalidDocument("A task in flow '\(flow.name)' points to a request that no longer exists.")
            }
            return resolved
        }
    }

    private func resolveRequestReference(for requestID: UUID) -> WorkspaceFlowResolvedRequest? {
        for collection in workspace.collections {
            if let node = requestNode(for: requestID, in: collection.items),
               let request = node.request {
                let effectiveRequest = CollectionScriptSupport.enrichedRequest(
                    from: request,
                    collection: collection,
                    sourceNodeID: node.id
                )
                return WorkspaceFlowResolvedRequest(
                    requestID: request.id,
                    collectionID: collection.id,
                    request: effectiveRequest,
                    collectionVariables: collection.variables
                )
            }
        }

        return nil
    }

    private func requestNode(for requestID: UUID, in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.request?.id == requestID {
                return node
            }
            if let nested = requestNode(for: requestID, in: node.children) {
                return nested
            }
        }
        return nil
    }

    private func restoreDraftTabsIfNeeded() {
        for draft in standaloneDraftStates() {
            let tabID = draft.tabID ?? draft.id
            guard !tabs.contains(where: { $0.id == tabID }) else { continue }

            let selectedEnvironmentID = draft.selectedEnvironmentID ?? workspace.activeEnvironmentID
            let persistedSelectedEnvironmentID = draft.persistedSelectedEnvironmentID
                ?? draft.selectedEnvironmentID
                ?? workspace.activeEnvironmentID

            let tab = RequestTabState(
                id: tabID,
                request: draft.request,
                selectedEnvironmentID: selectedEnvironmentID,
                pendingEnvironmentVariables: environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments),
                persistedRequest: draft.persistedRequest ?? draft.request,
                persistedSelectedEnvironmentID: persistedSelectedEnvironmentID,
                persistedEnvironmentVariables: environmentCoordinator.variables(for: persistedSelectedEnvironmentID, in: workspace.environments)
            )
            tabs.append(tab)
        }

        for draft in workspace.requestDrafts {
            guard let collectionID = draft.collectionID,
                  let nodeID = draft.nodeID,
                  let collection = workspace.collections.first(where: { $0.id == collectionID }),
                  let node = find(nodeID: nodeID, in: collection.items),
                  !tabs.contains(where: { $0.sourceNodeID == nodeID }) else {
                continue
            }

            let savedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)
            let request = draft.request
            let selectedEnvironmentID = draft.selectedEnvironmentID ?? workspace.activeEnvironmentID
            let persistedSelectedEnvironmentID = draft.persistedSelectedEnvironmentID
                ?? draft.selectedEnvironmentID
                ?? workspace.activeEnvironmentID
            let tab = RequestTabState(
                id: draft.tabID ?? draft.id,
                request: request,
                selectedEnvironmentID: selectedEnvironmentID,
                pendingEnvironmentVariables: environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments),
                persistedRequest: draft.persistedRequest ?? savedRequest,
                persistedSelectedEnvironmentID: persistedSelectedEnvironmentID,
                persistedEnvironmentVariables: environmentCoordinator.variables(for: persistedSelectedEnvironmentID, in: workspace.environments),
                sourceCollectionID: collectionID,
                sourceNodeID: nodeID
            )
            tabs.append(tab)
        }

        if selectedTabID == nil {
            selectedTabID = tabs.last?.id
        }
    }

    private func firstRequest(in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.kind == .request {
                return node
            }
            if let nested = firstRequest(in: node.children) {
                return nested
            }
        }
        return nil
    }

    private func filter(nodes: [CollectionNode], with query: String) -> [CollectionNode] {
        nodes.compactMap { node in
            if node.kind == .request && node.name.localizedCaseInsensitiveContains(query) {
                return node
            }

            let children = filter(nodes: node.children, with: query)
            if node.name.localizedCaseInsensitiveContains(query) || !children.isEmpty {
                var copy = node
                copy.children = children
                return copy
            }

            return nil
        }
    }

    private func collectionVariables(for tab: RequestTabState) -> [VariableValue] {
        guard let collectionID = tab.sourceCollectionID,
              let collection = workspace.collections.first(where: { $0.id == collectionID }) else {
            return []
        }
        return collection.variables
    }

    private func collection(for tab: RequestTabState) -> CollectionModel? {
        guard let collectionID = tab.sourceCollectionID else {
            return nil
        }
        return workspace.collections.first(where: { $0.id == collectionID })
    }

    private func environment(for tab: RequestTabState) -> EnvironmentProfile? {
        environmentCoordinator.profile(
            for: tab,
            environments: workspace.environments,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
    }

    private func refreshTabEnvironmentSnapshotFromWorkspace(for tab: RequestTabState) {
        environmentCoordinator.refreshTabSnapshot(
            tab,
            environments: workspace.environments,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
    }

    /// Resuelve `{{clave}}` con globales, variables de colección, entorno del tab y variables locales (sin scripts pre-request).
    public func resolveTemplatePlaceholders(_ template: String, for tab: RequestTabState) -> String {
        let collection = collection(for: tab)
        let context = VariableResolutionContext(
            globals: workspace.globalVariables,
            collection: collection?.variables ?? [],
            environment: environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
            local: tab.request.localVariables
        )
        return VariableResolver().resolve(template, context: context, expressionEvaluator: nil)
    }

    /// Plantilla `APIRequestModel.awsAccessPortalURLTemplate` ya sustituida y recortada.
    public func resolvedAWSAccessPortalURL(for tab: RequestTabState) -> String {
        // Igual que antes de enviar: alinear variables del tab con el workspace (evita `{{}}` sin resolver en iPad).
        refreshTabEnvironmentSnapshotFromWorkspace(for: tab)
        return resolveTemplatePlaceholders(tab.request.awsAccessPortalURLTemplate, for: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sincroniza globales, variables de colección y entornos desde disco (como antes de **Send**) y refresca el snapshot del tab.
    /// Úsalo antes de abrir el portal AWS para que `{{variable}}` refleje el último estado guardado en el repo.
    public func synchronizeVariableStoresBeforePortalAWS(for tab: RequestTabState) async {
        await refreshPersistedVariableStoresFromDisk()
        refreshTabEnvironmentSnapshotFromWorkspace(for: tab)
    }

    private func pushableCollectionsSnapshot() -> [CollectionModel] {
        workspace.collections
    }

    private func pushableEnvironmentsSnapshot() -> [EnvironmentProfile] {
        persistedSharedEnvironments
    }

    private func ensureEnvironmentExistsIfRequired(for tab: RequestTabState, collection: CollectionModel?, request: APIRequestModel) {
        guard environment(for: tab) == nil else {
            return
        }

        guard requestUsesEnvironmentScripting(request) || requestUsesEnvironmentPlaceholders(request) else {
            return
        }

        let environmentName: String
        if let collection {
            environmentName = collection.info.name
        } else {
            environmentName = "Local"
        }

        let environment = EnvironmentProfile(name: environmentName)
        workspace.environments.append(environment)
        workspace.activeEnvironmentID = environment.id
        tab.selectedEnvironmentID = environment.id
        tab.pendingEnvironmentVariables = environment.variables
        tab.persistedEnvironmentVariables = environment.variables
        persistWorkspace(syncSharedData: false)
    }

    private func updateCollectionVariables(for tab: RequestTabState, variables: [VariableValue]) {
        guard let collectionID = tab.sourceCollectionID,
              let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }
        workspace.collections[index].variables = environmentCoordinator.merge(existing: workspace.collections[index].variables, with: variables)
    }

    private func updateCollectionVariables(forCollectionID collectionID: UUID, variables: [VariableValue]) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }
        workspace.collections[index].variables = environmentCoordinator.merge(existing: workspace.collections[index].variables, with: variables)
    }

    private func updateEnvironmentVariables(_ variables: [VariableValue], for tab: RequestTabState) {
        guard let environmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID else {
            return
        }
        let base = environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments)
        let mergedVariables = environmentCoordinator.merge(existing: base, with: variables)
        let previousVariables = environmentCoordinator.variables(for: environmentID, in: workspace.environments)

        tab.pendingEnvironmentVariables = mergedVariables

        if let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID }) {
            workspace.environments[environmentIndex].variables = mergedVariables
        }

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environmentID,
            previousVariables: previousVariables,
            updatedVariables: mergedVariables,
            excluding: tab.id
        )

        persistDraft(for: tab, syncNow: true)
    }

    private func applyExecutionVariableUpdates(
        to tab: RequestTabState,
        updatedGlobals: [VariableValue],
        updatedCollection: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        updatedLocal: [KeyValueEntry]
    ) {
        tab.request.localVariables = updatedLocal
        workspace.globalVariables = environmentCoordinator.merge(existing: workspace.globalVariables, with: updatedGlobals)
        updateCollectionVariables(for: tab, variables: updatedCollection)
        if applyRuntimeEnvironmentChanges(
            updatedEnvironments: updatedEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            sourceTab: tab,
            persistSideEffects: true
        ) {
            if updatedEnvironment.isEmpty,
               let resolvedEnvironmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID {
                tab.pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
            } else {
                updateEnvironmentVariables(updatedEnvironment, for: tab)
            }
        } else {
            updateEnvironmentVariables(updatedEnvironment, for: tab)
        }
    }

    /// Merges flow execution outcomes into the live `workspace` for UI and in-memory continuity.
    /// - Parameter persistToDisk: `false` while running a workspace flow: no `persistWorkspace` and no tab draft sync from this path (requests + explicit batch preflight own persistence).
    private func applyFlowExecutionVariableUpdates(_ result: WorkspaceFlowExecutionResult, persistToDisk: Bool = true) {
        workspace.globalVariables = environmentCoordinator.merge(existing: workspace.globalVariables, with: result.updatedGlobals)

        for collectionUpdate in result.updatedCollections {
            updateCollectionVariables(forCollectionID: collectionUpdate.collectionID, variables: collectionUpdate.variables)
        }

        if applyRuntimeEnvironmentChanges(
            updatedEnvironments: result.updatedEnvironments,
            activeEnvironmentID: result.activeEnvironmentID,
            sourceTab: nil,
            persistSideEffects: persistToDisk
        ) {
            if result.updatedEnvironment.isEmpty {
                if persistToDisk {
                    persistWorkspace(syncSharedData: false)
                }
                return
            }
        }

        if let environmentID = workspace.activeEnvironmentID {
            let previousVariables = environmentCoordinator.variables(for: environmentID, in: workspace.environments)
            let mergedEnvironment = environmentCoordinator.merge(existing: previousVariables ?? [], with: result.updatedEnvironment)

            if let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID }) {
                workspace.environments[environmentIndex].variables = mergedEnvironment
            }

            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environmentID,
                previousVariables: previousVariables,
                updatedVariables: mergedEnvironment,
                excluding: UUID()
            )
        }

        if persistToDisk {
            persistWorkspace(syncSharedData: false)
        }
    }

    @discardableResult
    private func applyRuntimeEnvironmentChanges(
        updatedEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        sourceTab: RequestTabState?,
        persistSideEffects: Bool = true
    ) -> Bool {
        guard !updatedEnvironments.isEmpty || activeEnvironmentID != nil else {
            return false
        }

        let previousActiveEnvironmentID = workspace.activeEnvironmentID
        let previousVariablesByEnvironmentID = Dictionary(uniqueKeysWithValues: workspace.environments.map { ($0.id, $0.variables) })

        if !updatedEnvironments.isEmpty {
            workspace.environments = updatedEnvironments
        }

        if let activeEnvironmentID,
           workspace.environments.contains(where: { $0.id == activeEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = activeEnvironmentID
        } else if let currentActiveEnvironmentID = workspace.activeEnvironmentID,
                  workspace.environments.contains(where: { $0.id == currentActiveEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = currentActiveEnvironmentID
        } else {
            workspace.activeEnvironmentID = workspace.environments.first(where: \.isEnabled)?.id
        }

        for environment in workspace.environments {
            let previousVariables = previousVariablesByEnvironmentID[environment.id]
            guard previousVariables != environment.variables else {
                continue
            }

            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environment.id,
                previousVariables: previousVariables,
                updatedVariables: environment.variables,
                excluding: sourceTab?.id ?? UUID()
            )
        }

        for index in tabs.indices {
            let currentSelection = tabs[index].selectedEnvironmentID ?? previousActiveEnvironmentID

            if let explicitSelection = tabs[index].selectedEnvironmentID,
               !workspace.environments.contains(where: { $0.id == explicitSelection }) {
                tabs[index].selectedEnvironmentID = nil
            }

            if tabs[index].id == sourceTab?.id,
               let activeEnvironmentID = workspace.activeEnvironmentID {
                tabs[index].selectedEnvironmentID = activeEnvironmentID
            }

            let resolvedEnvironmentID = tabs[index].selectedEnvironmentID
                ?? (currentSelection != previousActiveEnvironmentID ? currentSelection : workspace.activeEnvironmentID)
                ?? workspace.activeEnvironmentID
            tabs[index].pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
            if persistSideEffects {
                persistDraft(for: tabs[index], syncNow: true)
            }
        }

        for draftIndex in workspace.requestDrafts.indices {
            if let explicitSelection = workspace.requestDrafts[draftIndex].selectedEnvironmentID,
               !workspace.environments.contains(where: { $0.id == explicitSelection }) {
                workspace.requestDrafts[draftIndex].selectedEnvironmentID = nil
            }

            if workspace.requestDrafts[draftIndex].tabID == sourceTab?.id {
                workspace.requestDrafts[draftIndex].selectedEnvironmentID = workspace.activeEnvironmentID
            }

            let resolvedEnvironmentID = workspace.requestDrafts[draftIndex].selectedEnvironmentID
                ?? workspace.activeEnvironmentID
            workspace.requestDrafts[draftIndex].pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
        }

        return true
    }

    private func appendWebSocketTranscript(_ entry: WebSocketTranscriptEntry, to tab: RequestTabState) {
        tab.webSocketTranscript.append(entry)
        if tab.webSocketTranscript.count > 500 {
            tab.webSocketTranscript.removeFirst(tab.webSocketTranscript.count - 500)
        }
    }

    private func connectWebSocketWithTimeout(
        prepared: WebSocketPreparationOutcome,
        request: APIRequestModel
    ) async throws -> any WebSocketConnectionProtocol {
        let timeoutSeconds = request.webSocketOpenTimeoutSeconds
        if timeoutSeconds <= 0 {
            return try await webSocketCoordinator.connect(prepared: prepared, request: request)
        }

        return try await withThrowingTaskGroup(of: (any WebSocketConnectionProtocol).self) { group in
            group.addTask { [webSocketCoordinator] in
                try await webSocketCoordinator.connect(prepared: prepared, request: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppError.network("WebSocket open timed out after \(Int(timeoutSeconds)) seconds.")
            }

            let result = try await group.next()
            group.cancelAll()
            guard let result else {
                throw AppError.network("WebSocket open timed out.")
            }
            return result
        }
    }

    private func startWebSocketAutomationTasks(
        for tab: RequestTabState,
        request: APIRequestModel,
        connection: any WebSocketConnectionProtocol
    ) {
        if request.webSocketPingIntervalSeconds > 0 {
            let pingInterval = request.webSocketPingIntervalSeconds
            tab.webSocketPingTask = Task { [weak tab] in
                guard let tab else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                        if Task.isCancelled { return }
                        try await connection.sendPing()
                        await MainActor.run {
                            tab.webSocketPingSentCount += 1
                            tab.webSocketLastPingSentAt = Date()
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await MainActor.run {
                            tab.consoleLogs.append("Ping error: \(error.localizedDescription)")
                        }
                        return
                    }
                }
            }
        }

        let keepAliveMessage = request.webSocketKeepAliveMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.webSocketKeepAliveIntervalSeconds > 0,
           !keepAliveMessage.isEmpty {
            let keepAliveInterval = request.webSocketKeepAliveIntervalSeconds
            tab.webSocketKeepAliveTask = Task { [weak self, weak tab] in
                guard let self, let tab else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(keepAliveInterval * 1_000_000_000))
                        if Task.isCancelled { return }

                        let collection = await MainActor.run { self.collection(for: tab) }
                        let collectionVariables = await MainActor.run { collection?.variables ?? [] }
                        let environmentVariables = await MainActor.run { self.environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments) }
                        let globals = await MainActor.run { self.workspace.globalVariables }

                        let payload = self.webSocketCoordinator.resolve(
                            keepAliveMessage,
                            globals: globals,
                            collectionVariables: collectionVariables,
                            environmentVariables: environmentVariables,
                            localVariables: tab.request.localVariables,
                            request: tab.request,
                            utilityLibraries: self.workspace.utilityLibraries
                        )

                        try await connection.send(text: payload)
                        await MainActor.run {
                            self.appendWebSocketTranscript(
                                WebSocketTranscriptEntry(direction: .system, body: "Keepalive message sent:\n\(payload)"),
                                to: tab
                            )
                            tab.consoleLogs.append("Keepalive message sent (\(payload.count) chars).")
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        await MainActor.run {
                            tab.consoleLogs.append("Keepalive error: \(error.localizedDescription)")
                        }
                        return
                    }
                }
            }
        }
    }

    private func cancelWebSocketTasks(for tab: RequestTabState) {
        tab.webSocketReceiveTask?.cancel()
        tab.webSocketReceiveTask = nil
        tab.webSocketPingTask?.cancel()
        tab.webSocketPingTask = nil
        tab.webSocketKeepAliveTask?.cancel()
        tab.webSocketKeepAliveTask = nil
    }

    private func synchronizeOpenTabsForLocalEnvironmentChange(
        environmentID: UUID,
        previousVariables: [VariableValue]?,
        updatedVariables: [VariableValue],
        excluding excludedTabID: UUID
    ) {
        var drafts = workspace.requestDrafts
        environmentCoordinator.synchronizeOpenTabs(
            environmentID: environmentID,
            previousVariables: previousVariables,
            updatedVariables: updatedVariables,
            excluding: excludedTabID,
            tabs: tabs,
            drafts: &drafts,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
        workspace.requestDrafts = drafts
    }

    private func synchronizePersistedEnvironmentBaseline(environmentID: UUID, variables: [VariableValue]) {
        var drafts = workspace.requestDrafts
        environmentCoordinator.synchronizePersistedBaseline(
            environmentID: environmentID,
            variables: variables,
            tabs: tabs,
            drafts: &drafts,
            activeEnvironmentID: workspace.activeEnvironmentID,
            environments: workspace.environments
        )
        workspace.requestDrafts = drafts
    }

    private func requestUsesEnvironmentScripting(_ request: APIRequestModel) -> Bool {
        request.scripts.contains { script in
            let source = script.source.lowercased()
            return source.contains("pm.environment")
                || source.contains("postman.setenvironmentvariable")
                || source.contains("postman.getenvironmentvariable")
                || source.contains("postman.clearenvironmentvariable")
        }
    }

    private func requestUsesEnvironmentPlaceholders(_ request: APIRequestModel) -> Bool {
        let candidates = [
            request.url,
            request.body.raw,
            request.auth.username,
            request.auth.password,
            request.auth.token,
            request.auth.key,
            request.auth.value,
            request.auth.accessTokenURL,
            request.auth.clientID,
            request.auth.clientSecret,
            request.auth.scopes,
        ] + request.headers.map(\.value)
          + request.cookies.map(\.value)
          + request.queryItems.map(\.value)
          + request.pathVariables.map(\.value)
          + request.localVariables.map(\.value)
          + request.body.parameters.map(\.value)

        return candidates.contains { $0.contains("{{") && $0.contains("}}") }
    }

    private func contains(nodeID: UUID, in node: CollectionNode) -> Bool {
        if node.id == nodeID {
            return true
        }
        return node.children.contains { contains(nodeID: nodeID, in: $0) }
    }

    private func update(nodeID: UUID, in node: CollectionNode, with replacement: CollectionNode) -> CollectionNode {
        if node.id == nodeID {
            return replacement
        }

        var copy = node
        copy.children = node.children.map { update(nodeID: nodeID, in: $0, with: replacement) }
        return copy
    }

    private func rename(nodeID: UUID, in node: CollectionNode, to newName: String) -> CollectionNode {
        if node.id == nodeID {
            var copy = node
            copy.name = newName
            if copy.kind == .request {
                copy.request?.name = newName
            }
            return copy
        }

        var copy = node
        copy.children = node.children.map { rename(nodeID: nodeID, in: $0, to: newName) }
        return copy
    }

    /// Inserta `newNode` inmediatamente después del nodo con id `afterSiblingID` (búsqueda recursiva en carpetas).
    private func insertCollectionNode(_ newNode: CollectionNode, afterSiblingID: UUID, in nodes: inout [CollectionNode]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == afterSiblingID {
                nodes.insert(newNode, at: index + 1)
                return true
            }
            if nodes[index].kind == .folder && !nodes[index].children.isEmpty {
                var children = nodes[index].children
                if insertCollectionNode(newNode, afterSiblingID: afterSiblingID, in: &children) {
                    nodes[index].children = children
                    return true
                }
            }
        }
        return false
    }

    private func makeDuplicatedRequestCollectionNode(from node: CollectionNode) -> CollectionNode? {
        guard node.kind == .request, let sourceRequest = node.request else { return nil }
        guard var duplicatedRequest = catalogCoordinator.cloneRequest(sourceRequest) else { return nil }
        let baseName = node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (sourceRequest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Request" : sourceRequest.name)
            : node.name
        let copyTitle = "\(baseName) Copy"
        duplicatedRequest.name = copyTitle
        let duplicatedResponses = node.responses.map {
            SavedResponseModel(name: $0.name, statusCode: $0.statusCode, headers: $0.headers, body: $0.body)
        }
        return CollectionNode(
            name: copyTitle,
            kind: .request,
            request: duplicatedRequest,
            responses: duplicatedResponses,
            scripts: node.scripts,
            auth: node.auth,
            nodeDescription: node.nodeDescription,
            children: []
        )
    }

    private func remove(nodeID: UUID, from nodes: [CollectionNode]) -> [CollectionNode] {
        nodes.compactMap { node in
            if node.id == nodeID {
                return nil
            }

            var copy = node
            copy.children = remove(nodeID: nodeID, from: node.children)
            return copy
        }
    }

    public func persistPendingChanges(for tab: RequestTabState) {
        if tab.sourceCollectionID != nil || tab.sourceNodeID != nil {
            persistRequestToWorkspace(for: tab, preferredCollectionID: tab.sourceCollectionID)
        } else {
            tab.persistedRequest = tab.request
            tab.persistedSelectedEnvironmentID = tab.selectedEnvironmentID
            tab.persistedEnvironmentVariables = tab.pendingEnvironmentVariables
            persistDraft(for: tab)
        }
    }

    public func flushStateForApplicationTermination() async {
        snapshotOpenTabsIntoDrafts()
        persistWorkspace()
        await flushPendingWorkspacePersistence()
    }

    private func persistDraft(for tab: RequestTabState, syncNow: Bool = false) {
        guard let activeWorkspaceName = workspace.activeWorkspaceName else {
            return
        }

        switch requestTabsCoordinator.resolveDraftMutation(
            tab: tab,
            activeWorkspaceName: activeWorkspaceName,
            drafts: workspace.requestDrafts,
            requestsEquivalent: requestsEquivalentForPersistence
        ) {
        case .removeCollectionDraft(let nodeID, let collectionID):
            removeDraft(nodeID: nodeID, collectionID: collectionID)
        case .update(let index, let draft):
            workspace.requestDrafts[index] = draft
        case .append(let draft):
            workspace.requestDrafts.append(draft)
        }

        _ = syncNow
        persistWorkspace(syncSharedData: false)
    }

    private func snapshotOpenTabsIntoDrafts() {
        for tab in tabs {
            persistDraft(for: tab, syncNow: true)
        }
    }

    private func removeDraft(nodeID: UUID?, collectionID: UUID?) {
        guard let activeWorkspaceName = workspace.activeWorkspaceName,
              let nodeID,
              let collectionID else {
            return
        }

        workspace.requestDrafts.removeAll {
            $0.workspaceName == activeWorkspaceName &&
            $0.collectionID == collectionID &&
            $0.nodeID == nodeID
        }
    }

    private func removeStandaloneDraft(tabID: UUID) {
        guard let activeWorkspaceName = workspace.activeWorkspaceName else {
            return
        }

        workspace.requestDrafts.removeAll {
            $0.workspaceName == activeWorkspaceName &&
            $0.tabID == tabID &&
            $0.collectionID == nil &&
            $0.nodeID == nil
        }
    }

    private func draftState(for nodeID: UUID, collectionID: UUID) -> RequestDraftState? {
        requestTabsCoordinator.draftState(
            nodeID: nodeID,
            collectionID: collectionID,
            workspaceName: workspace.activeWorkspaceName,
            drafts: workspace.requestDrafts
        )
    }

    private func standaloneDraftStates() -> [RequestDraftState] {
        requestTabsCoordinator.standaloneDraftStates(
            workspaceName: workspace.activeWorkspaceName,
            drafts: workspace.requestDrafts
        )
    }

    private func savedRequestNode(nodeID: UUID, collectionID: UUID) -> CollectionNode? {
        guard let collection = workspace.collections.first(where: { $0.id == collectionID }) else {
            return nil
        }
        return find(nodeID: nodeID, in: collection.items)
    }

    private func find(nodeID: UUID, in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.id == nodeID {
                return node
            }
            if let nested = find(nodeID: nodeID, in: node.children) {
                return nested
            }
        }
        return nil
    }

    private func persistWorkspace(syncSharedData: Bool = true) {
        persistWorkspace(
            syncSharedCollections: syncSharedData,
            syncSharedEnvironments: syncSharedData,
            syncSharedFlows: syncSharedData,
            syncSharedUtilities: syncSharedData
        )
    }

    private func persistWorkspace(
        syncSharedCollections: Bool = true,
        syncSharedEnvironments: Bool = true,
        syncSharedFlows: Bool = true,
        syncSharedUtilities: Bool = true
    ) {
        let workspaceSnapshot = workspace
        let workspaceRoot = activeWorkspaceDirectoryURL

        if syncSharedEnvironments {
            persistedSharedEnvironments = workspace.environments
        }

        var persistedSnapshot = workspaceSnapshot
        persistedSnapshot.flows = flowsPortableForPersistence(
            workspaceSnapshot.flows,
            collections: workspaceSnapshot.collections
        )

        let previousTask = pendingWorkspacePersistenceTask
        let coordinator = persistenceCoordinator
        let options = WorkspacePersistenceOptions(
            syncSharedCollections: syncSharedCollections,
            syncSharedEnvironments: syncSharedEnvironments,
            syncSharedFlows: syncSharedFlows,
            syncSharedUtilities: syncSharedUtilities
        )

        pendingWorkspacePersistenceTask = Task { [weak self] in
            await previousTask?.value
            do {
                try await coordinator.persist(
                    snapshot: persistedSnapshot,
                    workspaceRoot: workspaceRoot,
                    options: options
                )
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func flushPendingWorkspacePersistence() async {
        let task = pendingWorkspacePersistenceTask
        await task?.value
    }

    private func refreshPersistedVariableStoresFromDisk() async {
        await flushPendingWorkspacePersistence()

        do {
            let persistedWorkspace = try await persistenceCoordinator.loadLocal()
            applyPersistedVariableStores(from: persistedWorkspace)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyPersistedVariableStores(from persistedWorkspace: WorkspaceState) {
        workspace.globalVariables = persistedWorkspace.globalVariables

        let persistedCollectionVariables = Dictionary(
            uniqueKeysWithValues: persistedWorkspace.collections.map { ($0.id, $0.variables) }
        )
        for index in workspace.collections.indices {
            guard let variables = persistedCollectionVariables[workspace.collections[index].id] else {
                continue
            }
            workspace.collections[index].variables = variables
        }

        let previousActiveEnvironmentID = workspace.activeEnvironmentID
        let previousVariablesByEnvironmentID = Dictionary(
            uniqueKeysWithValues: workspace.environments.map { ($0.id, $0.variables) }
        )

        workspace.environments = persistedWorkspace.environments
        persistedSharedEnvironments = persistedWorkspace.environments

        if let activeEnvironmentID = persistedWorkspace.activeEnvironmentID,
           workspace.environments.contains(where: { $0.id == activeEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = activeEnvironmentID
        } else if let currentActiveEnvironmentID = workspace.activeEnvironmentID,
                  workspace.environments.contains(where: { $0.id == currentActiveEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = currentActiveEnvironmentID
        } else {
            workspace.activeEnvironmentID = workspace.environments.first(where: \.isEnabled)?.id
        }

        for environment in workspace.environments {
            let previousVariables = previousVariablesByEnvironmentID[environment.id]
            guard previousVariables != environment.variables else {
                continue
            }

            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environment.id,
                previousVariables: previousVariables,
                updatedVariables: environment.variables,
                excluding: UUID()
            )
        }

        sanitizeEnvironmentSelections()

        for tab in tabs {
            let currentSelection = tab.selectedEnvironmentID ?? previousActiveEnvironmentID
            let resolvedEnvironmentID = tab.selectedEnvironmentID
                ?? (currentSelection != previousActiveEnvironmentID ? currentSelection : workspace.activeEnvironmentID)
                ?? workspace.activeEnvironmentID
            tab.pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
            tab.persistedEnvironmentVariables = environmentCoordinator.variables(
                for: tab.persistedSelectedEnvironmentID ?? resolvedEnvironmentID,
                in: workspace.environments
            )
        }
    }

    private func restoreSharedRepositoryAccessIfNeeded() {
        guard let bookmarkData = workspace.sharedCollectionsDirectoryBookmarkData else { return }

        guard let restoreResult = repositoryDirectoryAccess.restore(
            bookmarkData: bookmarkData,
            refreshStaleBookmark: Self.makeSecurityScopedBookmarkData(for:)
        ) else {
            repositoryDirectoryAccess.releaseAccess()
            return
        }

        workspace.sharedCollectionsDirectoryPath = restoreResult.url.path
        if let refreshedBookmarkData = restoreResult.refreshedBookmarkData {
            workspace.sharedCollectionsDirectoryBookmarkData = refreshedBookmarkData
            persistWorkspace(syncSharedCollections: false, syncSharedEnvironments: false)
        }
    }

    private static func makeSecurityScopedBookmarkData(for url: URL) -> Data? {
        SecurityScopedDirectoryAccess().makeBookmarkData(for: url)
    }

    private func appendGitOutput(_ chunk: String) {
        gitSessionCoordinator.append(chunk: chunk, to: &gitOutput)
    }

    private func makeGitOutputHandler() -> GitOutputHandler {
        gitSessionCoordinator.makeOutputHandler { [weak self] chunk in
            self?.appendGitOutput(chunk)
        }
    }

    private func applyPullOutcome(_ outcome: GitSessionCoordinator.PullOutcome, at root: URL) async throws {
        gitMergeConflictPaths = []

        switch outcome {
        case .mergeConflictsPending(let paths, let output):
            await MainActor.run {
                self.gitMergeConflictPaths = paths
                if !output.isEmpty {
                    if !(self.gitOutput?.isEmpty == false) {
                        self.gitOutput = output
                    } else {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(output)
                    }
                }
                self.finishGitBusyState()
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }

        case .stashPopStalled(let message, let conflictPaths):
            await MainActor.run {
                self.gitMergeConflictPaths = conflictPaths
                self.appendGitOutput(message)
                self.finishGitBusyState()
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }

        case .completed(let extraOutputParts, let commandOutput, let emptySuccessMessage, let requiresFullRefresh, let changedPaths):
            var outputParts = extraOutputParts

            if requiresFullRefresh {
                await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)
            } else if let selectiveRefreshMessage = await applySelectiveGitPullRefresh(
                changedPaths: changedPaths,
                repositoryRoot: root
            ) {
                outputParts.append(selectiveRefreshMessage)
            }

            if !commandOutput.isEmpty && gitOutput?.isEmpty != false {
                outputParts.append(commandOutput)
            }

            await MainActor.run {
                if outputParts.isEmpty {
                    if commandOutput.isEmpty {
                        self.appendGitOutput(emptySuccessMessage)
                    }
                } else {
                    if self.gitOutput?.isEmpty == false {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                    } else {
                        self.gitOutput = outputParts.joined(separator: "\n\n")
                    }
                }
                self.finishGitBusyState()
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    private func applySelectiveGitPullRefresh(changedPaths: [String], repositoryRoot: URL) async -> String? {
        do {
            try await persistenceCoordinator.ensureWorkdirMarker(in: repositoryRoot)
            var workspaceNames = try await persistenceCoordinator.workspaceNames(in: repositoryRoot)
            if workspaceNames.isEmpty {
                let defaultWorkspace = try await persistenceCoordinator.ensureDefaultWorkspace(in: repositoryRoot)
                workspaceNames = [defaultWorkspace]
            }
            availableWorkspaceNames = workspaceNames
            gitRemoteDescription = try await gitSessionCoordinator.remoteURL(at: repositoryRoot)

            guard let activeWorkspaceName = workspace.activeWorkspaceName else {
                return nil
            }

            guard workspaceNames.contains(activeWorkspaceName) else {
                workspace.activeWorkspaceName = workspaceNames.first
                try await persistenceCoordinator.saveLocal(workspace)
                await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: false)
                return nil
            }

            let workspacePrefix = "\(activeWorkspaceName)/"
            let relevantPaths = changedPaths.filter { $0.hasPrefix(workspacePrefix) }
            guard !relevantPaths.isEmpty else {
                return nil
            }

            let workspaceRoot = repositoryRoot.appendingPathComponent(activeWorkspaceName, isDirectory: true)
            var notes: [String] = []

            if relevantPaths.contains(where: { $0.hasPrefix("\(workspacePrefix)collections/") }) {
                let reloadedCollections = SharedWorkspaceCoordinator.preserveCollectionIdentifiers(
                    from: workspace.collections,
                    in: try await persistenceCoordinator.loadCollections(from: workspaceRoot)
                )
                workspace.collections = reloadedCollections
                reconcileOpenTabsWithWorkspace(
                    affectedCollectionIDs: Set(reloadedCollections.map(\.id)),
                    affectedEnvironmentIDs: nil
                )
            }

            if relevantPaths.contains(where: { $0.hasPrefix("\(workspacePrefix)environments/") }) {
                let hasLocalEnvironmentDrafts =
                    hasPendingEnvironmentStoreChanges ||
                    tabs.contains(where: hasPendingEnvironmentChanges(for:))

                if hasLocalEnvironmentDrafts {
                    notes.append("Skipped reloading environment files from pull because local environment drafts are still in memory.")
                } else {
                    let reloadedEnvironments = try await persistenceCoordinator.loadEnvironments(from: workspaceRoot)
                    workspace.environments = reloadedEnvironments
                    persistedSharedEnvironments = reloadedEnvironments
                    if workspace.activeEnvironmentID == nil || !reloadedEnvironments.contains(where: { $0.id == workspace.activeEnvironmentID }) {
                        workspace.activeEnvironmentID = reloadedEnvironments.first(where: \.isEnabled)?.id
                    }
                    sanitizeEnvironmentSelections()
                    reconcileOpenTabsWithWorkspace(
                        affectedCollectionIDs: nil,
                        affectedEnvironmentIDs: Set(reloadedEnvironments.map(\.id))
                    )
                }
            }

            return notes.isEmpty ? nil : notes.joined(separator: "\n")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func completeConnectedGitFlow(
        at repositoryRoot: URL,
        remoteURL: String?,
        connectOutput: String,
        successMessage: String
    ) async {
        var outputParts = [connectOutput].filter { !$0.isEmpty }

        do {
            let pullResult = try await gitSessionCoordinator.pull(at: repositoryRoot, onOutput: makeGitOutputHandler())
            if !pullResult.mergeConflictsPending.isEmpty {
                if !pullResult.output.isEmpty {
                    outputParts.append(pullResult.output)
                }
                await MainActor.run {
                    self.gitMergeConflictPaths = pullResult.mergeConflictsPending
                    self.gitCredentialPrompt = nil
                    self.gitRemoteDescription = remoteURL
                    if self.gitOutput?.isEmpty == false {
                        if !outputParts.isEmpty {
                            if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                                self.appendGitOutput("\n")
                            }
                            self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                        }
                    } else {
                        self.gitOutput = outputParts.joined(separator: "\n\n")
                    }
                    self.infoMessage = successMessage
                    self.isGitBusy = false
                    self.gitBusyOperation = nil
                }
                await MainActor.run {
                    self.refreshSharedGitPushAvailability()
                }
                return
            }

            if !pullResult.output.isEmpty {
                outputParts.append(pullResult.output)
            }
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)

            await MainActor.run {
                self.gitCredentialPrompt = nil
                self.gitRemoteDescription = remoteURL
                if self.gitOutput?.isEmpty == false {
                    if !outputParts.isEmpty {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                    }
                } else {
                    self.gitOutput = outputParts.joined(separator: "\n\n")
                }
                self.infoMessage = successMessage
                self.isGitBusy = false
                self.gitBusyOperation = nil
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        } catch {
            await refreshWorkspacesAndLoadCurrent(forceInfoMessage: false)

            await MainActor.run {
                self.gitCredentialPrompt = nil
                self.gitRemoteDescription = remoteURL
                if self.gitOutput?.isEmpty == false {
                    if !outputParts.isEmpty {
                        if !(self.gitOutput?.hasSuffix("\n") ?? false) {
                            self.appendGitOutput("\n")
                        }
                        self.appendGitOutput(outputParts.joined(separator: "\n\n"))
                    }
                } else {
                    self.gitOutput = outputParts.joined(separator: "\n\n")
                }
                self.errorMessage = error.localizedDescription
                self.isGitBusy = false
                self.gitBusyOperation = nil
            }
            await MainActor.run {
                self.refreshSharedGitPushAvailability()
            }
        }
    }

    private func loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: Bool = false) async {
        guard let workspaceRoot = activeWorkspaceDirectoryURL else {
            return
        }

        do {
            let loaded = try await sharedWorkspaceCoordinator.loadSharedContent(
                workspaceRoot: workspaceRoot,
                existingCollections: workspace.collections,
                existingUtilities: workspace.utilityLibraries,
                existingFlows: workspace.flows,
                currentActiveEnvironmentID: workspace.activeEnvironmentID,
                forceInfoMessage: forceInfoMessage,
                activeWorkspaceName: workspace.activeWorkspaceName
            )

            try await sharedWorkspaceCoordinator.applyPendingSaves(loaded.pendingSaves)

            workspace.collections = loaded.collections
            workspace.environments = loaded.environments
            workspace.utilityLibraries = loaded.utilityLibraries
            workspace.flows = loaded.flows
            persistedSharedEnvironments = loaded.persistedEnvironments
            workspace.activeEnvironmentID = loaded.activeEnvironmentID

            if let globalVariables = loaded.globalVariables {
                workspace.globalVariables = globalVariables
            }
            if let history = loaded.history {
                workspace.history = history
            }
            if let requestDrafts = loaded.requestDrafts {
                workspace.requestDrafts = requestDrafts
            }

            reconcileOpenTabsWithWorkspace()
            sanitizeEnvironmentSelections()

            if let infoMessage = loaded.infoMessage {
                self.infoMessage = infoMessage
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsertEnvironment(_ importedEnvironment: EnvironmentProfile) {
        var environments = workspace.environments
        var activeEnvironmentID = workspace.activeEnvironmentID
        environmentCoordinator.upsertImported(
            importedEnvironment,
            into: &environments,
            activeEnvironmentID: &activeEnvironmentID
        )
        workspace.environments = environments
        workspace.activeEnvironmentID = activeEnvironmentID
        sanitizeEnvironmentSelections()
    }

    private func sanitizeEnvironmentSelections() {
        var activeEnvironmentID = workspace.activeEnvironmentID
        var drafts = workspace.requestDrafts
        environmentCoordinator.sanitizeSelections(
            environments: workspace.environments,
            activeEnvironmentID: &activeEnvironmentID,
            tabs: tabs,
            drafts: &drafts
        )
        workspace.activeEnvironmentID = activeEnvironmentID
        workspace.requestDrafts = drafts
    }

    private func reconcileOpenTabsWithWorkspace(
        affectedCollectionIDs: Set<UUID>? = nil,
        affectedEnvironmentIDs: Set<UUID>? = nil
    ) {
        for tab in tabs {
            let hasDraft: Bool
            if let collectionID = tab.sourceCollectionID, let nodeID = tab.sourceNodeID {
                hasDraft = draftState(for: nodeID, collectionID: collectionID) != nil
            } else {
                hasDraft = false
            }
            let matchesPersistedBaseline =
                requestsEquivalentForPersistence(tab.persistedRequest, tab.request)
                && tab.selectedEnvironmentID == tab.persistedSelectedEnvironmentID
                && environmentCoordinator.variablesEquivalent(tab.pendingEnvironmentVariables, tab.persistedEnvironmentVariables)

            guard !hasDraft, matchesPersistedBaseline else {
                continue
            }

            let shouldRefreshRequest: Bool
            if let affectedCollectionIDs, let collectionID = tab.sourceCollectionID {
                shouldRefreshRequest = affectedCollectionIDs.contains(collectionID)
            } else {
                shouldRefreshRequest = affectedCollectionIDs == nil
            }

            let selectedEnvironmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID
            let shouldRefreshEnvironment: Bool
            if let affectedEnvironmentIDs, let selectedEnvironmentID {
                shouldRefreshEnvironment = affectedEnvironmentIDs.contains(selectedEnvironmentID)
            } else {
                shouldRefreshEnvironment = affectedEnvironmentIDs == nil
            }

            if shouldRefreshRequest,
               let collectionID = tab.sourceCollectionID,
               let nodeID = tab.sourceNodeID,
               let node = savedRequestNode(nodeID: nodeID, collectionID: collectionID) {
                let savedRequest = CollectionScriptSupport.mergeScriptsIntoSavedRequest(node: node)
                tab.request = savedRequest
                tab.persistedRequest = savedRequest
                tab.editorRefreshToken = UUID()
            }

            if shouldRefreshEnvironment {
                let environmentVariables = environmentCoordinator.variables(for: selectedEnvironmentID, in: workspace.environments)
                tab.pendingEnvironmentVariables = environmentVariables
                tab.persistedEnvironmentVariables = environmentVariables
            }
        }
    }

    private func ensureActiveWorkspaceExistsIfNeeded() async throws {
        guard let repositoryRoot = sharedRepositoryURL else {
            return
        }

        if let activeWorkspaceName = workspace.activeWorkspaceName,
           !activeWorkspaceName.isEmpty {
            return
        }

        let defaultWorkspaceName = try await persistenceCoordinator.ensureDefaultWorkspace(in: repositoryRoot)
        let workspaceNames = try await persistenceCoordinator.workspaceNames(in: repositoryRoot)
        workspace.activeWorkspaceName = defaultWorkspaceName
        availableWorkspaceNames = workspaceNames
        try await persistenceCoordinator.saveLocal(workspace)
    }

    private func refreshWorkspacesAndLoadCurrent(forceInfoMessage: Bool) async {
        restoreSharedRepositoryAccessIfNeeded()

        guard let repositoryRoot = sharedRepositoryURL else {
            availableWorkspaceNames = []
            gitRemoteDescription = nil
            return
        }

        do {
            let context = try await sharedWorkspaceCoordinator.refreshRepositoryContext(
                repositoryRoot: repositoryRoot,
                currentWorkspace: workspace
            )

            availableWorkspaceNames = context.workspaceNames
            if let activeWorkspaceName = context.activeWorkspaceName {
                workspace.activeWorkspaceName = activeWorkspaceName
            }
            if context.shouldPersistLocalWorkspace {
                try await persistenceCoordinator.saveLocal(workspace)
            }
            gitRemoteDescription = context.gitRemoteDescription
            await loadCollectionsFromSharedDirectoryIfNeeded(forceInfoMessage: forceInfoMessage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestsEquivalentForPersistence(_ lhs: APIRequestModel, _ rhs: APIRequestModel) -> Bool {
        normalizedRequest(lhs) == normalizedRequest(rhs)
    }

    private func normalizedRequest(_ request: APIRequestModel) -> APIRequestModel {
        APIRequestModel(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
            name: request.name,
            transportKind: request.transportKind,
            httpRequestTargetKind: request.httpRequestTargetKind,
            method: request.method,
            url: request.url,
            queryItems: request.queryItems.map(normalizedKeyValueEntry),
            pathVariables: request.pathVariables.map(normalizedKeyValueEntry),
            headers: request.headers.map(normalizedKeyValueEntry),
            cookies: request.cookies.map(normalizedKeyValueEntry),
            auth: request.auth,
            body: RequestBodyModel(
                kind: request.body.kind,
                raw: request.body.raw,
                parameters: request.body.parameters.map(normalizedKeyValueEntry)
            ),
            scripts: request.scripts.map(normalizedScriptDefinition),
            localVariables: request.localVariables.map(normalizedKeyValueEntry),
            timeoutSeconds: request.timeoutSeconds,
            retryOn206Count: request.retryOn206Count,
            retryOn206DelayMilliseconds: request.retryOn206DelayMilliseconds,
            tlsValidationMode: request.tlsValidationMode,
            minimumTLSVersion: request.minimumTLSVersion,
            webSocketSubprotocols: request.webSocketSubprotocols,
            webSocketOpenTimeoutSeconds: request.webSocketOpenTimeoutSeconds,
            webSocketReconnectAttempts: request.webSocketReconnectAttempts,
            webSocketReconnectIntervalMilliseconds: request.webSocketReconnectIntervalMilliseconds,
            webSocketMaximumMessageSizeMB: request.webSocketMaximumMessageSizeMB,
            webSocketPingIntervalSeconds: request.webSocketPingIntervalSeconds,
            webSocketKeepAliveMessage: request.webSocketKeepAliveMessage,
            webSocketKeepAliveIntervalSeconds: request.webSocketKeepAliveIntervalSeconds,
            awsAccessPortalURLTemplate: request.awsAccessPortalURLTemplate
        )
    }

    private func normalizedKeyValueEntry(_ entry: KeyValueEntry) -> KeyValueEntry {
        KeyValueEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
            key: entry.key,
            value: entry.value,
            isEnabled: entry.isEnabled
        )
    }

    private func normalizedScriptDefinition(_ script: ScriptDefinition) -> ScriptDefinition {
        ScriptDefinition(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
            name: script.name,
            listen: script.listen,
            language: script.language,
            source: script.source
        )
    }

    private func validateRepositoryDirectory(_ url: URL, requireEmpty: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.persistence("The selected shared storage directory does not exist.")
        }

        guard requireEmpty else {
            return
        }

        if let recognizedExistingWorkdir = try? isRecognizedExistingWorkdir(url),
           recognizedExistingWorkdir {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        if !contents.isEmpty {
            throw AppError.persistence("Select an empty folder for the initial shared storage.")
        }
    }

    private func isRecognizedExistingWorkdir(_ url: URL) throws -> Bool {
        let markerURL = url.appendingPathComponent(SharedCollectionsRepository.workdirMarkerFilename, isDirectory: false)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            return true
        }

        let hiddenDotMarkerURL = url.appendingPathComponent(".directoritrabajo", isDirectory: false)
        if FileManager.default.fileExists(atPath: hiddenDotMarkerURL.path) {
            return true
        }

        let gitURL = url.appendingPathComponent(".git", isDirectory: false)
        if FileManager.default.fileExists(atPath: gitURL.path) {
            return true
        }

        return false
    }
}

private actor FlowBatchTranscriptCollector {
    private var stored: [String] = []

    func append(_ line: String) {
        stored.append(line)
    }

    func lines() -> [String] {
        stored
    }
}
