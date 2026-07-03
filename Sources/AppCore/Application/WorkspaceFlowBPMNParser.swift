import Foundation

public struct WorkspaceFlowBPMNParser: Sendable {
    public init() {}

    public func parse(xml: String) throws -> WorkspaceFlowGraphSnapshot {
        let data = Data(xml.utf8)
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "Unable to parse BPMN XML."
            throw AppError.invalidDocument(message)
        }

        return delegate.snapshot()
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private struct NodeBuilder {
        var id: String
        var name: String
        var bpmnType: String
        var nodeType: WorkspaceFlowNodeType
        var timerDefinition: String?
        var incomingIDs: [String]
        var outgoingIDs: [String]
        var hasTimerDefinition: Bool
        var hasTerminateDefinition: Bool
    }

    private struct ConnectionBuilder {
        var id: String
        var sourceID: String
        var targetID: String
        var name: String
    }

    private var nodesByID: [String: NodeBuilder] = [:]
    private var nodeOrder: [String] = []
    private var connections: [ConnectionBuilder] = []
    private var defaultFlowIDs: Set<String> = []
    private var currentNodeID: String?
    private var currentText = ""
    private var currentTimerExpressionElement: String?

    func snapshot() -> WorkspaceFlowGraphSnapshot {
        let snapshotConnections = connections.map { connection in
            WorkspaceFlowGraphConnection(
                id: connection.id,
                sourceID: connection.sourceID,
                targetID: connection.targetID,
                name: connection.name,
                isDefault: defaultFlowIDs.contains(connection.id)
            )
        }

        let nodes = nodeOrder.compactMap { nodeID -> WorkspaceFlowGraphNode? in
            guard let builder = nodesByID[nodeID] else {
                return nil
            }

            let resolvedNodeType: WorkspaceFlowNodeType
            if builder.bpmnType == "bpmn:IntermediateCatchEvent" {
                resolvedNodeType = builder.hasTimerDefinition || !(builder.timerDefinition ?? "").isEmpty
                    ? .timerEvent
                    : .unsupported
            } else if builder.bpmnType == "bpmn:EndEvent", builder.hasTerminateDefinition {
                resolvedNodeType = .terminateEndEvent
            } else {
                resolvedNodeType = builder.nodeType
            }

            return WorkspaceFlowGraphNode(
                id: builder.id,
                name: builder.name,
                bpmnType: builder.bpmnType,
                nodeType: resolvedNodeType,
                timerDefinition: builder.timerDefinition,
                incomingIDs: snapshotConnections
                    .filter { $0.targetID == builder.id }
                    .map(\.sourceID),
                outgoingIDs: snapshotConnections
                    .filter { $0.sourceID == builder.id }
                    .map(\.targetID)
            )
        }

        return WorkspaceFlowGraphSnapshot(nodes: nodes, connections: snapshotConnections)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = Self.localName(from: elementName)

        if let defaultFlowID = attributeDict["default"], !defaultFlowID.isEmpty {
            defaultFlowIDs.insert(defaultFlowID)
        }

        if let nodeBuilder = makeNodeBuilder(for: localName, attributes: attributeDict) {
            nodesByID[nodeBuilder.id] = nodeBuilder
            nodeOrder.append(nodeBuilder.id)
            currentNodeID = nodeBuilder.id
        } else if localName == "sequenceFlow",
                  let id = attributeDict["id"],
                  let sourceID = attributeDict["sourceRef"],
                  let targetID = attributeDict["targetRef"] {
            connections.append(
                ConnectionBuilder(
                    id: id,
                    sourceID: sourceID,
                    targetID: targetID,
                    name: attributeDict["name"] ?? ""
                )
            )
        } else if localName == "timerEventDefinition" {
            guard let currentNodeID,
                  var builder = nodesByID[currentNodeID] else {
                return
            }
            builder.hasTimerDefinition = true
            nodesByID[currentNodeID] = builder
        } else if localName == "terminateEventDefinition" {
            guard let currentNodeID,
                  var builder = nodesByID[currentNodeID] else {
                return
            }
            builder.hasTerminateDefinition = true
            nodesByID[currentNodeID] = builder
        }

        if Set(["incoming", "outgoing", "timeDuration", "timeDate", "timeCycle"]).contains(localName) {
            currentText = ""
        }

        if Set(["timeDuration", "timeDate", "timeCycle"]).contains(localName) {
            currentTimerExpressionElement = localName
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = Self.localName(from: elementName)
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let currentNodeID,
           var builder = nodesByID[currentNodeID] {
            switch localName {
            case "incoming":
                if !trimmedText.isEmpty {
                    builder.incomingIDs.append(trimmedText)
                }
            case "outgoing":
                if !trimmedText.isEmpty {
                    builder.outgoingIDs.append(trimmedText)
                }
            case "timeDuration", "timeDate", "timeCycle":
                if !trimmedText.isEmpty {
                    builder.timerDefinition = trimmedText
                }
            default:
                break
            }
            nodesByID[currentNodeID] = builder
        }

        if Set(["timeDuration", "timeDate", "timeCycle"]).contains(localName) {
            currentTimerExpressionElement = nil
        }

        if let currentNodeID,
           let builder = nodesByID[currentNodeID],
           Self.localName(from: builder.bpmnType).caseInsensitiveCompare(localName) == .orderedSame {
            self.currentNodeID = nil
        }

        if Set(["incoming", "outgoing", "timeDuration", "timeDate", "timeCycle"]).contains(localName) {
            currentText = ""
        }
    }

    private func makeNodeBuilder(for localName: String, attributes: [String: String]) -> NodeBuilder? {
        guard let id = attributes["id"], !id.isEmpty else {
            return nil
        }

        let name = attributes["name"] ?? ""

        switch localName {
        case "startEvent":
            return NodeBuilder(
                id: id,
                name: name,
                bpmnType: "bpmn:StartEvent",
                nodeType: .startEvent,
                timerDefinition: nil,
                incomingIDs: [],
                outgoingIDs: [],
                hasTimerDefinition: false,
                hasTerminateDefinition: false
            )
        case "endEvent":
            return NodeBuilder(
                id: id,
                name: name,
                bpmnType: "bpmn:EndEvent",
                nodeType: .endEvent,
                timerDefinition: nil,
                incomingIDs: [],
                outgoingIDs: [],
                hasTimerDefinition: false,
                hasTerminateDefinition: false
            )
        case "exclusiveGateway":
            return NodeBuilder(
                id: id,
                name: name,
                bpmnType: "bpmn:ExclusiveGateway",
                nodeType: .exclusiveGateway,
                timerDefinition: nil,
                incomingIDs: [],
                outgoingIDs: [],
                hasTimerDefinition: false,
                hasTerminateDefinition: false
            )
        case "parallelGateway":
            return NodeBuilder(
                id: id,
                name: name,
                bpmnType: "bpmn:ParallelGateway",
                nodeType: .parallelGateway,
                timerDefinition: nil,
                incomingIDs: [],
                outgoingIDs: [],
                hasTimerDefinition: false,
                hasTerminateDefinition: false
            )
        case "intermediateCatchEvent":
            return NodeBuilder(
                id: id,
                name: name,
                bpmnType: "bpmn:IntermediateCatchEvent",
                nodeType: .unsupported,
                timerDefinition: nil,
                incomingIDs: [],
                outgoingIDs: [],
                hasTimerDefinition: false,
                hasTerminateDefinition: false
            )
        default:
            if localName.hasSuffix("Task") || localName == "task" || localName == "callActivity" {
                return NodeBuilder(
                    id: id,
                    name: name,
                    bpmnType: Self.bpmnTypeName(for: localName),
                    nodeType: .task,
                    timerDefinition: nil,
                    incomingIDs: [],
                    outgoingIDs: [],
                    hasTimerDefinition: false,
                    hasTerminateDefinition: false
                )
            }
            return nil
        }
    }

    private static func bpmnTypeName(for localName: String) -> String {
        let leading = localName.prefix(1).uppercased()
        let remainder = localName.dropFirst()
        return "bpmn:\(leading)\(remainder)"
    }

    private static func localName(from qualifiedName: String) -> String {
        if let last = qualifiedName.split(separator: ":").last {
            return String(last)
        }
        return qualifiedName
    }
}
