import EfbyPresentation
import Foundation
import XCTest

final class AutosaveTests: XCTestCase {
    @MainActor
    func testRuntimeAndLocalRefreshPreserveUnsavedEnvironmentBaselineUntilSharedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutosaveEnvironment-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = root.appendingPathComponent("default", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let environment = EnvironmentProfile(name: "Environment", variables: [VariableValue(key: "value", value: "E1")])
        let request = APIRequestModel(name: "Request", url: "https://example.invalid/request")
        let collection = CollectionModel(info: CollectionInfoModel(name: "Collection"), items: [CollectionNode(name: "Request", kind: .request, request: request)])
        let initial = WorkspaceState(sharedCollectionsDirectoryPath: root.path, activeWorkspaceName: "default",
            collections: [collection], environments: [environment], activeEnvironmentID: environment.id)
        let repository = AutosaveLocalRepository(initial)
        let shared = SharedCollectionsRepository()
        try await shared.saveCollections([collection], to: workspaceRoot)
        try await shared.saveEnvironments([environment], to: workspaceRoot)
        try await shared.saveWorkspaceSnapshot(initial, to: workspaceRoot)
        let runner = AutosaveHTTPRunner(repository: repository, environmentUpdate: [VariableValue(key: "value", value: "E2")])
        let vm = MainViewModel(dependencies: .live(workspaceRepository: repository, sharedCollectionsRepository: shared,
            httpService: runner), autoloadWorkspace: false)
        await vm.loadWorkspace()
        let source = try XCTUnwrap(vm.currentTab)
        vm.open(history: HistoryEntry(request: APIRequestModel(name: "Sibling", url: "https://example.invalid/sibling"), response: nil))
        let sibling = try XCTUnwrap(vm.currentTab)
        vm.selectedTabID = source.id
        vm.sendCurrentRequest()
        try await eventually { source.response != nil && !source.isSending }
        XCTAssertTrue(vm.hasPendingEnvironmentChanges(for: source))
        XCTAssertTrue(vm.hasPendingEnvironmentChanges(for: sibling))
        XCTAssertEqual(source.persistedEnvironmentVariables?.first?.value, "E1")

        await vm.open(request: collection.items[0], in: collection)
        let local = await repository.snapshot
        let sharedBeforeSave = try await shared.loadEnvironments(from: workspaceRoot)
        XCTAssertEqual(local.environments.first?.variables.first?.value, "E2")
        XCTAssertEqual(sharedBeforeSave.first?.variables.first?.value, "E1")
        XCTAssertTrue(vm.hasPendingEnvironmentChanges(for: source))
        XCTAssertTrue(vm.hasPendingEnvironmentChanges(for: sibling))

        vm.saveCurrentEnvironmentChanges()
        let saved = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(saved)
        let sharedAfterSave = try await shared.loadEnvironments(from: workspaceRoot)
        XCTAssertEqual(sharedAfterSave.first?.variables.first?.value, "E2")
        XCTAssertFalse(vm.hasPendingEnvironmentChanges(for: source))
        XCTAssertFalse(vm.hasPendingEnvironmentChanges(for: sibling))
        XCTAssertFalse(vm.hasPendingEnvironmentStoreChanges)
    }

    @MainActor
    func testFiftyRequestEditsAndTerminationWriteOneLatestLocalSnapshot() async throws {
        let (vm, repository, tab) = try await scenario()
        for index in 0..<50 {
            tab.request.url = "https://example.invalid/\(index)"
            vm.persistPendingChanges(for: tab)
        }
        XCTAssertTrue(vm.hasPendingRequestEditorChanges(for: tab))
        let success = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(success)
        let writes = await repository.successfulWrites
        let saved = await repository.snapshot
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(saved.collections.first?.items.first?.request?.url, "https://example.invalid/49")
        XCTAssertFalse(vm.hasPendingRequestEditorChanges(for: tab))
    }

    @MainActor
    func testSnapshotOfManyOpenTabsDoesNotWritePerTab() async throws {
        let repository = AutosaveLocalRepository(WorkspaceState(activeWorkspaceName: "default"))
        let vm = MainViewModel(dependencies: .live(workspaceRepository: repository), autoloadWorkspace: false)
        vm.workspace = await repository.snapshot
        for _ in 0..<50 { vm.newRequest() }
        let success = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(success)
        let writes = await repository.successfulWrites
        let saved = await repository.snapshot
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(saved.requestDrafts.count, 50)
    }

