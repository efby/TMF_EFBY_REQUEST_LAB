import EfbyPresentation
import Foundation
import XCTest

/// Repeatable local workloads. Durations are observations, not timing assertions on a shared runner.
final class PerformanceMeasurementTests: XCTestCase {
    private actor MeasuredLocalRepository: WorkspaceRepositoryProtocol {
        var state: WorkspaceState
        let url: URL
        var writes = 0
        var bytes = 0
        init(state: WorkspaceState, url: URL) { self.state = state; self.url = url }
        func load() throws -> WorkspaceState { state }
        func save(_ state: WorkspaceState) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
            self.state = state
            writes += 1
            bytes += data.count
        }
        func resetCounters() { writes = 0; bytes = 0 }
        func counters() -> (Int, Int) { (writes, bytes) }
    }

    private final class FileOperations: @unchecked Sendable {
        private let lock = NSLock()
        private var moves = 0
        private var copies = 0
        func moved() { lock.lock(); moves += 1; lock.unlock() }
        func copied() { lock.lock(); copies += 1; lock.unlock() }
        func reset() { lock.lock(); defer { lock.unlock() }; moves = 0; copies = 0 }
        var counters: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (moves, copies) }
    }
    private final class MeasuredFileManager: FileManager, @unchecked Sendable {
        let operations: FileOperations
        init(operations: FileOperations) { self.operations = operations; super.init() }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            try super.moveItem(at: srcURL, to: dstURL)
            operations.moved()
        }
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            try super.copyItem(at: srcURL, to: dstURL)
            operations.copied()
        }
    }

    @MainActor
    func testMeasureFiftyEditsAndFlushOnFiftyCollections() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = dataset()
        let repository = MeasuredLocalRepository(state: state, url: directory.appendingPathComponent("workspace.json"))
        let viewModel = MainViewModel(dependencies: .live(workspaceRepository: repository), autoloadWorkspace: false)
        viewModel.workspace = state
        await viewModel.open(request: state.collections[0].items[0], in: state.collections[0])
        await viewModel.flushStateForApplicationTermination()
        await repository.resetCounters()
        let tab = try XCTUnwrap(viewModel.currentTab)
        let start = ContinuousClock.now
        for index in 0..<50 {
            tab.request.url = "https://example.invalid/edited/\(index)"
            viewModel.persistPendingChanges(for: tab)
        }
        let enqueueSeconds = seconds(start.duration(to: .now))
        await viewModel.flushStateForApplicationTermination()
        let totalSeconds = seconds(start.duration(to: .now))
        let saved = try await repository.load()
        XCTAssertEqual(saved.collections[0].items[0].request?.url, "https://example.invalid/edited/49")
        XCTAssertNil(viewModel.errorMessage)
        let (writes, bytes) = await repository.counters()
        XCTAssertEqual(writes, 1, "A synchronous edit burst and flush must persist only its latest state")
        print("EFBY_PERF autosave edits=50 collections=50 requests=500 writes=\(writes) bytes=\(bytes) enqueue_s=\(enqueueSeconds) flush_total_s=\(totalSeconds)")
    }

    func testMeasureTwentyIdenticalCollectionSaves() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let operations = FileOperations()
        let repository = SharedCollectionsRepository(fileManager: MeasuredFileManager(operations: operations))
        let collections = dataset().collections
        try await repository.saveCollections(collections, to: directory)
        operations.reset()
        let start = ContinuousClock.now
        for _ in 0..<20 { try await repository.saveCollections(collections, to: directory) }
        let elapsed = seconds(start.duration(to: .now))
        let loaded = try await repository.loadCollections(from: directory)
        XCTAssertEqual(loaded.count, 50)
        let (moves, copies) = operations.counters
        XCTAssertEqual(moves, 0, "Identical saves must not swap a managed directory")
        XCTAssertEqual(copies, 0, "Identical saves must not create a staging copy")
        print("EFBY_PERF repository identical_saves=20 collections=50 moves=\(moves) copies=\(copies) elapsed_s=\(elapsed)")
    }

    @MainActor
    func testMeasureFiftyEditsWithSharedWorkspaceAndFlush() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = dataset()
        state.sharedCollectionsDirectoryPath = directory.path
        let sharedRoot = directory.appendingPathComponent("default", isDirectory: true)
        let operations = FileOperations()
        let shared = SharedCollectionsRepository(fileManager: MeasuredFileManager(operations: operations))
        try await shared.saveCollections(state.collections, to: sharedRoot)
        try await shared.saveWorkspaceSnapshot(state, to: sharedRoot)
        let repository = MeasuredLocalRepository(state: state, url: directory.appendingPathComponent("workspace.json"))
        let viewModel = MainViewModel(dependencies: .live(workspaceRepository: repository, sharedCollectionsRepository: shared), autoloadWorkspace: false)
        viewModel.workspace = state
        await viewModel.open(request: state.collections[0].items[0], in: state.collections[0])
        await viewModel.flushStateForApplicationTermination()
        await repository.resetCounters()
        operations.reset()
        let tab = try XCTUnwrap(viewModel.currentTab)
        let start = ContinuousClock.now
        for index in 0..<50 {
            tab.request.url = "https://example.invalid/shared-edited/\(index)"
            viewModel.persistPendingChanges(for: tab)
        }
        let saved = await viewModel.flushStateForApplicationTermination()
        XCTAssertTrue(saved)
        let elapsed = seconds(start.duration(to: .now))
        let local = try await repository.load()
        let collections = try await shared.loadCollections(from: sharedRoot)
        let first = try XCTUnwrap(collections.first(where: { $0.info.name == state.collections[0].info.name }))
        XCTAssertEqual(first.items[0].request?.url, "https://example.invalid/shared-edited/49")
        XCTAssertEqual(local.collections[0].items[0].request?.url, "https://example.invalid/shared-edited/49")
        let (writes, bytes) = await repository.counters()
        let (moves, copies) = operations.counters
        XCTAssertLessThanOrEqual(writes, 2, "Coalescing must retain recovery and confirmation without saving each edit")
        XCTAssertEqual(moves, 2, "Only the changed collections directory needs one recoverable swap")
        XCTAssertEqual(copies, 1)
        print("EFBY_PERF autosave_shared edits=50 collections=50 requests=500 local_writes=\(writes) local_bytes=\(bytes) moves=\(moves) copies=\(copies) flush_total_s=\(elapsed)")
    }

    func testMeasureTwentySequentialHTTPRequests() async throws {
        MeasuredURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeasuredURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = RequestExecutionService(session: session)
        let start = ContinuousClock.now
        for index in 0..<20 {
            let outcome = try await service.execute(request: APIRequestModel(name: "Measured", url: "https://example.invalid/\(index)"),
                globals: [], collectionVariables: [], environmentVariables: [])
            XCTAssertEqual(outcome.response.statusCode, 200)
        }
        let identifiers = MeasuredURLProtocol.identifiers
        XCTAssertEqual(identifiers.count, 20)
        XCTAssertFalse(identifiers.contains(0), "URLProtocol must expose its native task for this measurement")
        print("EFBY_PERF http requests=20 first_task_ids=\(identifiers.filter { $0 == 1 }.count) distinct_task_ids=\(Set(identifiers).count) elapsed_s=\(seconds(start.duration(to: .now)))")
    }

    private func dataset() -> WorkspaceState {
        let collections = (0..<50).map { collection in
            CollectionModel(info: CollectionInfoModel(name: "Collection \(collection)"), items: (0..<10).map { request in
                CollectionNode(name: "Request \(request)", kind: .request,
                    request: APIRequestModel(name: "Request \(request)", method: .post,
                        url: "https://example.invalid/\(collection)/\(request)",
                        body: RequestBodyModel(kind: .raw, raw: String(repeating: "x", count: 1024))))
            })
        }
        return WorkspaceState(activeWorkspaceName: "default", collections: collections)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EFBYPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private final class MeasuredURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable { let lock = NSLock(); var ids: [Int] = [] }
    private static let state = State()
    static func reset() { state.lock.lock(); defer { state.lock.unlock() }; state.ids = [] }
    static var identifiers: [Int] { state.lock.lock(); defer { state.lock.unlock() }; return state.ids }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock(); Self.state.ids.append(task?.taskIdentifier ?? 0); Self.state.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
