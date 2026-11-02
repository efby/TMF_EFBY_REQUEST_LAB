@testable import EfbyPresentation
import Foundation
import XCTest

@MainActor
final class AutosaveQueueTests: XCTestCase {
    func testOneHundredEditsCoalesceIntoOneLatestWriteOnFlush() async throws {
        var writes: [WorkspacePersistencePayload] = []
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            writes.append(payload)
            return self.receipt(payload, root)
        }
        for index in 0..<100 {
            queue.enqueue(snapshot: snapshot("edit-\(index)"), workspaceRoot: nil, options: .localOnly)
        }
        XCTAssertTrue(writes.isEmpty)

        try await boundedFlush(queue, rescue: snapshot("edit-99"))

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(marker(writes.last?.localSnapshot), "edit-99")
    }

    func testLocalOnlyEditDoesNotReplacePreviouslyAuthorizedSharedEnvironment() async throws {
        let authorized = snapshot("E1")
        let local = snapshot("E2")
        let root = URL(fileURLWithPath: "/tmp/efby-autosave-authorized")
        var writes: [WorkspacePersistencePayload] = []
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            writes.append(payload)
            return self.receipt(payload, root)
        }
        queue.enqueue(snapshot: authorized, workspaceRoot: root, options: environmentOnly)
        queue.enqueue(snapshot: local, workspaceRoot: root, options: .localOnly)

        try await boundedFlush(queue, rescue: local, root: root)

        let payload = try XCTUnwrap(writes.last)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(marker(payload.localSnapshot), "E2")
        XCTAssertEqual(payload.localSnapshot.environments, local.environments)
        XCTAssertEqual(payload.environments, authorized.environments)
        XCTAssertEqual(payload.sharedMetadata?.globalVariables, authorized.globalVariables)
        XCTAssertEqual(payload.options, environmentOnly)
        XCTAssertNil(payload.collections)
    }

    func testReverseOrderAndDifferentAreasKeepLatestAuthorizedValuePerArea() async throws {
        let local = snapshot("local")
        let environment = snapshot("environment")
        let collection = snapshot("collection")
        let root = URL(fileURLWithPath: "/tmp/efby-autosave-union")
        var writes: [WorkspacePersistencePayload] = []
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            writes.append(payload)
            return self.receipt(payload, root)
        }
        queue.enqueue(snapshot: local, workspaceRoot: root, options: .localOnly)
        queue.enqueue(snapshot: environment, workspaceRoot: root, options: environmentOnly)
        queue.enqueue(snapshot: collection, workspaceRoot: root, options: collectionOnly)

        try await boundedFlush(queue, rescue: collection, root: root)

        let payload = try XCTUnwrap(writes.last)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(marker(payload.localSnapshot), "collection")
        XCTAssertEqual(payload.environments, environment.environments)
        XCTAssertEqual(payload.collections, collection.collections)
        XCTAssertTrue(payload.options.syncSharedCollections)
        XCTAssertTrue(payload.options.syncSharedEnvironments)
        XCTAssertFalse(payload.options.syncSharedFlows)
        XCTAssertFalse(payload.options.syncSharedUtilities)
    }

    func testDifferentDestinationsRemainSeparateAndNewestLocalSnapshotIsWrittenLast() async throws {
        let firstRoot = URL(fileURLWithPath: "/tmp/efby-autosave-A")
        let secondRoot = URL(fileURLWithPath: "/tmp/efby-autosave-B")
        let first = snapshot("A1", workspace: "A")
        let second = snapshot("B1", workspace: "B")
        let latest = snapshot("A2", workspace: "A")
        var writes: [(WorkspacePersistencePayload, URL?)] = []
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            writes.append((payload, root))
            return self.receipt(payload, root)
        }
        queue.enqueue(snapshot: first, workspaceRoot: firstRoot, options: environmentOnly)
        queue.enqueue(snapshot: second, workspaceRoot: secondRoot, options: collectionOnly)
        queue.enqueue(snapshot: latest, workspaceRoot: firstRoot, options: .localOnly)

        try await boundedFlush(queue, rescue: latest, root: firstRoot)

        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map { marker($0.0.localSnapshot) }, ["B1", "A2"])
        XCTAssertEqual(writes.map { $0.1 }, [secondRoot, firstRoot])
        XCTAssertEqual(writes.first?.0.collections, second.collections)
        XCTAssertNil(writes.first?.0.environments)
        XCTAssertEqual(writes.last?.0.environments, first.environments)
        XCTAssertNil(writes.last?.0.collections)
    }

    func testSuspendedWriterSerializesLaterEditsAndKeepsNewestPendingValue() async throws {
        let probe = AutosaveWriterProbe()
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            try await probe.write(payload, root: root)
        }
        let first = snapshot("first")
        let latest = snapshot("latest")
        queue.enqueue(snapshot: first, workspaceRoot: nil, options: .localOnly, immediately: true)
        let started = await waitUntil { probe.isPaused }
        guard started else { probe.release(); return XCTFail("First writer did not start") }
        queue.enqueue(snapshot: snapshot("intermediate"), workspaceRoot: nil, options: .localOnly)
        queue.enqueue(snapshot: latest, workspaceRoot: nil, options: .localOnly)
        XCTAssertEqual(probe.writes.count, 1)
        probe.release()

        try await boundedFlush(queue, rescue: latest)

        XCTAssertEqual(probe.maximumConcurrentWriters, 1)
        XCTAssertEqual(probe.writes.map { marker($0.localSnapshot) }, ["first", "latest"])
    }

    func testFailureRetainsAuthorizedPayloadForDeliberateRetryWithNewLocalEdit() async throws {
        let root = URL(fileURLWithPath: "/tmp/efby-autosave-retry")
        let authorized = snapshot("authorized")
        let latest = snapshot("latest-local")
        var shouldFail = true
        var writes: [WorkspacePersistencePayload] = []
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            writes.append(payload)
            if shouldFail { throw AutosaveTestError.expectedFailure }
            return self.receipt(payload, root)
        }
        queue.enqueue(snapshot: authorized, workspaceRoot: root, options: environmentOnly)
        do {
            try await boundedFlush(queue, rescue: authorized, root: root)
            XCTFail("Expected write failure")
        } catch AutosaveTestError.expectedFailure { }
        XCTAssertEqual(writes.count, 1)
        shouldFail = false
        queue.enqueue(snapshot: latest, workspaceRoot: root, options: .localOnly)

        try await boundedFlush(queue, rescue: latest, root: root)

        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.environments, authorized.environments)
        XCTAssertEqual(marker(writes.last?.localSnapshot), "latest-local")
        XCTAssertEqual(writes.last?.options, environmentOnly)
    }

    func testConcurrentFlushesIncludeEditEnqueuedByCompletionTaskWithoutDebounceSpin() async throws {
        let firstSnapshot = snapshot("first")
        let nextSnapshot = snapshot("next")
        var writes: [WorkspacePersistencePayload] = []
        var finished = 0
        var failures = 0
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60)) { payload, root in
            writes.append(payload)
            return self.receipt(payload, root)
        }
        queue.enqueue(snapshot: firstSnapshot, workspaceRoot: nil, options: .localOnly) { _ in
            Task { queue.enqueue(snapshot: nextSnapshot, workspaceRoot: nil, options: .localOnly) }
        }
        let first = Task { do { try await queue.flush() } catch { failures += 1 }; finished += 1 }
        let second = Task { do { try await queue.flush() } catch { failures += 1 }; finished += 1 }
        let completed = await waitUntil { finished == 2 && writes.count == 2 }
        if !completed {
            // Rescue a regressed queue instead of leaving an uncooperative flush running for 60s.
            queue.enqueue(snapshot: nextSnapshot, workspaceRoot: nil, options: .localOnly, immediately: true)
            _ = await waitUntil { finished == 2 }
        }
        XCTAssertTrue(completed, "Concurrent flushes waited for debounce or left the callback's edit pending")
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(writes.map { marker($0.localSnapshot) }, ["first", "next"])
        first.cancel()
        second.cancel()
    }

    func testContinuousTypingCannotPostponeFirstWriteIndefinitely() async throws {
        var writes: [WorkspacePersistencePayload] = []
        let queue = WorkspaceAutosaveQueue(debounce: .seconds(60), maximumDelay: .milliseconds(40)) { payload, root in
            writes.append(payload)
            return self.receipt(payload, root)
        }
        let producer = Task {
            var index = 0
            while !Task.isCancelled {
                queue.enqueue(snapshot: self.snapshot("edit-\(index)"), workspaceRoot: nil, options: .localOnly)
                index += 1
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
        let wroteDuringTyping = await waitUntil { !writes.isEmpty }
        producer.cancel()
        await producer.value
        XCTAssertTrue(wroteDuringTyping, "Continuous edits suppressed autosave beyond the maximum delay")
        try await boundedFlush(queue, rescue: snapshot("final"))
    }

    private var environmentOnly: WorkspacePersistenceOptions {
        WorkspacePersistenceOptions(syncSharedCollections: false, syncSharedEnvironments: true,
            syncSharedFlows: false, syncSharedUtilities: false)
    }

    private var collectionOnly: WorkspacePersistenceOptions {
        WorkspacePersistenceOptions(syncSharedCollections: true, syncSharedEnvironments: false,
            syncSharedFlows: false, syncSharedUtilities: false)
    }

    private func snapshot(_ marker: String, workspace: String = "default") -> WorkspaceState {
        WorkspaceState(activeWorkspaceName: workspace, globalVariables: [VariableValue(key: "marker", value: marker)],
            collections: [CollectionModel(info: CollectionInfoModel(name: marker))],
            environments: [EnvironmentProfile(name: "QA", variables: [VariableValue(key: "value", value: marker)])])
    }

    private func marker(_ snapshot: WorkspaceState?) -> String? {
        snapshot?.globalVariables.first(where: { $0.key == "marker" })?.value
    }

    private func receipt(_ payload: WorkspacePersistencePayload, _ root: URL?) -> WorkspacePersistenceReceipt {
        WorkspacePersistenceReceipt(localSnapshot: payload.localSnapshot, sharedSnapshot: nil,
            options: payload.options, workspaceRoot: root)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func boundedFlush(_ queue: WorkspaceAutosaveQueue, rescue: WorkspaceState, root: URL? = nil) async throws {
        var outcome: Result<Void, any Error>?
        let task = Task {
            do { try await queue.flush(); outcome = .success(()) }
            catch { outcome = .failure(error) }
        }
        let completed = await waitUntil { outcome != nil }
        if !completed {
            queue.enqueue(snapshot: rescue, workspaceRoot: root, options: .localOnly, immediately: true)
            _ = await waitUntil { outcome != nil }
            XCTFail("Flush did not complete promptly")
        }
        task.cancel()
        guard let outcome else { throw AutosaveTestError.flushDidNotFinish }
        try outcome.get()
    }
}

private enum AutosaveTestError: Error { case expectedFailure, flushDidNotFinish }

@MainActor
private final class AutosaveWriterProbe {
    var writes: [WorkspacePersistencePayload] = []
    var maximumConcurrentWriters = 0
    private var concurrentWriters = 0
    private var pause: CheckedContinuation<Void, Never>?
    private var released = false
    var isPaused: Bool { pause != nil }

    func write(_ payload: WorkspacePersistencePayload, root: URL?) async throws -> WorkspacePersistenceReceipt {
        concurrentWriters += 1
        maximumConcurrentWriters = max(maximumConcurrentWriters, concurrentWriters)
        writes.append(payload)
        if writes.count == 1, !released {
            await withCheckedContinuation { pause = $0 }
        }
        concurrentWriters -= 1
        return WorkspacePersistenceReceipt(localSnapshot: payload.localSnapshot, sharedSnapshot: nil,
            options: payload.options, workspaceRoot: root)
    }

    func release() {
        released = true
        pause?.resume()
        pause = nil
    }
}
