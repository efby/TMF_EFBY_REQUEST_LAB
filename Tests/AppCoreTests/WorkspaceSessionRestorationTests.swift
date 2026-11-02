@testable import EfbyPresentation
import Foundation
import XCTest

final class WorkspaceSessionRestorationTests: XCTestCase {
    @MainActor
    func testUnresolvableBookmarkRecoversSavedDirectoryAndSelectedWorkspace() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let invalidBookmark = Data("bookmark from an older app installation".utf8)
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryBookmarkData = invalidBookmark
        try await fixture.local.save(previous)

        let vm = fixture.makeViewModel()
        await vm.loadWorkspace()
        try assertRestored(vm, fixture: fixture)
        XCTAssertNotEqual(vm.workspace.sharedCollectionsDirectoryBookmarkData, invalidBookmark)
        XCTAssertNotNil(vm.workspace.sharedCollectionsDirectoryBookmarkData)
        let saved = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(saved)

        let restored = try await fixture.local.load()
        XCTAssertEqual(restored.activeWorkspaceName, "Beta")
        XCTAssertEqual(restored.sharedCollectionsDirectoryPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
                       fixture.workdir.standardizedFileURL)
        XCTAssertNotEqual(restored.sharedCollectionsDirectoryBookmarkData, invalidBookmark)
    }

    @MainActor
    func testPlainLegacyBookmarkRetainsSelectionAcrossTwoSessions() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryBookmarkData = try fixture.workdir.bookmarkData(options: .minimalBookmark)
        try await fixture.local.save(previous)

        let first = fixture.makeViewModel()
        await first.loadWorkspace()
        try assertRestored(first, fixture: fixture)
        let saved = await first.flushStateForApplicationTermination()
        XCTAssertTrue(saved)

        let second = fixture.makeViewModel()
        await second.loadWorkspace()
        try assertRestored(second, fixture: fixture)
        let savedAgain = await second.flushStateForApplicationTermination()
        XCTAssertTrue(savedAgain)
    }

    @MainActor
    func testPathOnlySessionFromOlderSchemaRecoversItsSelectedWorkspace() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var previous = fixture.selectedWorkspace
        previous.schemaVersion = 2
        previous.sharedCollectionsDirectoryBookmarkData = nil
        try await fixture.local.save(previous)

        let vm = fixture.makeViewModel()
        await vm.loadWorkspace()
        try assertRestored(vm, fixture: fixture)
        XCTAssertEqual(vm.workspace.schemaVersion, WorkspaceState.currentSchemaVersion)
        XCTAssertNotNil(vm.workspace.sharedCollectionsDirectoryBookmarkData)
        let saved = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(saved)
    }

    @MainActor
    func testResolvedBookmarkTakesPrecedenceOverAnOutdatedSavedPath() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let decoy = fixture.root.appendingPathComponent("outdated-location", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryPath = decoy.path
        previous.sharedCollectionsDirectoryBookmarkData = try fixture.workdir.bookmarkData(options: .minimalBookmark)
        try await fixture.local.save(previous)

        let vm = fixture.makeViewModel()
        await vm.loadWorkspace()
        try assertRestored(vm, fixture: fixture)
        XCTAssertEqual(vm.workspace.sharedCollectionsDirectoryPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
                       fixture.workdir.standardizedFileURL)
        let saved = await vm.flushStateForApplicationTermination()
        XCTAssertTrue(saved)
    }

    @MainActor
    func testDeniedAccessDoesNotDiscardTheSavedSelectionOrAcceptThePath() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryBookmarkData = Data("previous bookmark".utf8)
        try await fixture.local.save(previous)
        let vm = fixture.makeViewModel()
        var denied = SecurityScopedDirectoryAccess.Operations()
        denied.startAccess = { _ in false }
        denied.validateDirectory = { _ in throw CocoaError(.fileReadNoPermission) }
        denied.resolveBookmark = { _, _ in throw CocoaError(.fileReadNoPermission) }
        vm.repositoryDirectoryAccess = SecurityScopedDirectoryAccess(operations: denied)

        await vm.loadWorkspace()
        XCTAssertTrue(vm.requiresWorkingDirectorySelection)
        XCTAssertNil(vm.sharedRepositoryURL)
        XCTAssertEqual(vm.workspace.activeWorkspaceName, "Beta")
        XCTAssertEqual(vm.workspace.sharedCollectionsDirectoryPath, fixture.workdir.path)
        XCTAssertEqual(vm.workspace.sharedCollectionsDirectoryBookmarkData, previous.sharedCollectionsDirectoryBookmarkData)
        XCTAssertEqual(vm.workspace.collections, previous.collections)
    }

    @MainActor
    func testMissingSavedDirectoryKeepsRecoverableWorkspaceData() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryPath = fixture.root.appendingPathComponent("missing-directory").path
        previous.sharedCollectionsDirectoryBookmarkData = Data("unresolvable".utf8)
        try await fixture.local.save(previous)

        let vm = fixture.makeViewModel()
        await vm.loadWorkspace()
        XCTAssertTrue(vm.requiresWorkingDirectorySelection)
        XCTAssertNil(vm.sharedRepositoryURL)
        XCTAssertEqual(vm.workspace.activeWorkspaceName, "Beta")
        XCTAssertEqual(vm.workspace.collections, previous.collections)
        XCTAssertEqual(vm.workspace.environments, previous.environments)
        let saved = try await fixture.local.load()
        XCTAssertEqual(saved.sharedCollectionsDirectoryPath, previous.sharedCollectionsDirectoryPath)
        XCTAssertEqual(saved.activeWorkspaceName, "Beta")
    }

    @MainActor
    func testRelativeSavedPathDoesNotSelectAnUnrelatedWorkingDirectory() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryPath = "."
        previous.sharedCollectionsDirectoryBookmarkData = nil
        try await fixture.local.save(previous)

        let vm = fixture.makeViewModel()
        await vm.loadWorkspace()
        XCTAssertTrue(vm.requiresWorkingDirectorySelection)
        XCTAssertNil(vm.sharedRepositoryURL)
        XCTAssertEqual(vm.workspace.activeWorkspaceName, "Beta")
        XCTAssertEqual(vm.workspace.collections, previous.collections)
    }

    @MainActor
    func testFileAtSavedDirectoryPathDoesNotCountAsAWorkspaceDirectory() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("not-a-directory")
        try Data("keep this file".utf8).write(to: file)
        var previous = fixture.selectedWorkspace
        previous.sharedCollectionsDirectoryPath = file.path
        previous.sharedCollectionsDirectoryBookmarkData = nil
        try await fixture.local.save(previous)

        let vm = fixture.makeViewModel()
        await vm.loadWorkspace()
        XCTAssertTrue(vm.requiresWorkingDirectorySelection)
        XCTAssertNil(vm.sharedRepositoryURL)
        XCTAssertEqual(vm.workspace.activeWorkspaceName, "Beta")
        XCTAssertEqual(try Data(contentsOf: file), Data("keep this file".utf8))
    }

    @MainActor
    private func assertRestored(_ vm: MainViewModel, fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(vm.didFinishInitialWorkspaceLoad, file: file, line: line)
        XCTAssertFalse(vm.requiresWorkingDirectorySelection, file: file, line: line)
        XCTAssertEqual(vm.sharedRepositoryURL?.standardizedFileURL, fixture.workdir.standardizedFileURL, file: file, line: line)
        XCTAssertEqual(vm.workspace.activeWorkspaceName, "Beta", file: file, line: line)
        XCTAssertEqual(vm.availableWorkspaceNames, ["Alpha", "Beta"], file: file, line: line)
        XCTAssertEqual(vm.workspace.collections.first?.info.name, "Beta Collection", file: file, line: line)
        XCTAssertEqual(vm.currentTab?.request.name, "Beta Request", file: file, line: line)
        XCTAssertEqual(vm.activeEnvironment?.name, "Beta Environment", file: file, line: line)
        XCTAssertNil(vm.errorMessage, file: file, line: line)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let workdir: URL
        let local: WorkspaceRepository
        let shared: SharedCollectionsRepository
        let selectedWorkspace: WorkspaceState

        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("efby-session-tests-\(UUID())", isDirectory: true)
                .resolvingSymlinksInPath()
            let workdir = root.appendingPathComponent("workdir", isDirectory: true)
            let local = WorkspaceRepository(storageURL: root.appendingPathComponent("workspace.json"))
            let shared = SharedCollectionsRepository()
            var selected: WorkspaceState?
            for name in ["Alpha", "Beta"] {
                let directory = workdir.appendingPathComponent(name, isDirectory: true)
                let environment = EnvironmentProfile(name: "\(name) Environment")
                let request = APIRequestModel(name: "\(name) Request", url: "https://example.invalid/\(name)")
                let collection = CollectionModel(info: CollectionInfoModel(name: "\(name) Collection"),
                    items: [CollectionNode(name: request.name, kind: .request, request: request)])
                let state = WorkspaceState(sharedCollectionsDirectoryPath: workdir.path, activeWorkspaceName: name,
                    collections: [collection], environments: [environment], activeEnvironmentID: environment.id)
                try await shared.saveCollections(state.collections, to: directory)
                try await shared.saveEnvironments(state.environments, to: directory)
                try await shared.saveWorkspaceSnapshot(state, to: directory)
                if name == "Beta" { selected = state }
            }
            return Fixture(root: root, workdir: workdir, local: local, shared: shared,
                           selectedWorkspace: try XCTUnwrap(selected))
        }

        func makeViewModel() -> MainViewModel {
            MainViewModel(dependencies: .live(workspaceRepository: local, sharedCollectionsRepository: shared), autoloadWorkspace: false)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
