import Foundation

public struct WorkspaceFlowValidator: Sendable {
    public init() {}

    public func validate(
        flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        availableRequests: [WorkspaceFlowRequestReference]
    ) -> WorkspaceFlowValidationResult {
        var issues: [WorkspaceFlowValidationIssue] = []

        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let bindingsByElementID = Dictionary(uniqueKeysWithValues: flow.taskBindings.map { ($0.elementID, $0) })

        if graph.nodes.isEmpty {
            issues.append(.init(severity: .error, message: "The flow has no BPMN nodes."))
            return WorkspaceFlowValidationResult(issues: issues)
        }

        let supportedNodes = graph.nodes.filter { $0.nodeType != .unsupported }
        if supportedNodes.count != graph.nodes.count {
            for node in graph.nodes where node.nodeType == .unsupported {
                issues.append(.init(
                    severity: .error,
                    message: "Unsupported BPMN element '\(node.bpmnType)'. This MVP supports start, end, terminate end, task, timer event, exclusive gateway, and parallel gateway.",
                    elementID: node.id
                ))
            }
        }

        let startNodes = graph.nodes.filter { $0.nodeType == .startEvent }
        let endNodes = graph.nodes.filter { $0.nodeType == .endEvent || $0.nodeType == .terminateEndEvent }

        if startNodes.isEmpty {
            issues.append(.init(severity: .error, message: "The flow must include at least one start event."))
        }
        if endNodes.isEmpty {
            issues.append(.init(severity: .error, message: "The flow must include at least one end event."))
        }

        for startNode in startNodes {
            if !startNode.incomingIDs.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Start events must not have incoming connections.",
                    elementID: startNode.id
                ))
            }
            if startNode.outgoingIDs.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "Start events must connect to at least one next node.",
                    elementID: startNode.id
                ))
            }
        }

        for endNode in endNodes where !endNode.outgoingIDs.isEmpty {
            issues.append(.init(
                severity: .error,
                message: "End events must not have outgoing connections.",
                elementID: endNode.id
            ))
        }

        for node in graph.nodes where node.nodeType == .task {
            guard let binding = bindingsByElementID[node.id] else {
                issues.append(.init(
                    severity: .error,
                    message: "Every task node must be bound to an existing workspace request.",
                    elementID: node.id
                ))
                continue
            }

            guard binding.resolvedRequestID(matching: availableRequests) != nil else {
                let hasIdentity =
                    binding.requestID != nil
                    || (
                        (binding.boundCollectionName?.isEmpty == false)
                            && (binding.boundRequestName?.isEmpty == false)
                    )
                issues.append(.init(
                    severity: .error,
                    message: hasIdentity
                        ? "The bound request for this task no longer exists in the workspace."
                        : "Every task node must be bound to an existing workspace request.",
                    elementID: node.id
                ))
                continue
            }

            if node.incomingIDs.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "This task is unreachable because it has no incoming connection.",
                    elementID: node.id
                ))
            }

            if node.outgoingIDs.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "This task has no outgoing connection and will terminate the token at this point.",
                    elementID: node.id
                ))
            }
        }

        for node in graph.nodes where node.nodeType == .timerEvent {
            if WorkspaceFlowTimerParser.parseDelayMilliseconds(from: node) == nil {
                let timerValue = WorkspaceFlowTimerParser.displayExpression(for: node) ?? "empty"
                issues.append(.init(
                    severity: .error,
                    message: "Timer events require a valid delay. Use values like 2000ms, 5s, 1m, 2h, or PT5S. Current value: \(timerValue).",
                    elementID: node.id
                ))
            }

            if node.incomingIDs.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "This timer event is unreachable because it has no incoming connection.",
                    elementID: node.id
                ))
            }

            if node.outgoingIDs.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    message: "This timer event has no outgoing connection and will stop the token after waiting.",
                    elementID: node.id
                ))
            }
        }

        for node in graph.nodes where node.nodeType == .exclusiveGateway {
            if node.outgoingIDs.count < 2 {
                issues.append(.init(
                    severity: .warning,
                    message: "Decision gateways should usually have at least two outgoing paths.",
                    elementID: node.id
                ))
            }
        }

        for node in graph.nodes where node.nodeType == .parallelGateway {
            if node.outgoingIDs.count < 2 && node.incomingIDs.count < 2 {
                issues.append(.init(
                    severity: .warning,
                    message: "Parallel gateways should fork or join at least two connections.",
                    elementID: node.id
                ))
            }
        }

        for connection in graph.connections {
            guard nodesByID[connection.sourceID] != nil, nodesByID[connection.targetID] != nil else {
                issues.append(.init(
                    severity: .error,
                    message: "There is a connection pointing to a missing BPMN node.",
                    elementID: connection.id
                ))
                continue
            }
        }

        let reachableNodeIDs = reachableNodes(in: graph)
        for node in graph.nodes where !reachableNodeIDs.contains(node.id) {
            issues.append(.init(
                severity: .warning,
                message: "This node is unreachable from any start event.",
                elementID: node.id
            ))
        }

        if !endNodes.contains(where: { reachableNodeIDs.contains($0.id) }) {
            issues.append(.init(
                severity: .error,
                message: "No reachable path from a start event reaches an end event."
            ))
        }

        return WorkspaceFlowValidationResult(issues: deduplicate(issues))
    }

    private func reachableNodes(in graph: WorkspaceFlowGraphSnapshot) -> Set<String> {
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let startIDs = graph.nodes.filter { $0.nodeType == .startEvent }.map(\.id)
        var visited: Set<String> = []
        var queue = Array(startIDs)

        while let current = queue.first {
            queue.removeFirst()
            guard visited.insert(current).inserted, let node = nodesByID[current] else {
                continue
            }
            queue.append(contentsOf: node.outgoingIDs)
        }

        return visited
    }

    private func deduplicate(_ issues: [WorkspaceFlowValidationIssue]) -> [WorkspaceFlowValidationIssue] {
        var seen: Set<String> = []
        var unique: [WorkspaceFlowValidationIssue] = []

        for issue in issues {
            let key = "\(issue.severity.rawValue)|\(issue.elementID ?? "-")|\(issue.message)"
            if seen.insert(key).inserted {
                unique.append(issue)
            }
        }

        return unique
    }
}
