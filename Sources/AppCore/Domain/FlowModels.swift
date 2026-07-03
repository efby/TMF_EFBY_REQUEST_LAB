import Foundation

public enum WorkspaceFlowNodeType: String, Codable, Hashable, Sendable {
    case startEvent
    case endEvent
    /// BPMN terminate end event: ends the entire process instance and cancels other branches.
    case terminateEndEvent
    case task
    case timerEvent
    case exclusiveGateway
    case parallelGateway
    case unsupported
}

public struct WorkspaceFlowTaskBinding: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var elementID: String
    public var requestID: UUID?
    /// Snapshot of the collection name when the task was bound; used to remap after import on another machine.
    public var boundCollectionName: String?
    /// Snapshot of the request (folder item) name when the task was bound.
    public var boundRequestName: String?
    /// Transport kind at bind time; narrows remapping if several requests share the same name.
    public var boundTransportKind: RequestTransportKind?

    public init(
        id: UUID = UUID(),
        elementID: String,
        requestID: UUID? = nil,
        boundCollectionName: String? = nil,
        boundRequestName: String? = nil,
        boundTransportKind: RequestTransportKind? = nil
    ) {
        self.id = id
        self.elementID = elementID
        self.requestID = requestID
        self.boundCollectionName = boundCollectionName
        self.boundRequestName = boundRequestName
        self.boundTransportKind = boundTransportKind
    }

    /// Workspace request UUID for validation and execution: the stored ID if it still exists, otherwise a unique match by bound collection + request name (and transport when needed).
    public func resolvedRequestID(matching availableRequests: [WorkspaceFlowRequestReference]) -> UUID? {
        if let requestID, availableRequests.contains(where: { $0.requestID == requestID }) {
            return requestID
        }
        if let match = rematchReference(in: availableRequests) {
            return match.requestID
        }
        return nil
    }

    private func rematchReference(in availableRequests: [WorkspaceFlowRequestReference]) -> WorkspaceFlowRequestReference? {
        let collectionName = boundCollectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestName = boundRequestName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collectionName, !collectionName.isEmpty, let requestName, !requestName.isEmpty else {
            return nil
        }

        var matches = availableRequests.filter { ref in
            ref.collectionName.caseInsensitiveCompare(collectionName) == .orderedSame
                && ref.requestName.caseInsensitiveCompare(requestName) == .orderedSame
        }

        if let kind = boundTransportKind {
            matches = matches.filter { $0.transportKind == kind }
        }

        if matches.count == 1 {
            return matches[0]
        }

        if matches.count > 1 {
            let exactCollection = matches.filter { $0.collectionName == collectionName }
            if exactCollection.count == 1 {
                return exactCollection[0]
            }
            let exactRequest = matches.filter { $0.requestName == requestName }
            if exactRequest.count == 1 {
                return exactRequest[0]
            }
        }

        return nil
    }
}

/// One row in the flow editor “Runs” tab: optional label + JSON object whose keys become environment variables before execution.
public struct WorkspaceFlowBatchRunCase: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Optional label shown in the list (e.g. “Visa happy path”).
    public var name: String
    /// UTF-8 JSON object at the root, e.g. `{"tipoflujo":"visa"}`. Keys map to active environment variable names.
    public var parametersJSON: String

    public init(id: UUID = UUID(), name: String = "", parametersJSON: String = "{}") {
        self.id = id
        self.name = name
        self.parametersJSON = parametersJSON
    }
}

/// Zoom and pan of the BPMN canvas (diagram-js viewbox), persisted with the flow.
public struct WorkspaceFlowDiagramViewport: Codable, Hashable, Sendable {
    /// Display zoom as a percentage (100 = 100 %); mirrors `canvas.zoom()` at capture time.
    public var zoomPercent: Double
    public var viewboxX: Double
    public var viewboxY: Double
    public var viewboxWidth: Double
    public var viewboxHeight: Double

    public init(
        zoomPercent: Double,
        viewboxX: Double,
        viewboxY: Double,
        viewboxWidth: Double,
        viewboxHeight: Double
    ) {
        self.zoomPercent = zoomPercent
        self.viewboxX = viewboxX
        self.viewboxY = viewboxY
        self.viewboxWidth = viewboxWidth
        self.viewboxHeight = viewboxHeight
    }
}

