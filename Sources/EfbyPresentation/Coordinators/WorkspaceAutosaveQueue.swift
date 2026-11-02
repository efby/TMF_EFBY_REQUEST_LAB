import EfbyApplication
import EfbyDomain
import Foundation

/// One pending value per destination, with a single writer and an explicit flush barrier.
@MainActor
final class WorkspaceAutosaveQueue {
    typealias Writer = @MainActor (WorkspacePersistencePayload, URL?) async throws -> WorkspacePersistenceReceipt
    typealias Completion = @MainActor (Result<WorkspacePersistenceReceipt, any Error>) -> Void

    private struct Destination: Hashable {
        let root: String?
        let workspace: String?
    }
    private struct Pending {
        var payload: WorkspacePersistencePayload
        let root: URL?
        var completion: Completion?
    }

    private let debounce: Duration
    private let maximumDelay: Duration
    private let writer: Writer
    private var pending: [Destination: Pending] = [:]
    private var order: [Destination] = []
    private var timer: Task<Void, Never>?
    private var worker: Task<Void, any Error>?
    private var deadline = ContinuousClock.now
    private var forceDrain = false
    private var activeFlushes = 0
    private var firstPendingChange: ContinuousClock.Instant?

    init(debounce: Duration = .milliseconds(250), maximumDelay: Duration = .seconds(2), writer: @escaping Writer) {
        self.debounce = debounce
        self.maximumDelay = maximumDelay
        self.writer = writer
    }

    func enqueue(snapshot: WorkspaceState, workspaceRoot: URL?, options: WorkspacePersistenceOptions,
                 immediately: Bool = false, completion: Completion? = nil) {
        let key = Destination(root: workspaceRoot?.standardizedFileURL.path, workspace: snapshot.activeWorkspaceName)
        let now = ContinuousClock.now
        if pending.isEmpty || firstPendingChange == nil { firstPendingChange = now }
        let payload = WorkspacePersistencePayload(snapshot: snapshot, options: options)
        if var previous = pending[key] {
            previous.payload.merge(payload)
            previous.completion = completion ?? previous.completion
            pending[key] = previous
        } else {
            pending[key] = Pending(payload: payload, root: workspaceRoot, completion: completion)
        }
        // The last destination edited must also be the last local snapshot written.
        order.removeAll { $0 == key }
        order.append(key)
        deadline = min(now.advanced(by: debounce), (firstPendingChange ?? now).advanced(by: maximumDelay))
        if immediately { forceDrain = true }
        guard worker == nil else { return }
        if forceDrain { startWorker() } else { schedule() }
    }

    func flush() async throws {
        activeFlushes += 1
        defer {
            activeFlushes -= 1
            if activeFlushes == 0 { forceDrain = false }
        }
        timer?.cancel()
        timer = nil
        forceDrain = true
        while !pending.isEmpty || worker != nil {
            forceDrain = true
            if worker == nil { startWorker() }
            if let running = worker { try await running.value }
        }
    }

    private func schedule() {
        timer?.cancel()
        let due = deadline
        timer = Task { [weak self] in
            do { try await Task.sleep(until: due, clock: .continuous) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.timer = nil
            self.startWorker()
        }
    }

    private func startWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        timer?.cancel()
        timer = nil
        worker = Task { [weak self] in
            guard let self else { return }
            try await self.drain()
        }
    }

    private func drain() async throws {
        while let key = order.first {
            if !forceDrain, activeFlushes == 0, ContinuousClock.now < deadline { break }
            order.removeFirst()
            guard let entry = pending.removeValue(forKey: key) else { continue }
            if pending.isEmpty { firstPendingChange = nil }
            do {
                let receipt = try await writer(entry.payload, entry.root)
                entry.completion?(.success(receipt))
            } catch {
                if let newer = pending[key] {
                    var retry = entry
                    retry.payload.merge(newer.payload)
                    retry.completion = newer.completion ?? retry.completion
                    pending[key] = retry
                } else {
                    pending[key] = entry
                    order.insert(key, at: 0)
                }
                entry.completion?(.failure(error))
                firstPendingChange = nil
                deadline = .now.advanced(by: debounce)
                forceDrain = activeFlushes > 0
                worker = nil
                // Keep the failed value for a deliberate retry, without a failure loop.
                throw error
            }
        }
        worker = nil
        forceDrain = activeFlushes > 0
        if !pending.isEmpty, activeFlushes == 0 { schedule() }
    }
}
