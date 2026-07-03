import EfbyPresentation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct WorkspaceFlowPortableDocument: Codable {
    var flow: WorkspaceFlowDefinition
    var graph: WorkspaceFlowGraphSnapshot
}

private enum WorkspaceFlowEditorTab: String, CaseIterable {
    case diagram = "Diagram"
    case validation = "Validation"
    case running = "Running"
    case runs = "Runs"
}

/// Shown beside tab labels until the user opens that tab (then cleared).
private enum WorkspaceFlowTabAttention: Equatable {
    case none
    case positive
    case negative
}

private struct BatchRunLastLogInspectTarget: Identifiable, Hashable {
    let caseID: UUID
    let title: String
    var id: UUID { caseID }
}

/// Reference-type log lines for batch runs: safe to append from `MainActor.run` / `onLog` without losing updates to a copied `[String]`.
private final class BatchRunTranscriptAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

struct WorkspaceFlowEditor: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: MainViewModel

    @State private var draftFlow: WorkspaceFlowDefinition
    @State private var graph: WorkspaceFlowGraphSnapshot
    @State private var selection: BPMNEditorSelection
    @State private var validation = WorkspaceFlowValidationResult()
    @State private var lastRunResult: WorkspaceFlowExecutionResult?
    @State private var liveRunLogs: [String] = []
    @State private var editorReloadToken = UUID()
    @State private var isRunning = false
    @State private var localStatusMessage: String?
    @State private var taskConfigurationNodeID: String?
    @State private var taskConfigurationNameDraft = ""
    @State private var pendingTaskRename: BPMNPendingTaskRename?
    @State private var pendingElementRemoval: BPMNPendingElementRemoval?
    @State private var taskRenameDebounceTask: Task<Void, Never>?
    @State private var showDeleteTaskConfirmation = false
    @State private var selectedEditorTab: WorkspaceFlowEditorTab = .diagram
    @State private var validationTabAttention: WorkspaceFlowTabAttention = .none
    @State private var runningTabAttention: WorkspaceFlowTabAttention = .none
    @State private var batchJSONInspectPresented = false
    /// Which batch case the JSON sheet edits (stable across reorder; never use a raw index for this).
    @State private var batchJSONInspectCaseID: UUID?
    /// Draft shown in the JSON sheet (`MacCodeEditor`); persisted minified on Done.
    @State private var batchJSONInspectDraft = ""
    @State private var batchRunLastLogInspectTarget: BatchRunLastLogInspectTarget?
    @State private var batchRunCasePendingDeletion: WorkspaceFlowBatchRunCase?
    @State private var showRunInFlightCloseConfirmation = false
    @State private var structuredBatchRunTask: Task<Void, Never>?

    init(flow: WorkspaceFlowDefinition, viewModel: MainViewModel) {
        self.viewModel = viewModel
        self._draftFlow = State(initialValue: Self.normalizedFlowForEditor(flow))
        self._graph = State(initialValue: WorkspaceFlowGraphSnapshot())
        self._selection = State(initialValue: .empty)
        // Siempre Diagram al abrir: monta el BPMN WebEditor y sincroniza `graph`. La pestaña Running sigue mostrando atención (punto) si hay sesión.
        self._selectedEditorTab = State(initialValue: .diagram)
    }

    private static func normalizedFlowForEditor(_ flow: WorkspaceFlowDefinition) -> WorkspaceFlowDefinition {
        var copy = flow
        if copy.batchRunCases == nil {
            copy.batchRunCases = []
        }
        return copy
    }

    /// Sin la pestaña Diagram el WebView no corre: el `graph` quedaría vacío y los runs fallan. Parseamos el XML al abrir el editor si hace falta (misma fuente que la ejecución en `MainViewModel`).
    private func loadGraphFromBpmnXMLIfNeeded() {
        guard graph.nodes.isEmpty else { return }
        let trimmed = draftFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let parsed = try? WorkspaceFlowBPMNParser().parse(xml: draftFlow.bpmnXML) else { return }
        graph = parsed
        refreshValidation()
    }

    private var availableRequests: [WorkspaceFlowRequestReference] {
        viewModel.availableFlowRequests()
    }

    private var enabledUtilityCount: Int {
        viewModel.workspace.utilityLibraries.filter { $0.isEnabled }.count
    }

    private var activeEnvironmentName: String {
        viewModel.activeEnvironment?.name ?? "No active environment"
    }

    private var selectableEnvironments: [EnvironmentProfile] {
        viewModel.workspace.environments.filter(\.isEnabled)
    }

    private var activeEnvironmentBinding: Binding<UUID?> {
        Binding(
            get: { viewModel.workspace.activeEnvironmentID },
            set: { newValue in
                let environment = selectableEnvironments.first(where: { $0.id == newValue })
                viewModel.activateEnvironment(environment)
            }
        )
    }

    private var taskNodes: [WorkspaceFlowGraphNode] {
        graph.nodes
            .filter { $0.nodeType == .task }
            .sorted { lhs, rhs in
                let leftName = lhs.name.isEmpty ? lhs.id : lhs.name
                let rightName = rhs.name.isEmpty ? rhs.id : rhs.name
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
    }

    private var currentValidationMessage: String? {
        viewModel.flowNameValidationMessage(draftFlow.name, excluding: draftFlow.id)
    }

    private var selectedGraphNode: WorkspaceFlowGraphNode? {
        guard let elementID = selection.elementID else {
            return nil
        }
        return graph.nodes.first(where: { $0.id == elementID })
    }

    private var canSave: Bool {
        currentValidationMessage == nil && !draftFlow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var flowRunSession: WorkspaceFlowRunSession? {
        viewModel.flowRunSession(for: draftFlow.id)
    }

    private var isBackgroundFlowRunning: Bool {
        flowRunSession?.isRunning == true
    }

    /// Batch/sequential runs (`executeFlow`) or a detached background run tracked in `MainViewModel`.
    private var isFlowExecutionLive: Bool {
        isRunning || isBackgroundFlowRunning
    }

    private var observedBackgroundFlowIsRunning: Bool {
        flowRunSession?.isRunning ?? false
    }

    /// Drives `onChange` when the VM session for this flow updates (e.g. reabrir el sheet tras segundo plano).
    private var flowRunSessionRecoverySignature: String {
        guard let session = viewModel.flowRunSession(for: draftFlow.id) else {
            return "\(draftFlow.id)-none"
        }
        let errLen = session.lastErrorDescription?.count ?? 0
        return "\(draftFlow.id)-\(session.isRunning)-\(session.logs.count)-\(session.lastResult != nil)-\(errLen)"
    }

    private var displayLiveLogs: [String] {
        if let session = flowRunSession,
           session.isRunning || !session.logs.isEmpty || session.lastResult != nil || session.lastErrorDescription != nil {
            return session.logs
        }
        if isRunning {
            return liveRunLogs
        }
        return liveRunLogs
    }

    private var effectiveLastRunResult: WorkspaceFlowExecutionResult? {
        if let result = flowRunSession?.lastResult {
            return result
        }
        return lastRunResult
    }

    /// Sincroniza el indicador de la pestaña **Running** con la sesión en `MainViewModel` **sin** cambiar la pestaña activa (Diagram, Runs, etc.).
    private func reattachFlowRunSessionUIIfNeeded() {
        guard let session = viewModel.flowRunSession(for: draftFlow.id) else { return }
        let hasSomethingToShow =
            session.isRunning
            || !session.logs.isEmpty
            || session.lastResult != nil
            || session.lastErrorDescription != nil
        guard hasSomethingToShow else { return }

        if session.isRunning {
            runningTabAttention = .positive
        } else if session.lastErrorDescription != nil {
            runningTabAttention = .negative
        } else if let result = session.lastResult {
            runningTabAttention = executionResultIndicatesSuccess(result) ? .positive : .negative
        } else if !session.logs.isEmpty {
            runningTabAttention = .positive
        } else {
            runningTabAttention = .none
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(PostmanTheme.border)

            mainContent

            Divider()
                .overlay(PostmanTheme.border)

            footer
        }
        .frame(minWidth: 1240, minHeight: 820)
        .background(PostmanTheme.appBackground)
        .confirmationDialog(
            "Cerrar editor",
            isPresented: $showRunInFlightCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Seguir en segundo plano") {
                dismiss()
            }
            Button("Cancelar ejecución", role: .destructive) {
                viewModel.cancelFlowExecution(flowID: draftFlow.id)
                structuredBatchRunTask?.cancel()
                structuredBatchRunTask = nil
                dismiss()
            }
            Button("Volver", role: .cancel) {}
        } message: {
            Text(
                "Hay una ejecución en curso. Puedes seguir en segundo plano o cancelar cooperativamente (puede tardar hasta el siguiente await en el runtime)."
            )
        }
        .alert(
            "Eliminar run",
            isPresented: Binding(
                get: { batchRunCasePendingDeletion != nil },
                set: { if !$0 { batchRunCasePendingDeletion = nil } }
            ),
            presenting: batchRunCasePendingDeletion
        ) { runCase in
            Button("Eliminar", role: .destructive) {
                removeBatchRunCase(id: runCase.id)
                batchRunCasePendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) {
                batchRunCasePendingDeletion = nil
            }
        } message: { runCase in
            let label = runCase.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = label.isEmpty ? "esta fila" : "«\(label)»"
            Text("¿Eliminar \(quoted) de la lista de runs? Se perderán el JSON guardado y el último log asociado a esta prueba.")
        }
        .onAppear {
            loadGraphFromBpmnXMLIfNeeded()
            reconcileTaskBindingsWithAvailableRequests()
            reattachFlowRunSessionUIIfNeeded()
        }
        .onChange(of: flowRunSessionRecoverySignature) { _, _ in
            reattachFlowRunSessionUIIfNeeded()
        }
        .onChange(of: viewModel.cancelAllRunningFlowsTick) { _, _ in
            structuredBatchRunTask?.cancel()
            structuredBatchRunTask = nil
        }
        .onChange(of: observedBackgroundFlowIsRunning) { wasRunning, nowRunning in
            guard wasRunning, !nowRunning else { return }
            if let session = flowRunSession, session.lastResult != nil {
                let runOK = session.lastResult.map(executionResultIndicatesSuccess) ?? false
                if selectedEditorTab == .running {
                    runningTabAttention = .none
                } else {
                    runningTabAttention = runOK ? .positive : .negative
                }
                localStatusMessage = runOK ? "Flow executed successfully." : "Flow finished with errors — see Running tab."
            } else if flowRunSession?.lastErrorDescription != nil {
                if selectedEditorTab != .running {
                    runningTabAttention = .negative
                }
                localStatusMessage = "Flow execution stopped."
            }
        }
        .onChange(of: graph) { _, _ in
            sanitizeBindings()
            reconcileTaskBindingsWithAvailableRequests()
            refreshValidation()
        }
        .onChange(of: viewModel.workspace.collections.count) { _, _ in
            reconcileTaskBindingsWithAvailableRequests()
        }
        .onChange(of: draftFlow.taskBindings) { _, _ in
            refreshValidation()
        }
        .onChange(of: taskConfigurationNodeID) { _, newID in
            showDeleteTaskConfirmation = false
            taskRenameDebounceTask?.cancel()
            taskRenameDebounceTask = nil
            pendingTaskRename = nil
            if let newID,
               let node = graph.nodes.first(where: { $0.id == newID && $0.nodeType == .task }) {
                taskConfigurationNameDraft = node.name
            } else {
                taskConfigurationNameDraft = ""
            }
        }
        .sheet(item: taskConfigurationBinding) { target in
            taskConfigurationSheet(for: target.id, showDeleteConfirmation: $showDeleteTaskConfirmation)
                .confirmationDialog(
                    "Borrar tarea",
                    isPresented: $showDeleteTaskConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Borrar", role: .destructive) {
                        confirmDeleteTask(elementID: target.id)
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("¿Estás seguro de que quieres borrar esta tarea? Se eliminará del diagrama y se quitará la vinculación al request.")
                }
        }
        .sheet(isPresented: $batchJSONInspectPresented) {
            batchJSONParametersInspectSheet
        }
        .onChange(of: batchJSONInspectPresented) { _, isPresented in
            if !isPresented {
                batchJSONInspectCaseID = nil
            }
        }
        .sheet(item: $batchRunLastLogInspectTarget) { target in
            batchRunLastLogInspectSheet(target: target)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace Flow")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Text("BPMN visual editor integrated with workspace requests, shared utilities, environments, and current execution context.")
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    requestDismissFlowEditor()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Name")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .fixedSize()

                    DarkTextInput(text: $draftFlow.name, placeholder: "Flow name")
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .frame(minWidth: 140, maxWidth: 280)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                }

                environmentBadge
                    .layoutPriority(1)

                contextBadge(title: "Utilities", value: "\(enabledUtilityCount) enabled")
                contextBadge(title: "Requests", value: "\(availableRequests.count)")

                Spacer(minLength: 0)
            }

            if let currentValidationMessage {
                Text(currentValidationMessage)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.salmon)
            } else if let localStatusMessage {
                Text(localStatusMessage)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }
        }
        .padding(24)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            flowEditorTabStrip
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(PostmanTheme.appBackground)

            Divider()
                .overlay(PostmanTheme.border)

            Group {
                switch selectedEditorTab {
                case .diagram:
                    editorPanel
                case .validation:
                    validationTabContent
                case .running:
                    runningTabContent
                case .runs:
                    runsTabContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var flowEditorTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceFlowEditorTab.allCases, id: \.self) { tab in
                flowEditorTabButton(tab)
            }
            Spacer(minLength: 0)
        }
    }

    private func flowEditorTabButton(_ tab: WorkspaceFlowEditorTab) -> some View {
        let selected = selectedEditorTab == tab
        let attention = attention(for: tab)
        return Button {
            selectEditorTab(tab)
        } label: {
            HStack(spacing: 8) {
                Text(tab.rawValue)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                if attention != .none {
                    Circle()
                        .fill(attention == .positive ? PostmanTheme.green : PostmanTheme.salmon)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(attention == .positive ? "Status: OK" : "Status: needs attention")
                }
            }
            .foregroundStyle(selected ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                selected ? PostmanTheme.panel : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? PostmanTheme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tabTooltip(for: tab, attention: attention))
    }

    private func attention(for tab: WorkspaceFlowEditorTab) -> WorkspaceFlowTabAttention {
        switch tab {
        case .diagram:
            return .none
        case .validation:
            return validationTabAttention
        case .running:
            return runningTabAttention
        case .runs:
            return .none
        }
    }

    private func tabTooltip(for tab: WorkspaceFlowEditorTab, attention: WorkspaceFlowTabAttention) -> String {
        switch tab {
        case .diagram:
            return "BPMN diagram and task bindings"
        case .validation:
            switch attention {
            case .none:
                return "Open validation results for this flow"
            case .positive:
                return "Validation passed — open the Validation tab to review"
            case .negative:
                return "Validation issues found — open the Validation tab to review"
            }
        case .running:
            switch attention {
            case .none:
                return "Open run logs and last execution summary"
            case .positive:
                if isFlowExecutionLive {
                    return "Flow is running — open the Running tab for live logs"
                }
                return "Last run finished — open the Running tab for details"
            case .negative:
                return "Last run failed or returned error responses — open the Running tab to review"
            }
        case .runs:
            return "Define JSON parameters per run, apply to the active environment, and execute the flow once or in sequence"
        }
    }

    private func selectEditorTab(_ tab: WorkspaceFlowEditorTab) {
        selectedEditorTab = tab
        switch tab {
        case .diagram:
            break
        case .validation:
            validationTabAttention = .none
        case .running:
            runningTabAttention = .none
        case .runs:
            break
        }
    }

    private var validationTabContent: some View {
        ScrollView {
            validationCard
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PostmanTheme.sidebar)
    }

    private var runningTabContent: some View {
        executionCard
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(PostmanTheme.sidebar)
    }

    private var runsTabContent: some View {
        let rows = draftFlow.batchRunCases ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Runs")
                    Text(
                        "Each row is one run: JSON object at the root → keys become active environment variables before the flow runs. Save persists the list. Use the chevrons on the left to reorder rows. Use the magnifier for a larger JSON editor."
                    )
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    secondaryButton("Add run", action: appendBatchRunCase)
                    secondaryButton("Run all (sequential)") {
                        structuredBatchRunTask?.cancel()
                        structuredBatchRunTask = Task { @MainActor in
                            await runAllBatchRunsSequentially()
                            structuredBatchRunTask = nil
                        }
                    }
                    .disabled(isFlowExecutionLive || rows.isEmpty)
                }

                if rows.isEmpty {
                    Text("No runs yet. Add a row and set JSON, for example {\"tipoflujo\":\"visa\"}.")
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.textSecondary)
                } else {
                    batchRunsTable(rows: rows)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PostmanTheme.sidebar)
    }

    private func batchRunsTable(rows: [WorkspaceFlowBatchRunCase]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Order")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .frame(width: 28, alignment: .center)
                Text("Name")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .frame(width: 168, alignment: .leading)
                Text("Parameters (JSON)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Actions")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .frame(width: 176, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, runCase in
                Group {
                    batchRunTableRow(caseID: runCase.id, rowIndexParity: index % 2 == 0)
                    if index < rows.count - 1 {
                        Divider()
                            .overlay(PostmanTheme.border)
                            .padding(.leading, 12)
                    }
                }
            }
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        }
    }

    private func batchRunCasesSnapshot() -> [WorkspaceFlowBatchRunCase] {
        draftFlow.batchRunCases ?? []
    }

    private func indexOfBatchCase(withID id: UUID) -> Int? {
        batchRunCasesSnapshot().firstIndex { $0.id == id }
    }

    private func batchRunTableRow(caseID: UUID, rowIndexParity: Bool) -> some View {
        let rows = batchRunCasesSnapshot()
        let rowIndex = indexOfBatchCase(withID: caseID)
        return HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 0) {
                Button {
                    moveBatchRunCase(caseID: caseID, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(rowIndex.map { $0 > 0 } ?? false ? PostmanTheme.textSecondary : PostmanTheme.textSecondary.opacity(0.25))
                        .frame(width: 28, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(rowIndex.map { $0 == 0 } ?? true || rows.count < 2)
                .help("Move this run up")

                Button {
                    moveBatchRunCase(caseID: caseID, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(
                            (rowIndex.map { $0 < rows.count - 1 } ?? false)
                                ? PostmanTheme.textSecondary
                                : PostmanTheme.textSecondary.opacity(0.25)
                        )
                        .frame(width: 28, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(rowIndex.map { $0 >= rows.count - 1 } ?? true || rows.count < 2)
                .help("Move this run down")
            }
            .frame(width: 28, height: 28)
            .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            DarkTextInput(
                text: Binding(
                    get: {
                        guard let i = indexOfBatchCase(withID: caseID) else { return "" }
                        return (draftFlow.batchRunCases ?? [])[i].name
                    },
                    set: { newValue in
                        guard let i = indexOfBatchCase(withID: caseID) else { return }
                        updateBatchRunCase(at: i) { $0.name = newValue }
                    }
                ),
                placeholder: "Name",
                fontSize: 11
            )
            .padding(.horizontal, 8)
            .frame(width: 168, height: 28)
            .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            Button {
                batchJSONInspectCaseID = caseID
                batchJSONInspectPresented = true
            } label: {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(
                        FlowBatchJSONSyntax.attributedCompact(
                            (draftFlow.batchRunCases ?? []).first(where: { $0.id == caseID })?.parametersJSON ?? "{}",
                            baseSize: 9
                        )
                    )
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                }
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
            }
            .buttonStyle(.plain)
            .help("Abrir editor JSON; al guardar se compacta en una línea")

            HStack(spacing: 6) {
                Button {
                    batchJSONInspectCaseID = caseID
                    batchJSONInspectPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 32, height: 28)
                        .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Abrir editor JSON")

                Button {
                    guard let idx = indexOfBatchCase(withID: caseID) else { return }
                    let row = rows[idx]
                    let displayTitle = row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Run \(idx + 1)"
                        : row.name
                    batchRunLastLogInspectTarget = BatchRunLastLogInspectTarget(caseID: row.id, title: displayTitle)
                } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 32, height: 28)
                        .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ver último log de esta prueba")
                .disabled(lastBatchRunTranscript(forCaseID: caseID).isEmpty)

                Button {
                    structuredBatchRunTask?.cancel()
                    structuredBatchRunTask = Task { @MainActor in
                        await runSingleBatchRun(caseID: caseID)
                        structuredBatchRunTask = nil
                    }
                } label: {
                    Text("Run")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 40, height: 28)
                        .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFlowExecutionLive)

                Button {
                    guard let runCase = rows.first(where: { $0.id == caseID }) else { return }
                    batchRunCasePendingDeletion = runCase
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PostmanTheme.salmon)
                        .frame(width: 32, height: 28)
                        .background(PostmanTheme.appBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Eliminar esta fila de runs")
            }
            .frame(width: 176, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(rowIndexParity ? PostmanTheme.panel.opacity(0.35) : Color.clear)
    }

    private var batchJSONParametersInspectSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("JSON parameters")
                    .font(.headline)
                    .foregroundStyle(PostmanTheme.textPrimary)
                Spacer()
                Button("Done") {
                    let rows = draftFlow.batchRunCases ?? []
                    if let caseID = batchJSONInspectCaseID,
                       let idx = rows.firstIndex(where: { $0.id == caseID }) {
                        let minified = FlowBatchJSONSyntax.minifiedForListDisplay(batchJSONInspectDraft)
                        updateBatchRunCase(at: idx) { $0.parametersJSON = minified }
                    }
                    batchJSONInspectPresented = false
                }
                .foregroundStyle(PostmanTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            let rows = draftFlow.batchRunCases ?? []
            if let snapshotID = batchJSONInspectCaseID,
               rows.contains(where: { $0.id == snapshotID }) {
                Divider()
                    .overlay(PostmanTheme.border)

                MacCodeEditor(
                    text: $batchJSONInspectDraft,
                    language: .json,
                    showsLineNumbers: true,
                    tabWidth: 2
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
                .padding(16)
            } else {
                Text("This run no longer exists.")
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .padding(24)
                Spacer()
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(PostmanTheme.appBackground)
        .onAppear {
            let rows = draftFlow.batchRunCases ?? []
            guard let caseID = batchJSONInspectCaseID,
                  let row = rows.first(where: { $0.id == caseID }) else {
                batchJSONInspectPresented = false
                batchJSONInspectCaseID = nil
                return
            }
            batchJSONInspectDraft = FlowBatchJSONSyntax.prettyPrinted(row.parametersJSON)
        }
    }

    private func updateBatchRunCase(at index: Int, _ mutate: (inout WorkspaceFlowBatchRunCase) -> Void) {
        var rows = draftFlow.batchRunCases ?? []
        guard rows.indices.contains(index) else { return }
        mutate(&rows[index])
        draftFlow.batchRunCases = rows
    }

    /// Swaps this row with the neighbour above (-1) or below (+1). Editing stays tied to `caseID`, not list index.
    private func moveBatchRunCase(caseID: UUID, direction: Int) {
        var rows = draftFlow.batchRunCases ?? []
        guard let index = rows.firstIndex(where: { $0.id == caseID }) else { return }
        let destination = index + direction
        guard rows.indices.contains(destination) else { return }
        rows.swapAt(index, destination)
        draftFlow.batchRunCases = rows
    }

    private func appendBatchRunCase() {
        var rows = draftFlow.batchRunCases ?? []
        rows.append(WorkspaceFlowBatchRunCase())
        draftFlow.batchRunCases = rows
    }

    private func removeBatchRunCase(id: UUID) {
        var rows = draftFlow.batchRunCases ?? []
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.remove(at: index)
        draftFlow.batchRunCases = rows
        viewModel.removeWorkspaceFlowBatchCaseTranscript(flowID: draftFlow.id, caseID: id)
        if batchJSONInspectCaseID == id {
            batchJSONInspectPresented = false
            batchJSONInspectCaseID = nil
        }
    }

    private func lastBatchRunTranscript(forCaseID id: UUID) -> [String] {
        viewModel.workspaceFlowBatchCaseTranscript(flowID: draftFlow.id, caseID: id)
    }

    private func executeBatchRunCase(caseID: UUID) async throws {
        let rows = draftFlow.batchRunCases ?? []
        guard let index = rows.firstIndex(where: { $0.id == caseID }) else { return }
        let runCase = rows[index]
        let caseID = runCase.id
        let title = runCase.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Run \(index + 1)"
            : runCase.name

        let transcript = BatchRunTranscriptAccumulator()

        let headerApplying = "=== \(title): applying JSON to active environment ==="
        await MainActor.run {
            transcript.append(headerApplying)
            viewModel.appendEditorSynchronousFlowRunLog(flowID: draftFlow.id, line: headerApplying)
        }
        // Siempre: unión de claves de primer nivel de **todas** las filas del batch → quitar del entorno activo → aplicar solo el JSON de esta fila.
        // Así un «Run» individual no deja valores colgantes de otras filas (p. ej. otro `transaccionTipo`).
        let keysToRemove = viewModel.allTopLevelKeysFromFlowBatchRunCases(rows)
        let keysSorted = keysToRemove.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let keysListForLog: String = {
            guard !keysSorted.isEmpty else { return "(ninguna clave en los JSON del batch)" }
            let joined = keysSorted.joined(separator: ", ")
            if joined.count <= 400 { return joined }
            return String(joined.prefix(397)) + "…"
        }()
        let scrubLine = "Batch env: quitando \(keysToRemove.count) clave(s) definidas en alguna fila del batch → [\(keysListForLog)]"
        await MainActor.run {
            transcript.append(scrubLine)
            viewModel.appendEditorSynchronousFlowRunLog(flowID: draftFlow.id, line: scrubLine)
        }
        try viewModel.removeActiveEnvironmentVariables(withKeys: keysToRemove)
        try viewModel.upsertActiveEnvironmentVariablesFromFlowBatchParametersJSON(runCase.parametersJSON)
        let headerExecuting = "=== \(title): executing flow ==="
        await MainActor.run {
            transcript.append(headerExecuting)
            viewModel.appendEditorSynchronousFlowRunLog(flowID: draftFlow.id, line: headerExecuting)
        }

        func persistTranscript() {
            viewModel.recordWorkspaceFlowBatchCaseTranscript(flowID: draftFlow.id, caseID: caseID, lines: transcript.snapshot)
        }

        do {
            let result = try await viewModel.executeFlow(
                currentFlowSnapshot(),
                graph: graph
            ) { entry in
                await MainActor.run {
                    transcript.append(entry)
                    viewModel.appendEditorSynchronousFlowRunLog(flowID: draftFlow.id, line: entry)
                }
            }
            await MainActor.run {
                lastRunResult = result
                persistTranscript()
            }
        } catch {
            await MainActor.run {
                persistTranscript()
            }
            throw error
        }
    }

    private func batchRunLastLogInspectSheet(target: BatchRunLastLogInspectTarget) -> some View {
        let lines = viewModel.workspaceFlowBatchCaseTranscript(flowID: draftFlow.id, caseID: target.caseID)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Último log — \(target.title)")
                    .font(.headline)
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copiar") {
                    let text = lines.joined(separator: "\n")
                    guard !text.isEmpty else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    localStatusMessage = "Log copiado al portapapeles."
                }
                .buttonStyle(.plain)
                .foregroundStyle(lines.isEmpty ? PostmanTheme.textSecondary : PostmanTheme.accent)
                .disabled(lines.isEmpty)
                Button("Cerrar") {
                    batchRunLastLogInspectTarget = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
            }
            .padding(16)

            Divider()
                .overlay(PostmanTheme.border)

            if lines.isEmpty {
                Text("Aún no hay log para esta prueba. Usa Run o Run all (sequential).")
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .padding(24)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { entry in
                            WorkspaceFlowRunLogStyledRow(text: entry.element)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 480)
        .background(PostmanTheme.appBackground)
    }

    private func runSingleBatchRun(caseID: UUID) async {
        guard !isRunning, !viewModel.hasActiveFlowRun(for: draftFlow.id) else { return }
        viewModel.beginEditorSynchronousFlowRun(flowID: draftFlow.id)
        isRunning = true
        if selectedEditorTab != .running {
            runningTabAttention = .positive
        }
        defer { isRunning = false }

        do {
            try await executeBatchRunCase(caseID: caseID)
            if let result = lastRunResult {
                viewModel.finishEditorSynchronousFlowRun(flowID: draftFlow.id, result: result)
            }
            let runOK = lastRunResult.map(executionResultIndicatesSuccess) ?? false
            if selectedEditorTab == .running {
                runningTabAttention = .none
            } else {
                runningTabAttention = runOK ? .positive : .negative
            }
            localStatusMessage = "Batch run finished."
        } catch is CancellationError {
            viewModel.markFlowRunCancelled(flowID: draftFlow.id)
            if selectedEditorTab != .running {
                runningTabAttention = .none
            }
            localStatusMessage = "Ejecución cancelada."
        } catch {
            viewModel.markEditorSynchronousFlowRunFailed(flowID: draftFlow.id, error: error)
            viewModel.errorMessage = error.localizedDescription
            if selectedEditorTab != .running {
                runningTabAttention = .negative
            }
        }
    }

    private func runAllBatchRunsSequentially() async {
        guard !isRunning, !viewModel.hasActiveFlowRun(for: draftFlow.id) else { return }
        let rows = draftFlow.batchRunCases ?? []
        guard !rows.isEmpty else { return }
        viewModel.beginEditorSynchronousFlowRun(flowID: draftFlow.id)
        isRunning = true
        if selectedEditorTab != .running {
            runningTabAttention = .positive
        }
        defer { isRunning = false }

        var allOK = true
        var aborted = false
        var lastCompletedResult: WorkspaceFlowExecutionResult?
        let orderedCaseIDs = rows.map(\.id)
        for (offset, caseID) in orderedCaseIDs.enumerated() {
            await MainActor.run {
                viewModel.appendEditorSynchronousFlowRunLog(
                    flowID: draftFlow.id,
                    line: "——— Batch \(offset + 1) / \(orderedCaseIDs.count) ———"
                )
            }
            do {
                try await executeBatchRunCase(caseID: caseID)
                lastCompletedResult = lastRunResult
                if let result = lastRunResult, !executionResultIndicatesSuccess(result) {
                    allOK = false
                }
            } catch is CancellationError {
                allOK = false
                aborted = true
                viewModel.markFlowRunCancelled(flowID: draftFlow.id)
                break
            } catch {
                allOK = false
                aborted = true
                viewModel.errorMessage = error.localizedDescription
                viewModel.markEditorSynchronousFlowRunFailed(flowID: draftFlow.id, error: error)
                break
            }
        }

        if !aborted, let result = lastCompletedResult {
            viewModel.finishEditorSynchronousFlowRun(flowID: draftFlow.id, result: result)
        }

        if selectedEditorTab == .running {
            runningTabAttention = .none
        } else {
            runningTabAttention = allOK ? .positive : .negative
        }
        if aborted, flowRunSession?.lastErrorDescription == "Cancelled" {
            localStatusMessage = "Ejecución cancelada."
        } else {
            localStatusMessage = allOK
                ? "All batch runs finished."
                : "Batch stopped: check the error message or Running tab."
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Visual BPMN Editor")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PostmanTheme.textSecondary)

                Text("Double-click a task to configure it. Start, end, task, timer event, exclusive gateway, parallel gateway, and sequence flow")
                    .font(.caption2)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BPMNFlowWebEditor(
                xml: $draftFlow.bpmnXML,
                graph: $graph,
                selection: $selection,
                diagramViewport: $draftFlow.diagramViewport,
                taskBindings: draftFlow.taskBindings,
                availableRequests: availableRequests,
                executionHighlightElementIDs: Array(viewModel.flowExecutionHighlightElementIDs).sorted(),
                pendingTaskRename: $pendingTaskRename,
                pendingElementRemoval: $pendingElementRemoval,
                onError: { message in
                    viewModel.errorMessage = message
                },
                onTaskDoubleClicked: { picked in
                    guard picked.nodeType == .task, let elementID = picked.elementID else { return }
                    taskConfigurationNodeID = elementID
                }
            )
            .id(editorReloadToken)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PostmanTheme.border))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
    }

    private var validationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Validation")
                Spacer()
                Text(validation.isValid ? "Ready" : "Review required")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(validation.isValid ? PostmanTheme.green : PostmanTheme.salmon)
            }

            if validation.issues.isEmpty {
                Text("No validation issues yet. The current graph is compatible with the supported BPMN subset.")
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(validation.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? PostmanTheme.salmon : Color.orange)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.message)
                                    .font(.caption)
                                    .foregroundStyle(PostmanTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let elementID = issue.elementID {
                                    Text(elementID)
                                        .font(.caption2)
                                        .foregroundStyle(PostmanTheme.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PostmanTheme.border))
    }

    /// Líneas mostradas en Running: misma fuente en vivo y al terminar (evita recrear el `ScrollView` y perder la posición).
    private var executionLogLinesForDisplay: [String] {
        let live = displayLiveLogs
        if !live.isEmpty {
            return live
        }
        return effectiveLastRunResult?.logs ?? []
    }

    private var showsFlowExecutionLogPanel: Bool {
        isFlowExecutionLive
            || !executionLogLinesForDisplay.isEmpty
            || !(flowRunSession?.lastErrorDescription?.isEmpty ?? true)
    }

    private var executionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(isFlowExecutionLive ? "Running" : "Last Run")
                Spacer()
                if executionTraceText != nil {
                    Button {
                        copyExecutionTrace()
                    } label: {
                        Label("Copy Trace", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.textSecondary)
                }

                if isFlowExecutionLive {
                    Text("Live")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PostmanTheme.green)
                } else if let effectiveLastRunResult {
                    Text("\(effectiveLastRunResult.taskResults.count) requests")
                        .font(.caption2)
                        .foregroundStyle(PostmanTheme.textSecondary)
                }
            }

            Group {
                if showsFlowExecutionLogPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        if isFlowExecutionLive {
                            Text("Executing flow. Live logs will appear here as each task advances.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()
                                .overlay(PostmanTheme.border)
                        }

                        if let err = flowRunSession?.lastErrorDescription,
                           !err.isEmpty,
                           executionLogLinesForDisplay.isEmpty,
                           !isFlowExecutionLive {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.salmon)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                if executionLogLinesForDisplay.isEmpty, isFlowExecutionLive {
                                    Text("Preparing execution...")
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundStyle(PostmanTheme.textSecondary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ForEach(Array(executionLogLinesForDisplay.enumerated()), id: \.offset) { entry in
                                        WorkspaceFlowRunLogStyledRow(text: entry.element)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Run the flow to execute the bound requests with the current environment, shared utilities, and collection configuration.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PostmanTheme.border))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            secondaryButton("New Diagram", action: resetDiagram)
            secondaryButton("Import", action: importFlowDocument)
            secondaryButton("Export XML", action: exportXML)
            secondaryButton("Export JSON", action: exportJSON)
            secondaryButton("Validate", action: validateAndShowPanel)

            Spacer()

            Button {
                beginBackgroundFlowRun()
            } label: {
                HStack(spacing: 8) {
                    if isFlowExecutionLive {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isFlowExecutionLive ? "Running..." : "Run")
                }
                .frame(width: 120, height: 34)
                .contentShape(Rectangle())
                .background(PostmanTheme.green, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(isFlowExecutionLive)

            Button {
                saveFlow()
            } label: {
                Text("Save")
                    .frame(width: 120, height: 34)
                    .contentShape(Rectangle())
                    .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .opacity(canSave ? 1 : 0.55)
            .disabled(!canSave)

            secondaryButton("Close") {
                requestDismissFlowEditor()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func contextBadge(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)
                .fixedSize()
            Text(value)
                .foregroundStyle(PostmanTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(minWidth: 118, alignment: .leading)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
    }

    private var environmentBadge: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Environment")
                .font(.caption2.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)
                .fixedSize()

            Picker("Environment", selection: activeEnvironmentBinding) {
                Text("No active environment").tag(Optional<UUID>.none)
                ForEach(selectableEnvironments) { environment in
                    Text(environment.name).tag(environment.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textPrimary)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(PostmanTheme.textSecondary)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var taskConfigurationBinding: Binding<TaskConfigurationTarget?> {
        Binding<TaskConfigurationTarget?>(
            get: {
                guard let taskConfigurationNodeID else { return nil }
                return TaskConfigurationTarget(id: taskConfigurationNodeID)
            },
            set: { newValue in
                taskConfigurationNodeID = newValue?.id
            }
        )
    }

    @ViewBuilder
    private func taskConfigurationSheet(for elementID: String, showDeleteConfirmation: Binding<Bool>) -> some View {
        if let node = graph.nodes.first(where: { $0.id == elementID && $0.nodeType == .task }) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Task name")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)
                        DarkTextInput(text: taskNameDraftBinding(for: elementID), placeholder: "Task name")
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        Text(node.id)
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }

                    Spacer()

                    Button {
                        flushPendingTaskRename(for: elementID)
                        taskConfigurationNodeID = nil
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bound request")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)

                    Picker("Bound request", selection: requestBinding(for: elementID)) {
                        Text("Unbound").tag(Optional<UUID>.none)
                        ForEach(availableRequests) { reference in
                            Text(requestLabel(for: reference)).tag(reference.requestID as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                }

                if let binding = draftFlow.taskBindings.first(where: { $0.elementID == elementID }),
                   let resolvedID = binding.resolvedRequestID(matching: availableRequests),
                   let reference = availableRequests.first(where: { $0.requestID == resolvedID }) {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Collection", value: reference.collectionName)
                        detailRow("Transport", value: reference.transportKind.displayName)
                    }
                }

                Text("Tip: label the sequence flow out of an exclusive gateway with flow-only conditions, for example `response.statusCode == 200`, `response.statusCode IN [200, 201]`, `environment.tipoflujo == 'visa'`, `environment.tipoflujo IN ['visa', 'mc']`, `globals.mode != 'off'`, or `globals.mode IN ['dry-run', 'full']`. Use the active environment’s variable keys as they appear in the editor.")
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                HStack {
                    Button {
                        showDeleteConfirmation.wrappedValue = true
                    } label: {
                        Text("Borrar")
                            .frame(height: 34)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.salmon)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.salmon.opacity(0.45)))

                    Spacer()

                    secondaryButton("Done") {
                        flushPendingTaskRename(for: elementID)
                        taskConfigurationNodeID = nil
                    }
                }
            }
            .padding(24)
            .frame(minWidth: 520, minHeight: 340)
            .background(PostmanTheme.appBackground)
        } else {
            EmptyView()
        }
    }

    private func taskNameDraftBinding(for elementID: String) -> Binding<String> {
        Binding(
            get: { taskConfigurationNameDraft },
            set: { newValue in
                taskConfigurationNameDraft = newValue
                scheduleDebouncedTaskRename(elementID: elementID, name: newValue)
            }
        )
    }

    private func scheduleDebouncedTaskRename(elementID: String, name: String) {
        taskRenameDebounceTask?.cancel()
        taskRenameDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            pendingTaskRename = BPMNPendingTaskRename(
                elementID: elementID,
                name: name,
                requestID: UUID()
            )
        }
    }

    private func flushPendingTaskRename(for elementID: String) {
        taskRenameDebounceTask?.cancel()
        taskRenameDebounceTask = nil
        pendingTaskRename = BPMNPendingTaskRename(
            elementID: elementID,
            name: taskConfigurationNameDraft,
            requestID: UUID()
        )
    }

    private func confirmDeleteTask(elementID: String) {
        taskRenameDebounceTask?.cancel()
        taskRenameDebounceTask = nil
        pendingTaskRename = nil
        draftFlow.taskBindings.removeAll { $0.elementID == elementID }
        draftFlow.updatedAt = Date()
        if selection.elementID == elementID {
            selection = .empty
        }
        taskConfigurationNodeID = nil
        showDeleteTaskConfirmation = false
        pendingElementRemoval = BPMNPendingElementRemoval(elementID: elementID, requestID: UUID())
    }

    private func requestBinding(for elementID: String) -> Binding<UUID?> {
        Binding(
            get: {
                guard let binding = draftFlow.taskBindings.first(where: { $0.elementID == elementID }) else {
                    return nil
                }
                return binding.resolvedRequestID(matching: availableRequests)
            },
            set: { newRequestID in
                let reference = newRequestID.flatMap { id in
                    availableRequests.first { $0.requestID == id }
                }
                upsertTaskBinding(elementID: elementID, requestID: newRequestID, reference: reference)
            }
        )
    }

    private func requestLabel(for reference: WorkspaceFlowRequestReference) -> String {
        "\(reference.collectionName) / \(reference.requestName) [\(reference.transportKind.displayName)]"
    }

    private var executionTraceText: String? {
        if isFlowExecutionLive {
            let liveTrace = displayLiveLogs.joined(separator: "\n")
            return liveTrace.isEmpty ? nil : liveTrace
        }

        if !displayLiveLogs.isEmpty {
            return displayLiveLogs.joined(separator: "\n")
        }

        guard let effectiveLastRunResult else { return nil }
        let trace = effectiveLastRunResult.logs.joined(separator: "\n")
        return trace.isEmpty ? nil : trace
    }

    private func copyExecutionTrace() {
        guard let executionTraceText else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(executionTraceText, forType: .string)
        localStatusMessage = "Execution trace copied."
    }

    private func upsertTaskBinding(
        elementID: String,
        requestID: UUID?,
        reference: WorkspaceFlowRequestReference? = nil
    ) {
        if let bindingIndex = draftFlow.taskBindings.firstIndex(where: { $0.elementID == elementID }) {
            if let requestID {
                draftFlow.taskBindings[bindingIndex].requestID = requestID
                if let reference {
                    draftFlow.taskBindings[bindingIndex].boundCollectionName = reference.collectionName
                    draftFlow.taskBindings[bindingIndex].boundRequestName = reference.requestName
                    draftFlow.taskBindings[bindingIndex].boundTransportKind = reference.transportKind
                }
            } else {
                draftFlow.taskBindings.remove(at: bindingIndex)
            }
        } else if let requestID {
            draftFlow.taskBindings.append(
                WorkspaceFlowTaskBinding(
                    elementID: elementID,
                    requestID: requestID,
                    boundCollectionName: reference?.collectionName,
                    boundRequestName: reference?.requestName,
                    boundTransportKind: reference?.transportKind
                )
            )
        }

        draftFlow.updatedAt = Date()
        refreshValidation()
    }

    /// Resolves each binding to this workspace (UUID + portable names). Needed after Git sync or when `requestID` from another machine does not exist locally.
    private func reconcileTaskBindingsWithAvailableRequests() {
        var bindings = draftFlow.taskBindings
        var changed = false
        for index in bindings.indices {
            var binding = bindings[index]
            guard let resolved = binding.resolvedRequestID(matching: availableRequests) else {
                continue
            }
            if binding.requestID != resolved {
                binding.requestID = resolved
                changed = true
            }
            if let ref = availableRequests.first(where: { $0.requestID == resolved }) {
                if binding.boundCollectionName != ref.collectionName
                    || binding.boundRequestName != ref.requestName
                    || binding.boundTransportKind != ref.transportKind {
                    binding.boundCollectionName = ref.collectionName
                    binding.boundRequestName = ref.requestName
                    binding.boundTransportKind = ref.transportKind
                    changed = true
                }
            }
            bindings[index] = binding
        }
        if changed {
            draftFlow.taskBindings = bindings
            draftFlow.updatedAt = Date()
        }
    }

    private func sanitizeBindings() {
        if graph.nodes.isEmpty,
           !draftFlow.taskBindings.isEmpty,
           !draftFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let validTaskIDs = Set(graph.nodes.filter { $0.nodeType == .task }.map(\.id))
        let previousElementID = selection.elementID

        draftFlow.taskBindings.removeAll { !validTaskIDs.contains($0.elementID) }

        if let previousElementID, !graph.nodes.contains(where: { $0.id == previousElementID }) {
            selection = .empty
        }
    }

    private func currentFlowSnapshot() -> WorkspaceFlowDefinition {
        var flow = draftFlow
        flow.name = flow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let graphHasTaskNodes = graph.nodes.contains(where: { $0.nodeType == .task })
        flow.taskBindings = flow.taskBindings
            .filter { binding in
                guard graphHasTaskNodes else {
                    return true
                }
                return graph.nodes.contains(where: { $0.nodeType == .task && $0.id == binding.elementID })
            }
            .map { binding in
                var normalized = binding
                if let resolved = normalized.resolvedRequestID(matching: availableRequests) {
                    normalized.requestID = resolved
                    if let ref = availableRequests.first(where: { $0.requestID == resolved }) {
                        normalized.boundCollectionName = ref.collectionName
                        normalized.boundRequestName = ref.requestName
                        normalized.boundTransportKind = ref.transportKind
                    }
                }
                return normalized
            }
        flow.updatedAt = Date()
        return flow
    }

    private func refreshValidation() {
        guard !graph.nodes.isEmpty else {
            validation = WorkspaceFlowValidationResult()
            validationTabAttention = .none
            return
        }
        validation = viewModel.validateFlow(currentFlowSnapshot(), graph: graph)
        applySilentValidationAttention()
    }

    private func applySilentValidationAttention() {
        if validation.issues.isEmpty {
            validationTabAttention = .none
        } else {
            validationTabAttention = selectedEditorTab == .validation ? .none : .negative
        }
    }

    private func validateAndShowPanel() {
        refreshValidation()
        if selectedEditorTab == .validation {
            validationTabAttention = .none
        } else {
            validationTabAttention = validation.isValid ? .positive : .negative
        }
    }

    private func saveFlow() {
        guard canSave else { return }

        let flow = currentFlowSnapshot()
        if viewModel.updateFlow(flow) {
            draftFlow = flow
            localStatusMessage = "Flow saved."
        }
    }

    private func beginBackgroundFlowRun() {
        guard !isFlowExecutionLive else { return }
        do {
            try viewModel.startBackgroundFlowExecution(currentFlowSnapshot(), graph: graph)
            if selectedEditorTab != .running {
                runningTabAttention = .positive
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
            if selectedEditorTab != .running {
                runningTabAttention = .negative
            }
        }
    }

    private func requestDismissFlowEditor() {
        if isFlowExecutionLive {
            showRunInFlightCloseConfirmation = true
        } else {
            dismiss()
        }
    }

    private func executionResultIndicatesSuccess(_ result: WorkspaceFlowExecutionResult) -> Bool {
        result.taskResults.allSatisfy { $0.statusCode < 400 }
    }

    private func resetDiagram() {
        viewModel.cancelFlowExecution(flowID: draftFlow.id)
        viewModel.removeFlowRunSessionIfNotRunning(flowID: draftFlow.id)
        structuredBatchRunTask?.cancel()
        structuredBatchRunTask = nil
        liveRunLogs = []
        viewModel.clearWorkspaceFlowBatchCaseTranscripts(for: draftFlow.id)
        batchRunLastLogInspectTarget = nil
        draftFlow.bpmnXML = ""
        draftFlow.taskBindings = []
        draftFlow.diagramViewport = nil
        graph = WorkspaceFlowGraphSnapshot()
        selection = .empty
        lastRunResult = nil
        validation = WorkspaceFlowValidationResult()
        draftFlow.batchRunCases = []
        validationTabAttention = .none
        runningTabAttention = .none
        selectedEditorTab = .diagram
        localStatusMessage = "Created a fresh BPMN diagram."
        editorReloadToken = UUID()
    }

    private func importFlowDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType.xml,
            UTType(filenameExtension: "bpmn"),
            UTType.json,
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            switch url.pathExtension.lowercased() {
            case "json":
                let imported = try JSONDecoder().decode(WorkspaceFlowPortableDocument.self, from: data)
                draftFlow.bpmnXML = imported.flow.bpmnXML
                draftFlow.taskBindings = imported.flow.taskBindings
                draftFlow.diagramViewport = imported.flow.diagramViewport
                viewModel.clearWorkspaceFlowBatchCaseTranscripts(for: draftFlow.id)
                draftFlow.batchRunCases = imported.flow.batchRunCases ?? []
                graph = imported.graph
                selection = .empty
                localStatusMessage = "Imported flow JSON from \(url.lastPathComponent)."

            default:
                draftFlow.bpmnXML = String(decoding: data, as: UTF8.self)
                draftFlow.taskBindings = []
                draftFlow.diagramViewport = nil
                viewModel.clearWorkspaceFlowBatchCaseTranscripts(for: draftFlow.id)
                graph = WorkspaceFlowGraphSnapshot()
                selection = .empty
                localStatusMessage = "Imported BPMN XML from \(url.lastPathComponent)."
            }
        } catch {
            viewModel.errorMessage = "Failed to import flow: \(error.localizedDescription)"
        }
    }

    private func exportXML() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.xml, UTType(filenameExtension: "bpmn")].compactMap { $0 }
        savePanel.nameFieldStringValue = "\(draftFlow.name).bpmn"

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return
        }

        do {
            let xml = draftFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = xml.data(using: .utf8) else {
                throw AppError.invalidDocument("The BPMN XML could not be encoded as UTF-8.")
            }
            try data.write(to: url)
            localStatusMessage = "Exported BPMN XML to \(url.lastPathComponent)."
        } catch {
            viewModel.errorMessage = "Failed to export BPMN XML: \(error.localizedDescription)"
        }
    }

    private func exportJSON() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.json]
        savePanel.nameFieldStringValue = "\(draftFlow.name).json"

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return
        }

        do {
            let payload = WorkspaceFlowPortableDocument(
                flow: currentFlowSnapshot(),
                graph: graph
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url)
            localStatusMessage = "Exported flow JSON to \(url.lastPathComponent)."
        } catch {
            viewModel.errorMessage = "Failed to export flow JSON: \(error.localizedDescription)"
        }
    }
}

