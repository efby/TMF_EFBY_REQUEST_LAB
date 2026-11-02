import Foundation
import Network

/// A loopback-only HTTP fixture. Slow responses remain gated until the test releases them.
final class TestHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "efby.ui-tests.http")
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var slowConnections: Set<UUID> = []
    private var receivedRequests: [String: Int] = [:]
    private var disconnectedSlowRequests = 0
    private var listenerIsReady = false
    private var listenerFailureDescription: String?

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    var cancelledSlowRequestCount: Int {
        queue.sync { disconnectedSlowRequests }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                listenerIsReady = true
                ready.signal()
            case .failed(let error):
                listenerFailureDescription = error.localizedDescription
                ready.signal()
            case .cancelled:
                listenerFailureDescription = "The listener was cancelled before becoming ready."
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        let signalled = ready.wait(timeout: .now() + 5) == .success
        let (isReady, failure) = queue.sync {
            (listenerIsReady && (listener.port?.rawValue ?? 0) > 0, listenerFailureDescription)
        }
        guard signalled, isReady else {
            listener.cancel()
            throw NSError(domain: "TestHTTPServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: failure ?? "The local HTTP fixture did not become ready within five seconds."
            ])
        }
    }

    func requestCount(for path: String) -> Int {
        queue.sync { receivedRequests[path, default: 0] }
    }

    func releaseSlowResponses() {
        queue.sync {
            for id in slowConnections {
                respond(to: id, message: "ui-late-response")
            }
            slowConnections.removeAll()
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
            slowConnections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        readRequest(on: connection, id: id, accumulated: Data())
    }

    private func readRequest(on connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let target = text.split(separator: "\r\n", maxSplits: 1).first?
                    .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
                receivedRequests[path, default: 0] += 1
                if path == "/slow" {
                    slowConnections.insert(id)
                    monitorSlowRequestDisconnect(on: connection, id: id)
                } else {
                    respond(to: id, message: path == "/beta" ? "ui-beta" : "ui-success")
                }
            } else if complete || error != nil || request.count > 65_536 {
                removeConnection(id)
            } else {
                readRequest(on: connection, id: id, accumulated: request)
            }
        }
    }

    private func monitorSlowRequestDisconnect(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] _, _, complete, error in
            guard let self, slowConnections.contains(id) else { return }
            if complete || error != nil {
                disconnectedSlowRequests += 1
                removeConnection(id)
            } else {
                monitorSlowRequestDisconnect(on: connection, id: id)
            }
        }
    }

    private func respond(to id: UUID, message: String) {
        guard let connection = connections[id] else { return }
        let body = "{\"message\":\"\(message)\"}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.removeConnection(id)
        })
    }

    private func removeConnection(_ id: UUID) {
        slowConnections.remove(id)
        connections.removeValue(forKey: id)?.cancel()
    }
}
