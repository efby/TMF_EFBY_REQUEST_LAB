import EfbyApplication
import Foundation

/// Scoped to a single `WorkspaceFlowExecutionService.execute` run so terminate / user cancel can
/// `URLSessionDataTask.cancel()` and `WebSocketConnection.disconnect()` on everything still in flight.
public final class WorkspaceFlowActiveRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var httpDataTasks: [URLSessionDataTask] = []
    private var webSocketConnections: [any WebSocketConnectionProtocol] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func registerHTTPDataTask(_ task: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { httpDataTasks.append(task) }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    public func unregisterHTTPDataTask(_ task: URLSessionDataTask) {
        lock.lock()
        httpDataTasks.removeAll { $0 === task }
        lock.unlock()
    }

    public func registerWebSocket(_ connection: any WebSocketConnectionProtocol) {
        lock.lock()
        let shouldDisconnect = cancelled
        if !shouldDisconnect { webSocketConnections.append(connection) }
        lock.unlock()
        if shouldDisconnect { Task { await connection.disconnect() } }
    }

    public func unregisterWebSocket(_ connection: any WebSocketConnectionProtocol) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        webSocketConnections.removeAll { ObjectIdentifier($0) == identifier }
        lock.unlock()
    }

    /// Cancels all registered HTTP data tasks. Safe from `withTaskCancellationHandler.onCancel` (synchronous).
    public func cancelAllHTTPDataTasks() {
        lock.lock()
        cancelled = true
        let tasks = httpDataTasks
        httpDataTasks.removeAll()
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    public func disconnectAllRegisteredWebSockets() async {
        let sockets = takeAndClearWebSockets()
        for connection in sockets {
            await connection.disconnect()
        }
    }

    private func takeAndClearWebSockets() -> [any WebSocketConnectionProtocol] {
        lock.lock()
        let sockets = webSocketConnections
        webSocketConnections.removeAll()
        lock.unlock()
        return sockets
    }

    public func cancelHTTPTasksAndDisconnectWebSockets() async {
        cancelAllHTTPDataTasks()
        await disconnectAllRegisteredWebSockets()
    }
}

public enum WorkspaceFlowExecutionCancellationScope {
    @TaskLocal public static var activeRequestRegistry: WorkspaceFlowActiveRequestRegistry?
}
