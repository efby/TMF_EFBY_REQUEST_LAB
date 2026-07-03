import EfbyApplication
import Foundation

/// Scoped to a single `WorkspaceFlowExecutionService.execute` run so terminate / user cancel can
/// `URLSessionDataTask.cancel()` and `WebSocketConnection.disconnect()` on everything still in flight.
public final class WorkspaceFlowActiveRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var httpDataTasks: [URLSessionDataTask] = []
    private var webSocketConnections: [any WebSocketConnectionProtocol] = []

    public init() {}

    public func registerHTTPDataTask(_ task: URLSessionDataTask) {
        lock.lock()
        httpDataTasks.append(task)
        lock.unlock()
    }

    public func unregisterHTTPDataTask(_ task: URLSessionDataTask) {
        lock.lock()
        httpDataTasks.removeAll { $0 === task }
        lock.unlock()
    }

    public func registerWebSocket(_ connection: any WebSocketConnectionProtocol) {
        lock.lock()
        webSocketConnections.append(connection)
        lock.unlock()
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