public struct WorkspaceFlowDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var bpmnXML: String
    public var taskBindings: [WorkspaceFlowTaskBinding]
    /// Last editor canvas zoom/pan; applied when the diagram is loaded in the web editor.
    public var diagramViewport: WorkspaceFlowDiagramViewport?
    /// Optional so older saved workspaces decode without migration.
    public var batchRunCases: [WorkspaceFlowBatchRunCase]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        bpmnXML: String = "",
        taskBindings: [WorkspaceFlowTaskBinding] = [],
        diagramViewport: WorkspaceFlowDiagramViewport? = nil,
        batchRunCases: [WorkspaceFlowBatchRunCase]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bpmnXML = bpmnXML
        self.taskBindings = taskBindings
        self.diagramViewport = diagramViewport
        self.batchRunCases = batchRunCases
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkspaceFlowGraphNode: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var bpmnType: String
    public var nodeType: WorkspaceFlowNodeType
    public var timerDefinition: String?
    public var incomingIDs: [String]
    public var outgoingIDs: [String]

    public init(
        id: String,
        name: String,
        bpmnType: String,
        nodeType: WorkspaceFlowNodeType,
        timerDefinition: String? = nil,
        incomingIDs: [String] = [],
        outgoingIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.bpmnType = bpmnType
        self.nodeType = nodeType
        self.timerDefinition = timerDefinition
        self.incomingIDs = incomingIDs
        self.outgoingIDs = outgoingIDs
    }
}

public struct WorkspaceFlowGraphConnection: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sourceID: String
    public var targetID: String
    public var name: String
    public var isDefault: Bool

    public init(
        id: String,
        sourceID: String,
        targetID: String,
        name: String = "",
        isDefault: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.name = name
        self.isDefault = isDefault
    }
}

public struct WorkspaceFlowGraphSnapshot: Codable, Hashable, Sendable {
    public var nodes: [WorkspaceFlowGraphNode]
    public var connections: [WorkspaceFlowGraphConnection]

    public init(
        nodes: [WorkspaceFlowGraphNode] = [],
        connections: [WorkspaceFlowGraphConnection] = []
    ) {
        self.nodes = nodes
        self.connections = connections
    }
}

public struct WorkspaceFlowRequestReference: Identifiable, Hashable, Sendable {
    public var id: UUID { requestID }
    public var requestID: UUID
    public var collectionID: UUID
    public var nodeID: UUID
    public var collectionName: String
    public var requestName: String
    public var transportKind: RequestTransportKind

    public init(
        requestID: UUID,
        collectionID: UUID,
        nodeID: UUID,
        collectionName: String,
        requestName: String,
        transportKind: RequestTransportKind
    ) {
        self.requestID = requestID
        self.collectionID = collectionID
        self.nodeID = nodeID
        self.collectionName = collectionName
        self.requestName = requestName
        self.transportKind = transportKind
    }
}

public enum WorkspaceFlowValidationSeverity: String, Codable, Hashable, Sendable {
    case error
    case warning
}

public struct WorkspaceFlowValidationIssue: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var severity: WorkspaceFlowValidationSeverity
    public var message: String
    public var elementID: String?

    public init(
        id: UUID = UUID(),
        severity: WorkspaceFlowValidationSeverity,
        message: String,
        elementID: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.elementID = elementID
    }
}

public struct WorkspaceFlowValidationResult: Codable, Hashable, Sendable {
    public var issues: [WorkspaceFlowValidationIssue]

    public init(issues: [WorkspaceFlowValidationIssue] = []) {
        self.issues = issues
    }

    public var isValid: Bool {
        !issues.contains(where: { $0.severity == .error })
    }
}

/// Live diagram highlight while a workspace flow runs (`enter` / `leave` per BPMN element id, then `clearAll`).
public enum WorkspaceFlowExecutionHighlightEvent: Sendable, Equatable {
    case enter(elementID: String)
    case leave(elementID: String)
    case clearAll
}

