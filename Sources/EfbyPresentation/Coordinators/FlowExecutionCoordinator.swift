import EfbyApplication
import EfbyDomain
import Foundation

/// Coordina validación y ejecución de flujos BPMN del workspace.
@MainActor
public final class FlowExecutionCoordinator {
    private let flowExecutor: WorkspaceFlowExecutionService

    public init(
        httpRunner: any HTTPExecutionServiceProtocol,
        webSocketRunner: any WebSocketExecutionServiceProtocol
    ) {
        self.flowExecutor = WorkspaceFlowExecutionService(
            runner: httpRunner,
            webSocketRunner: webSocketRunner
        )
    }

    public func hasActiveRun(in sessions: [UUID: WorkspaceFlowRunSession], flowID: UUID) -> Bool {
        guard let session = sessions[flowID] else { return false }
        return session.isRunning
    }

    public func executionGraph(
        for flow: WorkspaceFlowDefinition,
        editorGraph: WorkspaceFlowGraphSnapshot
    ) -> WorkspaceFlowGraphSnapshot {
        let trimmed = flow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return editorGraph }
        do {
            return try WorkspaceFlowBPMNParser().parse(xml: flow.bpmnXML)
        } catch {
            return editorGraph
        }
    }

    public func validate(
        flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        availableRequests: [WorkspaceFlowRequestReference]
    ) -> WorkspaceFlowValidationResult {
        WorkspaceFlowValidator().validate(
            flow: flow,
            graph: graph,
            availableRequests: availableRequests
        )
    }

    public func execute(
        flow: WorkspaceFlowDefinition,
        graph: WorkspaceFlowGraphSnapshot,
        globals: [VariableValue],
        environment: [VariableValue],
        workspaceEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        utilityLibraries: [WorkspaceScriptUtility],
        resolvedRequests: [WorkspaceFlowResolvedRequest],
        onLog: (@Sendable (String) async -> Void)? = nil,
        onHighlight: (@Sendable (WorkspaceFlowExecutionHighlightEvent) -> Void)? = nil,
        onVariableCheckpoint: (@Sendable (WorkspaceFlowExecutionVariableCheckpoint) async -> Void)? = nil
    ) async throws -> WorkspaceFlowExecutionResult {
        let flowWallClockStart = Date()
        var result = try await flowExecutor.execute(
            flow: flow,
            graph: graph,
            globals: globals,
            environment: environment,
            workspaceEnvironments: workspaceEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            utilityLibraries: utilityLibraries,
            resolvedRequests: resolvedRequests,
            onLog: onLog,
            onHighlight: onHighlight,
            onVariableCheckpoint: onVariableCheckpoint
        )
        result.totalFlowWallClockMilliseconds = Date().timeIntervalSince(flowWallClockStart) * 1000
        return result
    }
}