    @MainActor
    func testFailedSaveKeepsRequestDirtyAndPreventsTerminationUntilRetrySucceeds() async throws {
        let (vm, repository, tab) = try await scenario()
        let original = tab.persistedRequest
        tab.request.url = "https://example.invalid/edited"
        vm.persistPendingChanges(for: tab)
        await repository.setFailing(true)
        let failed = await vm.flushStateForApplicationTermination()
        XCTAssertFalse(failed)
        XCTAssertEqual(tab.persistedRequest, original)
        XCTAssertTrue(vm.hasPendingRequestEditorChanges(for: tab))
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(tab.request.url, "https://example.invalid/edited")

        await repository.setFailing(false)
        let retried = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(retried)
        XCTAssertFalse(vm.hasPendingRequestEditorChanges(for: tab))
        XCTAssertNil(vm.errorMessage)
        let saved = await repository.snapshot
        XCTAssertEqual(saved.collections.first?.items.first?.request?.url, "https://example.invalid/edited")
    }

    @MainActor
    func testSendAbortsAfterFailedFlushWithoutReloadingOlderVariables() async throws {
        let request = APIRequestModel(name: "Request", url: "https://example.invalid/original")
        let collection = CollectionModel(info: CollectionInfoModel(name: "Collection"), items: [CollectionNode(name: "Request", kind: .request, request: request)])
        let initial = WorkspaceState(activeWorkspaceName: "default", globalVariables: [VariableValue(key: "value", value: "old")], collections: [collection])
        let repository = AutosaveLocalRepository(initial)
        let runner = AutosaveHTTPRunner(repository: repository)
        let vm = MainViewModel(dependencies: .live(workspaceRepository: repository, httpService: runner), autoloadWorkspace: false)
        vm.workspace = initial
        await vm.open(request: collection.items[0], in: collection)
        let tab = try XCTUnwrap(vm.currentTab)
        vm.workspace.globalVariables = [VariableValue(key: "value", value: "new")]
        tab.request.url = "https://example.invalid/new"
        vm.persistPendingChanges(for: tab)
        await repository.setFailing(true)
        let previousLoads = await repository.loads
        vm.sendCurrentRequest()
        let task = try XCTUnwrap(tab.task)
        await task.value
        let calls = await runner.callCount
        let loads = await repository.loads
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(loads, previousLoads)
        XCTAssertEqual(vm.workspace.globalVariables.first?.value, "new")
        XCTAssertFalse(tab.isSending)
        XCTAssertNotNil(vm.errorMessage)
        await repository.setFailing(false)
        _ = await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testSendFlushesNewestRequestBeforeStartingTraffic() async throws {
        let request = APIRequestModel(name: "Request", url: "https://example.invalid/original")
        let collection = CollectionModel(info: CollectionInfoModel(name: "Collection"), items: [CollectionNode(name: "Request", kind: .request, request: request)])
        let initial = WorkspaceState(activeWorkspaceName: "default", collections: [collection])
        let repository = AutosaveLocalRepository(initial)
        let runner = AutosaveHTTPRunner(repository: repository)
        let vm = MainViewModel(dependencies: .live(workspaceRepository: repository, httpService: runner), autoloadWorkspace: false)
        vm.workspace = initial
        await vm.open(request: collection.items[0], in: collection)
        let tab = try XCTUnwrap(vm.currentTab)
        tab.request.url = "https://example.invalid/newest"
        vm.persistPendingChanges(for: tab)
        vm.sendCurrentRequest()
        try await eventually { tab.response != nil }
        let snapshotAtSend = await runner.snapshotAtSend
        XCTAssertEqual(snapshotAtSend?.collections.first?.items.first?.request?.url, "https://example.invalid/newest")
        _ = await vm.flushStateForApplicationTermination()
    }

    @MainActor
    func testFailedFlushLeavesTabOpenForRetry() async throws {
        let (vm, repository, tab) = try await scenario()
        tab.request.url = "https://example.invalid/unsaved"
        vm.persistPendingChanges(for: tab)
        await repository.setFailing(true)
        vm.closeTab(tab)
        let failed = await vm.flushStateForApplicationTermination()
        XCTAssertFalse(failed)
        XCTAssertTrue(vm.tabs.contains(where: { $0.id == tab.id }))
        XCTAssertEqual(tab.request.url, "https://example.invalid/unsaved")
        await repository.setFailing(false)
        vm.closeTab(tab)
        let saved = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(saved)
        XCTAssertFalse(vm.tabs.contains(where: { $0.id == tab.id }))
    }

    @MainActor
    func testFailedFlushRestoresCurrentWorkspaceAndItsEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutosaveTransition-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let request = APIRequestModel(name: "Request", url: "https://example.invalid/original")
        let collection = CollectionModel(info: CollectionInfoModel(name: "Collection"), items: [CollectionNode(name: "Request", kind: .request, request: request)])
        let initial = WorkspaceState(sharedCollectionsDirectoryPath: root.path, activeWorkspaceName: "A", collections: [collection])
        let repository = AutosaveLocalRepository(initial)
        let shared = SharedCollectionsRepository()
        try await shared.saveCollections([collection], to: root.appendingPathComponent("A"))
        let vm = MainViewModel(dependencies: .live(workspaceRepository: repository, sharedCollectionsRepository: shared), autoloadWorkspace: false)
        vm.workspace = initial
        await vm.open(request: collection.items[0], in: collection)
        let tab = try XCTUnwrap(vm.currentTab)
        tab.request.url = "https://example.invalid/unsaved-A"
        vm.persistPendingChanges(for: tab)
        await repository.setFailing(true)
        vm.selectWorkspace(named: "B")
        try await eventually { vm.workspace.activeWorkspaceName == "A" && vm.currentTab != nil && vm.errorMessage != nil }
        XCTAssertEqual(vm.currentTab?.request.url, "https://example.invalid/unsaved-A")
        XCTAssertEqual(vm.workspace.collections.first?.items.first?.request?.url, "https://example.invalid/unsaved-A")
        await repository.setFailing(false)
        _ = await vm.flushStateForApplicationTermination()
    }