public struct WorkspaceFlowTaskExecutionResult: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var elementID: String
    public var requestID: UUID
    public var requestName: String
    public var statusCode: Int
    public var durationMilliseconds: Double

    public init(
        id: UUID = UUID(),
        elementID: String,
        requestID: UUID,
        requestName: String,
        statusCode: Int,
        durationMilliseconds: Double
    ) {
        self.id = id
        self.elementID = elementID
        self.requestID = requestID
        self.requestName = requestName
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct WorkspaceFlowCollectionUpdate: Hashable, Sendable {
    public var collectionID: UUID
    public var variables: [VariableValue]

    public init(collectionID: UUID, variables: [VariableValue]) {
        self.collectionID = collectionID
        self.variables = variables
    }
}

/// Full variable snapshot after a flow step (task, decision, or parallel join) for syncing the workspace UI mid-run.
public struct WorkspaceFlowExecutionVariableCheckpoint: Sendable {
    public var updatedGlobals: [VariableValue]
    public var updatedEnvironment: [VariableValue]
    public var updatedEnvironments: [EnvironmentProfile]
    public var activeEnvironmentID: UUID?
    public var updatedCollections: [WorkspaceFlowCollectionUpdate]

    public init(
        updatedGlobals: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        updatedCollections: [WorkspaceFlowCollectionUpdate]
    ) {
        self.updatedGlobals = updatedGlobals
        self.updatedEnvironment = updatedEnvironment
        self.updatedEnvironments = updatedEnvironments
        self.activeEnvironmentID = activeEnvironmentID
        self.updatedCollections = updatedCollections
    }
}

/// Live state for a workspace flow execution started from the UI (one active run per `flowID` in `MainViewModel`).
public struct WorkspaceFlowRunSession: Sendable {
    public var id: UUID
    public var flowID: UUID
    public var startedAt: Date
    public var logs: [String]
    public var isRunning: Bool
    public var lastResult: WorkspaceFlowExecutionResult?
    public var lastErrorDescription: String?

    public init(
        id: UUID = UUID(),
        flowID: UUID,
        startedAt: Date = Date(),
        logs: [String] = [],
        isRunning: Bool = true,
        lastResult: WorkspaceFlowExecutionResult? = nil,
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.flowID = flowID
        self.startedAt = startedAt
        self.logs = logs
        self.isRunning = isRunning
        self.lastResult = lastResult
        self.lastErrorDescription = lastErrorDescription
    }
}

public struct WorkspaceFlowExecutionResult: Sendable {
    public var logs: [String]
    public var taskResults: [WorkspaceFlowTaskExecutionResult]
    /// Tiempo en milisegundos desde el inicio de `WorkspaceFlowExecutionService.execute` hasta su retorno (reloj de pared del flujo BPMN).
    public var totalFlowWallClockMilliseconds: Double
    public var updatedGlobals: [VariableValue]
    public var updatedEnvironment: [VariableValue]
    public var updatedEnvironments: [EnvironmentProfile]
    public var activeEnvironmentID: UUID?
    public var updatedCollections: [WorkspaceFlowCollectionUpdate]

    public init(
        logs: [String],
        taskResults: [WorkspaceFlowTaskExecutionResult],
        totalFlowWallClockMilliseconds: Double = 0,
        updatedGlobals: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        updatedCollections: [WorkspaceFlowCollectionUpdate]
    ) {
        self.logs = logs
        self.taskResults = taskResults
        self.totalFlowWallClockMilliseconds = totalFlowWallClockMilliseconds
        self.updatedGlobals = updatedGlobals
        self.updatedEnvironment = updatedEnvironment
        self.updatedEnvironments = updatedEnvironments
        self.activeEnvironmentID = activeEnvironmentID
        self.updatedCollections = updatedCollections
    }
}

extension WorkspaceFlowExecutionResult {
    /// Líneas Markdown para el final del log (títulos, cita y lista con código HTTP resaltado).
    public func taskResultsSummaryLogLines() -> [String] {
        guard !taskResults.isEmpty else { return [] }
        var lines: [String] = []
        lines.append("")
        lines.append("## Resumen de requests (esta corrida)")
        lines.append("")
        lines.append(
            "> Los requests se resolvieron al iniciar esta corrida; los cambios en la colección aplican a la próxima ejecución."
        )
        lines.append("")
        for task in taskResults {
            let safeName = task.requestName
                .replacingOccurrences(of: "*", with: "·")
                .replacingOccurrences(of: "_", with: " ")
            lines.append(
                "- **\(safeName)** — HTTP `\(task.statusCode)` — \(Int(task.durationMilliseconds)) ms"
            )
        }
        if totalFlowWallClockMilliseconds > 0, totalFlowWallClockMilliseconds.isFinite {
            lines.append("")
            lines.append(
                "- **Tiempo total del flujo** (inicio → fin, reloj de pared): `\(Self.formatWallClockDuration(totalFlowWallClockMilliseconds))`"
            )
        }
        return lines
    }

    private static func formatWallClockDuration(_ ms: Double) -> String {
        guard ms.isFinite, ms > 0 else {
            return "0 ms"
        }
        if ms >= 60_000 {
            let minutes = Int(ms / 60_000)
            let seconds = (ms.truncatingRemainder(dividingBy: 60_000)) / 1000
            return String(format: "%dm %.1fs", minutes, seconds)
        }
        if ms >= 1_000 {
            return String(format: "%.2f s", ms / 1000)
        }
        return "\(Int(ms)) ms"
    }
}