/// One log line in the Running tab: chip by kind + readable block (print vs HTTP vs flow vs tests).
private struct WorkspaceFlowRunLogStyledRow: View {
    let text: String

    private var kind: WorkspaceFlowRunLogVisualKind {
        WorkspaceFlowRunLogClassifier.visualKind(for: text)
    }

    var body: some View {
        Group {
            if let inline = WorkspaceFlowInlineImageLogLine.parse(text) {
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.pillLabel(for: .inlineImage))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.pillForeground(for: .inlineImage))
                        .frame(width: 76, alignment: .center)
                        .padding(.vertical, 5)
                        .background(Self.pillBackground(for: .inlineImage), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(inline.caption)
                            .font(.system(size: 12, weight: .semibold, design: .default))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        if let nsImage = NSImage(contentsOf: inline.fileURL) {
                            Image(nsImage: nsImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 320, maxHeight: 320)
                                .padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text("No se pudo cargar el PNG (puede haberse borrado del temporal).")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(PostmanTheme.salmon)
                        }

                        Text(inline.fileURL.path)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(PostmanTheme.textSecondary.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Self.bodyBackground(for: .inlineImage), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Self.bodyBorder(for: .inlineImage), lineWidth: 1)
                    )
                }
            } else if let md = MarkdownLogFormatting.attributedLogLine(text) {
                Text(md)
                    .font(.system(size: 13))
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(PostmanTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(PostmanTheme.border.opacity(0.65), lineWidth: 1)
                    )
                    .textSelection(.enabled)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.pillLabel(for: kind))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.pillForeground(for: kind))
                        .frame(width: 76, alignment: .center)
                        .padding(.vertical, 5)
                        .background(Self.pillBackground(for: kind), in: RoundedRectangle(cornerRadius: 6))

                    Text(text)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Self.bodyForeground(for: kind))
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Self.bodyBackground(for: kind), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Self.bodyBorder(for: kind), lineWidth: 1)
                        )
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private static func pillLabel(for kind: WorkspaceFlowRunLogVisualKind) -> String {
        switch kind {
        case .taskBoundary: return "TAREA"
        case .flowStep: return "FLUJO"
        case .httpRequest: return "PETICIÓN"
        case .httpResponse: return "RESPUESTA"
        case .assertion: return "TEST"
        case .variableChange: return "VARIABLE"
        case .diagnostic: return "AVISO"
        case .inlineImage: return "IMAGEN"
        case .consolePrint: return "PRINT"
        }
    }

    private static func pillForeground(for kind: WorkspaceFlowRunLogVisualKind) -> Color {
        switch kind {
        case .taskBoundary: return PostmanTheme.textPrimary
        case .flowStep: return Color.white.opacity(0.92)
        case .httpRequest, .httpResponse, .assertion, .diagnostic: return Color.white.opacity(0.95)
        case .variableChange: return Color.white.opacity(0.92)
        case .inlineImage: return Color.white.opacity(0.95)
        case .consolePrint: return Color.white.opacity(0.88)
        }
    }

    private static func pillBackground(for kind: WorkspaceFlowRunLogVisualKind) -> Color {
        switch kind {
        case .taskBoundary: return PostmanTheme.accent.opacity(0.45)
        case .flowStep: return Color.white.opacity(0.12)
        case .httpRequest: return PostmanTheme.orange.opacity(0.42)
        case .httpResponse: return PostmanTheme.green.opacity(0.38)
        case .assertion: return Color(red: 0.55, green: 0.38, blue: 0.95).opacity(0.42)
        case .variableChange: return Color(red: 0.25, green: 0.72, blue: 0.82).opacity(0.38)
        case .diagnostic: return PostmanTheme.salmon.opacity(0.42)
        case .inlineImage: return Color(red: 0.35, green: 0.75, blue: 0.55).opacity(0.42)
        case .consolePrint: return Color.white.opacity(0.1)
        }
    }

    private static func bodyForeground(for kind: WorkspaceFlowRunLogVisualKind) -> Color {
        switch kind {
        case .diagnostic: return PostmanTheme.textPrimary
        case .httpResponse, .httpRequest: return PostmanTheme.textPrimary.opacity(0.95)
        case .inlineImage: return PostmanTheme.textPrimary.opacity(0.95)
        default: return PostmanTheme.textSecondary.opacity(0.98)
        }
    }

    private static func bodyBackground(for kind: WorkspaceFlowRunLogVisualKind) -> Color {
        switch kind {
        case .taskBoundary: return PostmanTheme.accent.opacity(0.08)
        case .flowStep: return Color.white.opacity(0.04)
        case .httpRequest: return PostmanTheme.orange.opacity(0.06)
        case .httpResponse: return PostmanTheme.green.opacity(0.06)
        case .assertion: return Color(red: 0.55, green: 0.38, blue: 0.95).opacity(0.07)
        case .variableChange: return Color(red: 0.25, green: 0.72, blue: 0.82).opacity(0.07)
        case .diagnostic: return PostmanTheme.salmon.opacity(0.1)
        case .inlineImage: return Color(red: 0.35, green: 0.75, blue: 0.55).opacity(0.12)
        case .consolePrint: return PostmanTheme.panel.opacity(0.65)
        }
    }

    private static func bodyBorder(for kind: WorkspaceFlowRunLogVisualKind) -> Color {
        switch kind {
        case .taskBoundary: return PostmanTheme.accent.opacity(0.22)
        case .httpRequest: return PostmanTheme.orange.opacity(0.2)
        case .httpResponse: return PostmanTheme.green.opacity(0.2)
        case .assertion: return Color(red: 0.55, green: 0.38, blue: 0.95).opacity(0.22)
        case .variableChange: return Color(red: 0.25, green: 0.72, blue: 0.82).opacity(0.2)
        case .diagnostic: return PostmanTheme.salmon.opacity(0.28)
        case .inlineImage: return Color(red: 0.35, green: 0.75, blue: 0.55).opacity(0.35)
        default: return PostmanTheme.border
        }
    }
}

private struct TaskConfigurationTarget: Identifiable {
    let id: String
}