    @MainActor
    private func scenario() async throws -> (MainViewModel, AutosaveLocalRepository, RequestTabState) {
        let request = APIRequestModel(name: "Request", url: "https://example.invalid/original")
        let collection = CollectionModel(info: CollectionInfoModel(name: "Collection"), items: [CollectionNode(name: "Request", kind: .request, request: request)])
        let initial = WorkspaceState(activeWorkspaceName: "default", collections: [collection])
        let repository = AutosaveLocalRepository(initial)
        let vm = MainViewModel(dependencies: .live(workspaceRepository: repository), autoloadWorkspace: false)
        vm.workspace = initial
        await vm.open(request: collection.items[0], in: collection)
        return (vm, repository, try XCTUnwrap(vm.currentTab))
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AppError.persistence("Autosave action did not complete") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor AutosaveLocalRepository: WorkspaceRepositoryProtocol {
    private(set) var snapshot: WorkspaceState
    private(set) var successfulWrites = 0
    private(set) var loads = 0
    private var failing = false
    init(_ initial: WorkspaceState) { snapshot = initial }
    func load() -> WorkspaceState { loads += 1; return snapshot }
    func save(_ state: WorkspaceState) throws {
        if failing { throw AppError.persistence("Autosave test write failure") }
        snapshot = state
        successfulWrites += 1
    }
    func setFailing(_ failing: Bool) { self.failing = failing }
}

private actor AutosaveHTTPRunner: HTTPExecutionServiceProtocol {
    let repository: AutosaveLocalRepository
    let environmentUpdate: [VariableValue]?
    private(set) var callCount = 0
    private(set) var snapshotAtSend: WorkspaceState?
    init(repository: AutosaveLocalRepository, environmentUpdate: [VariableValue]? = nil) {
        self.repository = repository
        self.environmentUpdate = environmentUpdate
    }
    func execute(request: APIRequestModel, globals: [VariableValue], collectionVariables: [VariableValue],
                 environmentVariables: [VariableValue], workspaceEnvironments: [EnvironmentProfile],
                 activeEnvironmentID: UUID?, utilityLibraries: [WorkspaceScriptUtility]) async throws -> ExecutionOutcome {
        callCount += 1
        snapshotAtSend = await repository.snapshot
        return ExecutionOutcome(response: HTTPResponseModel(url: request.url, statusCode: 200, statusText: "OK", headers: [],
            body: "OK", durationMilliseconds: 1, sizeBytes: 2, mimeType: "text/plain"), rawRequest: "request", rawResponse: "response",
            updatedGlobals: globals, updatedCollection: collectionVariables, updatedEnvironment: environmentUpdate ?? environmentVariables,
            updatedLocal: request.localVariables, logs: [])
    }
}
