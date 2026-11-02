@testable import EfbyPresentation
import Foundation
import XCTest

final class AutosavePersistenceTests: XCTestCase {
    @MainActor
    func testSharedSaveThenLocalEditKeepsNewestLocalAndExplicitSharedValues() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var explicitlySaved = fixture.initial
        explicitlySaved.environments[0].variables[0].value = "E1"
        var newerLocal = explicitlySaved
        newerLocal.environments[0].variables[0].value = "E2"

        fixture.coordinator.schedulePersistence(snapshot: explicitlySaved, workspaceRoot: fixture.workspaceRoot, options: .init())
        fixture.coordinator.schedulePersistence(snapshot: newerLocal, workspaceRoot: fixture.workspaceRoot, options: .localOnly)
        try await fixture.coordinator.flush()

        let local = try await fixture.local.load()
        let shared = try await fixture.shared.loadWorkspaceSnapshot(from: fixture.workspaceRoot)
        let environments = try await fixture.shared.loadEnvironments(from: fixture.workspaceRoot)
        XCTAssertEqual(local.environments.first?.variables.first?.value, "E2")
        XCTAssertEqual(shared?.environments.first?.variables.first?.value, "E1")
        XCTAssertEqual(environments.first?.variables.first?.value, "E1")
    }

    @MainActor
    func testLocalEditThenExplicitSharedSaveUsesLatestSaveForBothDestinations() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var earlierLocal = fixture.initial
        earlierLocal.environments[0].variables[0].value = "E2"
        var explicitlySaved = earlierLocal
        explicitlySaved.environments[0].variables[0].value = "E1"

        fixture.coordinator.schedulePersistence(snapshot: earlierLocal, workspaceRoot: fixture.workspaceRoot, options: .localOnly)
        fixture.coordinator.schedulePersistence(snapshot: explicitlySaved, workspaceRoot: fixture.workspaceRoot, options: .init())
        try await fixture.coordinator.flush()

        let local = try await fixture.local.load()
        let shared = try await fixture.shared.loadWorkspaceSnapshot(from: fixture.workspaceRoot)
        let environments = try await fixture.shared.loadEnvironments(from: fixture.workspaceRoot)
        XCTAssertEqual(local.environments.first?.variables.first?.value, "E1")
        XCTAssertEqual(shared?.environments.first?.variables.first?.value, "E1")
        XCTAssertEqual(environments.first?.variables.first?.value, "E1")
    }

    @MainActor
    func testCollectionOnlySaveDoesNotPublishLocalEnvironmentEdits() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var snapshot = fixture.initial
        snapshot.collections[0].items[0].request?.url = "https://example.invalid/C1"
        snapshot.environments[0].variables[0].value = "E2"
        fixture.coordinator.schedulePersistence(snapshot: snapshot, workspaceRoot: fixture.workspaceRoot,
            options: Self.options(collections: true, environments: false))
        try await fixture.coordinator.flush()

        let local = try await fixture.local.load()
        let shared = try await fixture.shared.loadWorkspaceSnapshot(from: fixture.workspaceRoot)
        let environments = try await fixture.shared.loadEnvironments(from: fixture.workspaceRoot)
        let collections = try await fixture.shared.loadCollections(from: fixture.workspaceRoot)
        XCTAssertEqual(local.environments.first?.variables.first?.value, "E2")
        XCTAssertEqual(shared?.environments.first?.variables.first?.value, "E0")
        XCTAssertEqual(environments.first?.variables.first?.value, "E0")
        XCTAssertEqual(shared?.collections.first?.items.first?.request?.url, "https://example.invalid/C1")
        XCTAssertEqual(collections.first?.items.first?.request?.url, "https://example.invalid/C1")
    }

    @MainActor
    func testEnvironmentOnlySaveDoesNotPublishLocalCollectionEdits() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var snapshot = fixture.initial
        snapshot.collections[0].items[0].request?.url = "https://example.invalid/C2"
        snapshot.environments[0].variables[0].value = "E1"
        fixture.coordinator.schedulePersistence(snapshot: snapshot, workspaceRoot: fixture.workspaceRoot,
            options: Self.options(collections: false, environments: true))
        try await fixture.coordinator.flush()

        let local = try await fixture.local.load()
        let shared = try await fixture.shared.loadWorkspaceSnapshot(from: fixture.workspaceRoot)
        let collections = try await fixture.shared.loadCollections(from: fixture.workspaceRoot)
        let environments = try await fixture.shared.loadEnvironments(from: fixture.workspaceRoot)
        XCTAssertEqual(local.collections.first?.items.first?.request?.url, "https://example.invalid/C2")
        XCTAssertEqual(shared?.collections.first?.items.first?.request?.url, "https://example.invalid/C0")
        XCTAssertEqual(collections.first?.items.first?.request?.url, "https://example.invalid/C0")
        XCTAssertEqual(shared?.environments.first?.variables.first?.value, "E1")
        XCTAssertEqual(environments.first?.variables.first?.value, "E1")
    }

    @MainActor
    func testFailedSharedWritePreservesRecoverableDraftAcrossRestartAndRetryConfirmsIt() async throws {
        let failure = AutosaveFailureSwitch()
        let fixture = try await Fixture.make(failure: failure)
        defer { fixture.cleanup() }
        var snapshot = fixture.initial
        let original = try XCTUnwrap(snapshot.collections[0].items[0].request)
        var edited = original
        edited.url = "https://example.invalid/C1"
        snapshot.collections[0].items[0].request = edited
        let environment = snapshot.environments[0]
        snapshot.requestDrafts = [RequestDraftState(
            workspaceName: "default", collectionID: snapshot.collections[0].id,
            nodeID: snapshot.collections[0].items[0].id, request: edited,
            selectedEnvironmentID: environment.id, pendingEnvironmentVariables: environment.variables,
            persistedRequest: original, persistedSelectedEnvironmentID: environment.id,
            persistedEnvironmentVariables: environment.variables
        )]
        failure.setFailure(true)
        fixture.coordinator.schedulePersistence(snapshot: snapshot, workspaceRoot: fixture.workspaceRoot,
            options: Self.options(collections: true, environments: false))
        do {
            try await fixture.coordinator.flush()
            XCTFail("Expected shared installation failure")
        } catch {}

        let checkpoint = try await fixture.local.load()
        XCTAssertEqual(checkpoint.requestDrafts.first?.request.url, edited.url)
        XCTAssertEqual(checkpoint.requestDrafts.first?.persistedRequest?.url, original.url)
        let previousShared = try await fixture.shared.loadCollections(from: fixture.workspaceRoot)
        XCTAssertEqual(previousShared.first?.items.first?.request?.url, original.url)

        let restarted = MainViewModel(repository: fixture.local, sharedCollectionsRepository: fixture.shared, autoloadWorkspace: false)
        await restarted.loadWorkspace()
        XCTAssertNil(restarted.errorMessage)
        let restoredTab = try XCTUnwrap(restarted.currentTab)
        XCTAssertEqual(restoredTab.request.url, edited.url)
        XCTAssertEqual(restoredTab.persistedRequest.url, original.url)
        XCTAssertTrue(restarted.hasPendingRequestChanges(for: restoredTab))

        failure.setFailure(false)
        try await fixture.coordinator.flush()
        let confirmed = try await fixture.local.load()
        let updatedShared = try await fixture.shared.loadCollections(from: fixture.workspaceRoot)
        XCTAssertTrue(confirmed.requestDrafts.isEmpty)
        XCTAssertEqual(confirmed.collections.first?.items.first?.request?.url, edited.url)
        XCTAssertEqual(updatedShared.first?.items.first?.request?.url, edited.url)

        let confirmedRestart = MainViewModel(repository: fixture.local, sharedCollectionsRepository: fixture.shared, autoloadWorkspace: false)
        await confirmedRestart.loadWorkspace()
        XCTAssertNil(confirmedRestart.errorMessage)
        let cleanTab = try XCTUnwrap(confirmedRestart.currentTab)
        XCTAssertEqual(cleanTab.request.url, edited.url)
        XCTAssertEqual(cleanTab.persistedRequest.url, edited.url)
        XCTAssertFalse(confirmedRestart.hasPendingRequestChanges(for: cleanTab))
        XCTAssertTrue(confirmedRestart.workspace.requestDrafts.isEmpty)
    }

    @MainActor
    func testLegacyCollectionOnlyAdapterDoesNotPublishLocalEnvironmentEdits() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var snapshot = fixture.initial
        snapshot.collections[0].items[0].request?.url = "https://example.invalid/C1"
        snapshot.environments[0].variables[0].value = "E2"
        let legacy = PersistWorkspaceSnapshotUseCase(
            saveWorkspace: SaveWorkspaceUseCase(repository: fixture.local), sharedRepository: fixture.shared
        )

        try await legacy(snapshot, workspaceRoot: fixture.workspaceRoot,
            options: Self.options(collections: true, environments: false))

        let local = try await fixture.local.load()
        let shared = try await fixture.shared.loadWorkspaceSnapshot(from: fixture.workspaceRoot)
        let environments = try await fixture.shared.loadEnvironments(from: fixture.workspaceRoot)
        let collections = try await fixture.shared.loadCollections(from: fixture.workspaceRoot)
        XCTAssertEqual(local.environments.first?.variables.first?.value, "E2")
        XCTAssertEqual(shared?.environments.first?.variables.first?.value, "E0")
        XCTAssertEqual(environments.first?.variables.first?.value, "E0")
        XCTAssertEqual(shared?.collections.first?.items.first?.request?.url, "https://example.invalid/C1")
        XCTAssertEqual(collections.first?.items.first?.request?.url, "https://example.invalid/C1")
    }

    private static func options(collections: Bool, environments: Bool) -> WorkspacePersistenceOptions {
        WorkspacePersistenceOptions(syncSharedCollections: collections, syncSharedEnvironments: environments,
            syncSharedFlows: false, syncSharedUtilities: false)
    }

    private struct Fixture {
        let root: URL
        let workspaceRoot: URL
        let local: WorkspaceRepository
        let shared: SharedCollectionsRepository
        let coordinator: WorkspacePersistenceCoordinator
        let initial: WorkspaceState

        @MainActor static func make(failure: AutosaveFailureSwitch? = nil) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutosavePersistenceTests-\(UUID())", isDirectory: true)
            let repositoryRoot = root.appendingPathComponent("shared", isDirectory: true)
            let workspaceRoot = repositoryRoot.appendingPathComponent("default", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            let local = WorkspaceRepository(storageURL: root.appendingPathComponent("local.json"))
            let shared: SharedCollectionsRepository
            if let failure {
                shared = SharedCollectionsRepository(fileManager: AutosaveFailingFileManager(failure: failure))
            } else {
                shared = SharedCollectionsRepository()
            }
            let environment = EnvironmentProfile(name: "Environment", variables: [VariableValue(key: "value", value: "E0")])
            let initial = WorkspaceState(
                sharedCollectionsDirectoryPath: repositoryRoot.path, activeWorkspaceName: "default",
                collections: [CollectionModel(info: CollectionInfoModel(name: "Collection"), items: [
                    CollectionNode(name: "Ping", kind: .request, request: APIRequestModel(name: "Ping", url: "https://example.invalid/C0"))
                ])], environments: [environment], activeEnvironmentID: environment.id
            )
            try await local.save(initial)
            try await shared.saveCollections(initial.collections, to: workspaceRoot)
            try await shared.saveEnvironments(initial.environments, to: workspaceRoot)
            try await shared.saveWorkspaceSnapshot(initial, to: workspaceRoot)
            let save = SaveWorkspaceUseCase(repository: local)
            let coordinator = WorkspacePersistenceCoordinator(loadWorkspace: LoadWorkspaceUseCase(repository: local),
                saveWorkspace: save, persistSnapshot: PersistWorkspaceSnapshotUseCase(saveWorkspace: save, sharedRepository: shared),
                sharedRepository: shared)
            return Fixture(root: root, workspaceRoot: workspaceRoot, local: local, shared: shared,
                coordinator: coordinator, initial: initial)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class AutosaveFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = false

    func setFailure(_ value: Bool) {
        lock.lock()
        fails = value
        lock.unlock()
    }

    var isFailing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fails
    }
}

private final class AutosaveFailingFileManager: FileManager, @unchecked Sendable {
    private let failure: AutosaveFailureSwitch

    init(failure: AutosaveFailureSwitch) {
        self.failure = failure
        super.init()
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        if failure.isFailing, source.lastPathComponent == ".collections.efby-staging", destination.lastPathComponent == "collections" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: source, to: destination)
    }
}
