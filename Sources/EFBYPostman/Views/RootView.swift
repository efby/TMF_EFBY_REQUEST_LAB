import EfbyPresentation
import AppKit
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var isImporting = false
    @State private var hasAutoPromptedForWorkingDirectory = false
    @State private var isCreatingWorkspace = false
    @State private var isConnectingGit = false

    var body: some View {
        ZStack {
            PostmanTheme.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                TopChromeBar(
                    workspaceName: viewModel.activeWorkspaceDescription,
                    workspaceNames: viewModel.availableWorkspaceNames,
                    onSelectWorkspace: viewModel.selectWorkspace(named:),
                    onRefresh: { viewModel.refreshSharedData(forceInfoMessage: true) },
                    onCreateWorkspace: { isCreatingWorkspace = true },
                    onConnectGit: { isConnectingGit = true },
                    onSelectRepo: { selectSharedRepoDirectory() },
                    hasRunningFlows: viewModel.hasAnyFlowExecutionInFlight,
                    onCancelAllRunningFlows: { viewModel.cancelAllRunningFlowExecutions() }
                )

                HStack(spacing: 0) {
                    SidebarPane(
                        viewModel: viewModel,
                        onImport: { isImporting = true },
                        onSelectRepository: { selectSharedRepoDirectory() }
                    )
                        .frame(width: 330)

                    Divider()
                        .overlay(PostmanTheme.border)

                    WorkspacePane(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if viewModel.didFinishInitialWorkspaceLoad && viewModel.requiresWorkingDirectorySelection {
                workingDirectoryRequiredOverlay
            }

            if let errorMessage = viewModel.errorMessage {
                errorOverlay(message: errorMessage)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: viewModel.didFinishInitialWorkspaceLoad) { _, didFinish in
            guard didFinish else { return }
            viewModel.refreshSharedData(forceInfoMessage: false)
            guard viewModel.requiresWorkingDirectorySelection,
                  !hasAutoPromptedForWorkingDirectory else {
                return
            }
            hasAutoPromptedForWorkingDirectory = true
            DispatchQueue.main.async {
                selectSharedRepoDirectory()
            }
        }
        .sheet(isPresented: $isCreatingWorkspace) {
            RenameSheet(
                title: "New Workspace",
                initialValue: ""
            ) { newName in
                viewModel.createWorkspace(named: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isConnectingGit) {
            TextInputSheet(
                title: "Connect Git Repository",
                placeholder: "https://repositoriogit.org/workspace/repositorio/src/main/ or git clone git@bitbucket.org:repositorio/repositorio.git",
                initialValue: viewModel.gitRemoteDescription ?? "",
                isProcessing: viewModel.isGitBusy && viewModel.gitBusyOperation == "connect",
                processingTitle: "Connecting...",
                output: viewModel.gitOutput,
                autoDismissOnComplete: false
            ) { value in
                viewModel.connectGitRepository(using: value)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $viewModel.gitCredentialPrompt) { prompt in
            GitCredentialsSheet(
                prompt: prompt,
                onCancel: { viewModel.cancelGitCredentialPrompt() }
            ) { mode, username, secret in
                viewModel.submitGitCredentials(mode: mode, username: username, secret: secret)
            }
            .preferredColorScheme(.dark)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await viewModel.importDocument(from: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Info",
            isPresented: Binding(
                get: { viewModel.infoMessage != nil },
                set: { if !$0 { viewModel.dismissInfoMessageBanner() } }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    viewModel.dismissInfoMessageBanner()
                }
            },
            message: {
                Text(viewModel.infoMessage ?? "")
            }
        )
    }

    private func selectSharedRepoDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Repository"
        panel.message = "Select an empty folder to start, or choose an existing Git repository / previous workdir. Workspaces will be managed as folders inside this directory."
        panel.directoryURL = viewModel.sharedRepositoryURL?.deletingLastPathComponent()

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.configureSharedCollectionsDirectory(url)
            if viewModel.requiresWorkingDirectorySelection {
                hasAutoPromptedForWorkingDirectory = false
            }
        }
    }

    private var workingDirectoryRequiredOverlay: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("Select Working Directory")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)

                Text("Choose an empty folder to start, or select an existing Git repository / previous workdir. If it has no workspace folders yet, the app will create a default workspace automatically.")
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button {
                        selectSharedRepoDirectory()
                    } label: {
                        Text("Select Repository")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(PostmanTheme.border))
        }
    }

    private func errorOverlay(message: String) -> some View {
        let availableWidth = max(520, (NSScreen.main?.visibleFrame.width ?? 880) - 120)

        return ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Error")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Spacer()

                    Button {
                        viewModel.dismissErrorMessageBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(PostmanTheme.panel, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cerrar error")
                }

                ScrollView {
                    Text(message)
                        .foregroundStyle(PostmanTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 180, maxHeight: 520)
                .padding(16)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(PostmanTheme.border))

                HStack {
                    Spacer()
                    Button {
                        viewModel.dismissErrorMessageBanner()
                    } label: {
                        Text("Cerrar")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(width: min(760, availableWidth))
            .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(PostmanTheme.border))
            .shadow(color: .black.opacity(0.35), radius: 28, y: 18)
        }
    }
}

enum PostmanTheme {
    static let appBackground = Color(nsColor: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    static let panel = Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1))
    static let panelElevated = Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1))
    static let sidebar = Color(nsColor: NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    static let tab = Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.19, alpha: 1))
    static let activeTab = Color(nsColor: NSColor(calibratedRed: 0.21, green: 0.21, blue: 0.22, alpha: 1))
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.20, green: 0.43, blue: 0.83, alpha: 1))
    static let green = Color(nsColor: NSColor(calibratedRed: 0.23, green: 0.75, blue: 0.47, alpha: 1))
    static let orange = Color(nsColor: NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.22, alpha: 1))
    static let salmon = Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.53, blue: 0.47, alpha: 1))
    static let warning = Color(nsColor: NSColor(calibratedRed: 0.36, green: 0.26, blue: 0.05, alpha: 1))
    static let border = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.63)
}

private extension GitProvider {
    var displayLabel: String {
        displayName
    }
}

private struct TopChromeBar: View {
    let workspaceName: String
    let workspaceNames: [String]
    let onSelectWorkspace: (String) -> Void
    let onRefresh: () -> Void
    let onCreateWorkspace: () -> Void
    let onConnectGit: () -> Void
    let onSelectRepo: () -> Void
    let hasRunningFlows: Bool
    let onCancelAllRunningFlows: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(PostmanTheme.textSecondary)
                Menu {
                    ForEach(workspaceNames, id: \.self) { name in
                        Button(name) {
                            onSelectWorkspace(name)
                        }
                    }
                    Divider()
                    Button("New Workspace", action: onCreateWorkspace)
                } label: {
                    HStack(spacing: 6) {
                        Text(workspaceName)
                            .foregroundStyle(PostmanTheme.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
            }

            Spacer()

            iconButton("arrow.clockwise", action: onRefresh)

            stopAllFlowsButton

            Spacer()

            HStack(spacing: 10) {
                topButton("Workdir", action: onSelectRepo)
                topButton("Connect Git", action: onConnectGit)
                topButton("New Workspace", action: onCreateWorkspace)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(PostmanTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PostmanTheme.border)
                .frame(height: 1)
        }
    }

    private func topButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textPrimary)
        .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
    }

    private var stopAllFlowsButton: some View {
        Button(action: onCancelAllRunningFlows) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasRunningFlows ? PostmanTheme.salmon : PostmanTheme.textSecondary.opacity(0.35))
        .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        .disabled(!hasRunningFlows)
        .help("Cancelar todas las ejecuciones de flows en curso (segundo plano y pestaña Runs)")
    }
}

private struct SidebarPane: View {
    @ObservedObject var viewModel: MainViewModel
    let onImport: () -> Void
    let onSelectRepository: () -> Void
    @State private var editingUtility: WorkspaceScriptUtility?
    @State private var editingFlow: WorkspaceFlowDefinition?
    /// Nueva cada vez que se abre el editor desde cero (nil → flow). Evita que SwiftUI reutilice `WorkspaceFlowEditor` y deje `@State` desincronizado con la sesión en `MainViewModel` al volver tras segundo plano.
    @State private var flowEditorInstanceID = UUID()
    @State private var renamingUtility: WorkspaceScriptUtility?
    @State private var renamingFlow: WorkspaceFlowDefinition?
    @State private var cloningFlow: WorkspaceFlowDefinition?
    @State private var renamingCollection: CollectionModel?
    @State private var cloningCollection: CollectionModel?
    @State private var renamingRequest: RenameRequestTarget?
    @State private var utilityPendingDeletion: WorkspaceScriptUtility?
    @State private var flowPendingDeletion: WorkspaceFlowDefinition?
    @State private var collectionPendingDeletion: CollectionModel?
    @State private var isCreatingUtility = false
    @State private var isCreatingFlow = false
    @State private var isCreatingCollection = false
    @State private var isUtilitiesExpanded = true
    @State private var isFlowsExpanded = true
    @State private var isCollectionsExpanded = true
    @State private var isHistoryExpanded = true
    @State private var isShowingSharedStorageModal = false
    @State private var sharedStorageInitialAction: SharedStorageQuickAction?

    var body: some View {
        VStack(spacing: 0) {
            SidebarToolbar(viewModel: viewModel, onImport: onImport)

            fixedSection(
                title: "SHARED STORAGE",
                trailing: {
                    Button {
                        openSharedStorageModal()
                    } label: {
                        Text("Configurar")
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.accent)
                    .font(.caption)
                }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    sharedInfoRow("Repo", value: viewModel.sharedCollectionsDirectoryDescription)
                    sharedInfoRow("Remote", value: viewModel.gitRemoteDescription ?? "Not configured")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accordionSection(
                        title: "FLOWS",
                        isExpanded: $isFlowsExpanded,
                        trailing: {
                            HStack(spacing: 4) {
                                Button {
                                    viewModel.cancelAllRunningFlowExecutions()
                                } label: {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(
                                            viewModel.hasAnyFlowExecutionInFlight
                                                ? PostmanTheme.salmon
                                                : PostmanTheme.textSecondary.opacity(0.35)
                                        )
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!viewModel.hasAnyFlowExecutionInFlight)
                                .help("Detener todos los flows en ejecución (segundo plano y runs en el editor)")

                                Button {
                                    isCreatingFlow = true
                                } label: {
                                    Image(systemName: "plus")
                                        .foregroundStyle(PostmanTheme.accent)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            if viewModel.workspace.flows.isEmpty {
                                subtleLabel("No flows")
                            }

                            ForEach(viewModel.workspace.flows) { flow in
                                HStack(spacing: 0) {
                                    Button {
                                        presentFlowEditor(flow)
                                    } label: {
                                        FlowRow(
                                            flow: flow,
                                            isFlowRunning: viewModel.hasActiveFlowRun(for: flow.id)
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    Menu {
                                        Button("Open") {
                                            presentFlowEditor(flow)
                                        }
                                        Button("Rename") {
                                            renamingFlow = flow
                                        }
                                        Button("Clone Flow") {
                                            cloningFlow = flow
                                        }
                                        Button("Delete", role: .destructive) {
                                            flowPendingDeletion = flow
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundStyle(PostmanTheme.textSecondary)
                                            .frame(width: 28, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                                .contextMenu {
                                    Button("Open") {
                                        presentFlowEditor(flow)
                                    }
                                    Button("Rename") {
                                        renamingFlow = flow
                                    }
                                    Button("Clone Flow") {
                                        cloningFlow = flow
                                    }
                                    Button("Delete", role: .destructive) {
                                        flowPendingDeletion = flow
                                    }
                                }
                            }
                        }
                    }

                    accordionSection(
                        title: "COLLECTIONS",
                        isExpanded: $isCollectionsExpanded,
                        trailing: {
                            Button {
                                isCreatingCollection = true
                            } label: {
                                Image(systemName: "plus")
                                    .foregroundStyle(PostmanTheme.accent)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.filteredCollections().isEmpty {
                                subtleLabel("No collections")
                            }
                            ForEach(viewModel.filteredCollections()) { collection in
                                CollectionTreeView(
                                    collection: collection,
                                    selectedNodeID: viewModel.currentTab?.sourceNodeID,
                                    onOpenRequest: { node in
                                        Task {
                                            await viewModel.open(request: node, in: collection)
                                        }
                                    },
                                    onNewRequest: {
                                        viewModel.newRequest(in: collection)
                                    },
                                    onCloneCollection: {
                                        cloningCollection = collection
                                    },
                                    onRenameCollection: {
                                        renamingCollection = collection
                                    },
                                    onDeleteCollection: {
                                        collectionPendingDeletion = collection
                                    },
                                    onRenameRequest: { node in
                                        renamingRequest = RenameRequestTarget(collection: collection, node: node)
                                    },
                                    onDuplicateRequest: { node in
                                        viewModel.duplicateRequestNode(node, in: collection)
                                    },
                                    onDeleteRequest: { node in
                                        viewModel.deleteRequestNode(node, from: collection)
                                    }
                                )
                            }
                        }
                    }

                    accordionSection(
                        title: "UTILITIES",
                        isExpanded: $isUtilitiesExpanded,
                        trailing: {
                            Button {
                                isCreatingUtility = true
                            } label: {
                                Image(systemName: "plus")
                                    .foregroundStyle(PostmanTheme.accent)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            if viewModel.workspace.utilityLibraries.isEmpty {
                                subtleLabel("No utilities")
                            }

                            ForEach(viewModel.workspace.utilityLibraries) { utility in
                                Button {
                                    editingUtility = utility
                                } label: {
                                    UtilityLibraryRow(utility: utility)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Edit") {
                                        editingUtility = utility
                                    }
                                    Button("Rename") {
                                        renamingUtility = utility
                                    }
                                    Button(utility.isEnabled ? "Disable" : "Enable") {
                                        var updated = utility
                                        updated.isEnabled.toggle()
                                        viewModel.updateUtilityLibrary(updated)
                                    }
                                    Button("Delete", role: .destructive) {
                                        utilityPendingDeletion = utility
                                    }
                                }
                            }
                        }
                    }

                    accordionSection(
                        title: "HISTORY",
                        isExpanded: $isHistoryExpanded,
                        trailing: {
                            Button {
                                viewModel.clearHistory()
                            } label: {
                                Text("Clear")
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PostmanTheme.accent)
                            .font(.caption)
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.workspace.history.prefix(12)) { entry in
                                Button {
                                    viewModel.open(history: entry)
                                } label: {
                                    HStack {
                                        requestPill(entry.request)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.request.name)
                                                .lineLimit(1)
                                                .foregroundStyle(PostmanTheme.textPrimary)
                                            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                                .font(.caption2)
                                                .foregroundStyle(PostmanTheme.textSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        viewModel.deleteHistoryEntry(entry)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PostmanTheme.sidebar)
        .sheet(isPresented: $isCreatingUtility) {
            RenameSheet(
                title: "New Utility Library",
                initialValue: viewModel.suggestedUtilityLibraryName(),
                validationMessage: { value in
                    viewModel.utilityLibraryNameValidationMessage(value)
                }
            ) { newName in
                editingUtility = viewModel.addUtilityLibrary(named: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isCreatingFlow) {
            RenameSheet(
                title: "New Flow",
                initialValue: viewModel.suggestedFlowName(),
                validationMessage: { value in
                    viewModel.flowNameValidationMessage(value)
                }
            ) { newName in
                if let created = viewModel.addFlow(named: newName) {
                    presentFlowEditor(created)
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $editingUtility) { utility in
            WorkspaceUtilityEditor(
                utility: utility,
                workspaceUtilities: viewModel.workspace.utilityLibraries,
                nameValidationMessage: { name, excludedID in
                    viewModel.utilityLibraryNameValidationMessage(name, excluding: excludedID)
                },
                sourceValidationMessage: { source, excludedID in
                    viewModel.utilityLibrarySourceValidationMessage(source, excluding: excludedID)
                }
            ) { updated in
                let didSave = viewModel.updateUtilityLibrary(updated)
                if didSave {
                    editingUtility = updated
                }
                return didSave
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $editingFlow) { flow in
            WorkspaceFlowEditor(flow: flow, viewModel: viewModel)
                .id(flowEditorInstanceID)
                .interactiveDismissDisabled(true)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isCreatingCollection) {
            RenameSheet(
                title: "New Collection",
                initialValue: viewModel.suggestedCollectionName()
            ) { newName in
                viewModel.addCollection(named: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isShowingSharedStorageModal) {
            SharedStorageSheet(
                viewModel: viewModel,
                initialAction: sharedStorageInitialAction,
                onSelectRepository: onSelectRepository
            )
            .preferredColorScheme(.dark)
        }
        .sheet(item: $renamingCollection) { collection in
            RenameSheet(
                title: "Rename Collection",
                initialValue: collection.info.name
            ) { newName in
                viewModel.renameCollection(collection, to: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $renamingUtility) { utility in
            RenameSheet(
                title: "Rename Utility Library",
                initialValue: utility.name,
                validationMessage: { value in
                    viewModel.utilityLibraryNameValidationMessage(value, excluding: utility.id)
                }
            ) { newName in
                viewModel.renameUtilityLibrary(utility, to: newName)
                if editingUtility?.id == utility.id,
                   let updated = viewModel.workspace.utilityLibraries.first(where: { $0.id == utility.id }) {
                    editingUtility = updated
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $renamingFlow) { flow in
            RenameSheet(
                title: "Rename Flow",
                initialValue: flow.name,
                validationMessage: { value in
                    viewModel.flowNameValidationMessage(value, excluding: flow.id)
                }
            ) { newName in
                viewModel.renameFlow(flow, to: newName)
                if editingFlow?.id == flow.id,
                   let updated = viewModel.workspace.flows.first(where: { $0.id == flow.id }) {
                    editingFlow = updated
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $cloningFlow) { flow in
            RenameSheet(
                title: "Clone Flow",
                initialValue: viewModel.suggestedFlowCloneName(for: flow),
                validationMessage: { value in
                    viewModel.flowNameValidationMessage(value)
                }
            ) { newName in
                _ = viewModel.cloneFlow(flow, named: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $cloningCollection) { collection in
            RenameSheet(
                title: "Clone Collection",
                initialValue: viewModel.suggestedCollectionCloneName(for: collection),
                validationMessage: { value in
                    viewModel.collectionNameValidationMessage(value)
                }
            ) { newName in
                viewModel.duplicateCollection(collection, named: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $renamingRequest) { target in
            RenameSheet(
                title: "Rename Request",
                initialValue: target.node.name
            ) { newName in
                viewModel.renameRequestNode(target.node, in: target.collection, to: newName)
            }
            .preferredColorScheme(.dark)
        }
        .alert(
            "Delete Utility Library",
            isPresented: Binding(
                get: { utilityPendingDeletion != nil },
                set: { if !$0 { utilityPendingDeletion = nil } }
            ),
            presenting: utilityPendingDeletion
        ) { utility in
            Button("Delete", role: .destructive) {
                viewModel.deleteUtilityLibrary(utility)
                if editingUtility?.id == utility.id {
                    editingUtility = nil
                }
                utilityPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                utilityPendingDeletion = nil
            }
        } message: { utility in
            Text("Are you sure you want to delete the utility library '\(utility.name)'?")
        }
        .alert(
            "Delete Flow",
            isPresented: Binding(
                get: { flowPendingDeletion != nil },
                set: { if !$0 { flowPendingDeletion = nil } }
            ),
            presenting: flowPendingDeletion
        ) { flow in
            Button("Delete", role: .destructive) {
                viewModel.deleteFlow(flow)
                if editingFlow?.id == flow.id {
                    editingFlow = nil
                }
                flowPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                flowPendingDeletion = nil
            }
        } message: { flow in
            Text("Are you sure you want to delete the flow '\(flow.name)'?")
        }
        .alert(
            "Delete Collection",
            isPresented: Binding(
                get: { collectionPendingDeletion != nil },
                set: { if !$0 { collectionPendingDeletion = nil } }
            ),
            presenting: collectionPendingDeletion
        ) { collection in
            Button("Delete", role: .destructive) {
                viewModel.deleteCollection(collection)
                collectionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                collectionPendingDeletion = nil
            }
        } message: { collection in
            Text("Are you sure you want to delete the collection '\(collection.info.name)'?")
        }
    }

    private func openSharedStorageModal(_ action: SharedStorageQuickAction? = nil) {
        sharedStorageInitialAction = action
        isShowingSharedStorageModal = true
    }

    private func presentFlowEditor(_ flow: WorkspaceFlowDefinition) {
        flowEditorInstanceID = UUID()
        editingFlow = flow
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .kerning(0.8)
            .foregroundStyle(PostmanTheme.textSecondary)
            .padding(.horizontal, 8)
    }

    private func accordionSection<Content: View, Trailing: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)
                        sectionTitle(title)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                trailing()
            }

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    private func accordionSection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        accordionSection(
            title: title,
            isExpanded: isExpanded,
            trailing: { EmptyView() },
            content: content
        )
    }

    private func fixedSection<Content: View, Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle(title)
                Spacer()
                trailing()
            }

            content()
        }
    }

    private func subtleLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(PostmanTheme.textSecondary)
            .padding(.horizontal, 8)
    }

    private func sharedInfoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.horizontal, 8)
    }

    private func compactAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textPrimary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
    }
}

private struct FlowRow: View {
    let flow: WorkspaceFlowDefinition
    var isFlowRunning: Bool = false

    private var validationColor: Color {
        flow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PostmanTheme.textSecondary.opacity(0.55) : PostmanTheme.green
    }

    private var validationText: String {
        if flow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No BPMN diagram saved yet"
        }
        return "\(flow.taskBindings.count) task bindings configured"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PostmanTheme.panelElevated)
                    .frame(width: 28, height: 28)

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PostmanTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(flow.name)
                        .lineLimit(1)
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Circle()
                        .fill(validationColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Text(validationText)
                    .font(.caption2)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isFlowRunning {
                Text("Running")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PostmanTheme.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UtilityLibraryRow: View {
    let utility: WorkspaceScriptUtility

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PostmanTheme.panelElevated)
                    .frame(width: 28, height: 28)

                Image(systemName: "curlybraces.square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(utility.isEnabled ? PostmanTheme.accent : PostmanTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(utility.name)
                        .lineLimit(1)
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Circle()
                        .fill(utility.isEnabled ? PostmanTheme.green : PostmanTheme.textSecondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Text(utility.isEnabled ? "JavaScript utility available in all scripts" : "Disabled for this workspace")
                    .font(.caption2)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum SharedStorageQuickAction {
    case repo
    case newWorkspace
    case connectGit
    case status
    case pull
    case push
}

private struct SharedStorageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: MainViewModel
    let initialAction: SharedStorageQuickAction?
    let onSelectRepository: () -> Void

    @State private var isCreatingWorkspace = false
    @State private var isConnectingGit = false
    @State private var hasTriggeredInitialAction = false
    private let gitOutputBottomAnchor = "git-output-bottom-anchor"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shared Storage")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)

                Spacer()

                HStack(spacing: 10) {
                    toolbarLink("Repo", action: handleRepo)
                    toolbarLink("New", action: { isCreatingWorkspace = true })
                    toolbarLink("Git", action: { isConnectingGit = true })
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(PostmanTheme.border)

            VStack(alignment: .leading, spacing: 16) {
                sharedInfoRow("Repo", value: viewModel.sharedCollectionsDirectoryDescription)
                sharedInfoRow("Workspace", value: viewModel.activeWorkspaceDescription)
                sharedInfoRow("Remote", value: viewModel.gitRemoteDescription ?? "Not configured")

                if !viewModel.availableWorkspaceNames.isEmpty {
                    HStack(spacing: 10) {
                        Text("Workspace")
                            .foregroundStyle(PostmanTheme.textPrimary)

                        Picker("Workspace", selection: Binding(
                            get: { viewModel.activeWorkspaceDescription },
                            set: { viewModel.selectWorkspace(named: $0) }
                        )) {
                            ForEach(viewModel.availableWorkspaceNames, id: \.self) { workspaceName in
                                Text(workspaceName).tag(workspaceName)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                }

                HStack(spacing: 10) {
                    actionButton(
                        "Status",
                        isLoading: viewModel.gitBusyOperation == "status",
                        action: viewModel.gitStatus
                    )
                    actionButton(
                        "Update",
                        isLoading: viewModel.gitBusyOperation == "pull",
                        action: viewModel.gitPull
                    )
                    actionButton(
                        "Push",
                        isLoading: viewModel.gitBusyOperation == "push",
                        extraDisabled: !viewModel.canPushToSharedGit,
                        action: viewModel.gitCommitAndPush
                    )
                }

                if let reason = viewModel.gitPushDisabledReason, !viewModel.canPushToSharedGit {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !viewModel.gitMergeConflictPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Conflicts — choose a side per file")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)

                        ForEach(viewModel.gitMergeConflictPaths, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(PostmanTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .lineLimit(3)

                                HStack(spacing: 8) {
                                    Button("Keep local") {
                                        viewModel.gitResolveMergeConflict(path: path, keepLocal: true)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(viewModel.isGitBusy)

                                    Button("Keep remote") {
                                        viewModel.gitResolveMergeConflict(path: path, keepLocal: false)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(viewModel.isGitBusy)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        }

                        if viewModel.isSharedGitMergeInProgress {
                            Button("Abort merge") {
                                viewModel.gitAbortSharedMerge()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(viewModel.isGitBusy)
                        }
                    }
                }

                HStack {
                    Text("Output")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)

                    Spacer()

                    Button("Copy") {
                        copyGitOutput()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle((viewModel.gitOutput?.isEmpty == false) ? PostmanTheme.accent : PostmanTheme.textSecondary)
                    .disabled(viewModel.gitOutput?.isEmpty != false)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(viewModel.gitOutput?.isEmpty == false ? viewModel.gitOutput! : "No output yet.")
                                .font(.caption.monospaced())
                                .foregroundStyle(viewModel.gitOutput?.isEmpty == false ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)

                            Color.clear
                                .frame(height: 1)
                                .id(gitOutputBottomAnchor)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
                    .onAppear {
                        proxy.scrollTo(gitOutputBottomAnchor, anchor: .bottom)
                    }
                    .onChange(of: viewModel.gitOutput ?? "") { _, _ in
                        proxy.scrollTo(gitOutputBottomAnchor, anchor: .bottom)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(PostmanTheme.panelElevated)
        .sheet(isPresented: $isCreatingWorkspace) {
            RenameSheet(
                title: "New Workspace",
                initialValue: ""
            ) { newName in
                viewModel.createWorkspace(named: newName)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $isConnectingGit) {
            TextInputSheet(
                title: "Connect Git Repository",
                placeholder: "https://bitbucket.org/teamefby/postmanefby/src/main/ or git clone git@bitbucket.org:teamefby/postmanefby.git",
                initialValue: viewModel.gitRemoteDescription ?? "",
                isProcessing: viewModel.isGitBusy && viewModel.gitBusyOperation == "connect",
                processingTitle: "Connecting...",
                output: viewModel.gitOutput,
                autoDismissOnComplete: false
            ) { value in
                viewModel.connectGitRepository(using: value)
            }
            .preferredColorScheme(.dark)
        }
        .alert(
            "Local changes before Update",
            isPresented: Binding(
                get: { viewModel.gitPullRecoveryPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelGitPullRecoveryPrompt()
                    }
                }
            ),
            actions: {
                Button("Stash and Update") {
                    viewModel.confirmGitPullStashAndUpdate()
                }
                Button("Revert (destructive) and Update", role: .destructive) {
                    viewModel.confirmGitPullRecoverDeletedFiles()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.continueGitPullWithoutRecoveringDeletedFiles()
                }
            },
            message: {
                Text(gitPullRecoveryMessage)
            }
        )
        .onAppear {
            viewModel.refreshSharedGitPushAvailability()
            guard !hasTriggeredInitialAction else { return }
            hasTriggeredInitialAction = true
            DispatchQueue.main.async {
                triggerInitialAction()
            }
        }
    }

    private func handleRepo() {
        onSelectRepository()
        viewModel.refreshSharedData(forceInfoMessage: true)
    }

    private func copyGitOutput() {
        guard let output = viewModel.gitOutput, !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    private func triggerInitialAction() {
        guard let initialAction else { return }
        switch initialAction {
        case .repo:
            handleRepo()
        case .newWorkspace:
            isCreatingWorkspace = true
        case .connectGit:
            isConnectingGit = true
        case .status:
            viewModel.gitStatus()
        case .pull:
            viewModel.gitPull()
        case .push:
            viewModel.gitCommitAndPush()
        }
    }

    private var gitPullRecoveryMessage: String {
        guard let prompt = viewModel.gitPullRecoveryPrompt else {
            return "Git detected local changes before pull."
        }

        let preview = prompt.changedPaths.prefix(5).joined(separator: "\n")
        let suffix = prompt.changedPaths.count > 5 ? "\n..." : ""
        return """
        Git detected local changes (including untracked files) before merging remote updates.

        \(preview)\(suffix)

        Stash and Update saves your work in a Git stash, merges the remote, then reapplies your changes (you may need to resolve conflicts). Revert discards those local changes permanently. Cancel leaves the repository unchanged.
        """
    }

    private func toolbarLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.accent)
        .font(.caption)
    }

    private func actionButton(_ title: String, isLoading: Bool, extraDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PostmanTheme.textPrimary)
                }

                Text(title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textPrimary)
        .frame(height: 36)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
        .disabled(viewModel.isGitBusy || extraDisabled)
    }

    private func sharedInfoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

private struct SidebarToolbar: View {
    @ObservedObject var viewModel: MainViewModel
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    DarkTextInput(text: $viewModel.searchText, placeholder: "Search")
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Button {
                    onImport()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(PostmanTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Import")
            }
        }
        .padding(12)
        .background(PostmanTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PostmanTheme.border)
                .frame(height: 1)
        }
    }
}

private struct CollectionTreeView: View {
    let collection: CollectionModel
    let selectedNodeID: UUID?
    let onOpenRequest: (CollectionNode) -> Void
    let onNewRequest: () -> Void
    let onCloneCollection: () -> Void
    let onRenameCollection: () -> Void
    let onDeleteCollection: () -> Void
    let onRenameRequest: (CollectionNode) -> Void
    let onDuplicateRequest: (CollectionNode) -> Void
    let onDeleteRequest: (CollectionNode) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(collection.info.name)
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .font(.body.weight(.medium))
                Spacer()
                Button {
                    onNewRequest()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button("New Request", action: onNewRequest)
                    Button("Clone Collection", action: onCloneCollection)
                    Button("Rename Collection", action: onRenameCollection)
                    Button("Delete Collection", role: .destructive, action: onDeleteCollection)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if isExpanded {
                ForEach(collection.items) { child in
                    NodeRow(
                        node: child,
                        level: 1,
                        selectedNodeID: selectedNodeID,
                        onOpenRequest: onOpenRequest,
                        onRenameRequest: onRenameRequest,
                        onDuplicateRequest: onDuplicateRequest,
                        onDeleteRequest: onDeleteRequest
                    )
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: CollectionNode
    let level: Int
    let selectedNodeID: UUID?
    let onOpenRequest: (CollectionNode) -> Void
    let onRenameRequest: (CollectionNode) -> Void
    let onDuplicateRequest: (CollectionNode) -> Void
    let onDeleteRequest: (CollectionNode) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if node.kind == .folder {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(width: 10)
                        Text(node.name)
                            .foregroundStyle(level == 0 ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                            .font(level == 0 ? .body.weight(.medium) : .callout)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(level) * 14)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(node.children) { child in
                        NodeRow(
                            node: child,
                            level: level + 1,
                            selectedNodeID: selectedNodeID,
                            onOpenRequest: onOpenRequest,
                            onRenameRequest: onRenameRequest,
                            onDuplicateRequest: onDuplicateRequest,
                            onDeleteRequest: onDeleteRequest
                        )
                    }
                }
            } else {
                Button {
                    onOpenRequest(node)
                } label: {
                    HStack(spacing: 8) {
                        Spacer()
                            .frame(width: 10)
                        if let request = node.request {
                            requestPill(request)
                        } else {
                            methodPill(.get)
                        }
                        Text(node.name)
                            .lineLimit(1)
                            .foregroundStyle(PostmanTheme.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(level) * 14)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    selectedNodeID == node.id ? PostmanTheme.activeTab : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contextMenu {
                    Button("Rename Request") {
                        onRenameRequest(node)
                    }
                    Button("Duplicate Request") {
                        onDuplicateRequest(node)
                    }
                    Button("Delete Request", role: .destructive) {
                        onDeleteRequest(node)
                    }
                }
            }
        }
    }
}

private struct WorkspacePane: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            RequestTabsBar(viewModel: viewModel)
            Divider().overlay(PostmanTheme.border)

            if let currentTab = viewModel.currentTab {
                RequestWorkspace(viewModel: viewModel, tab: currentTab)
                    .id(currentTab.id)
            } else {
                ContentUnavailableView("No Open Tabs", systemImage: "rectangle.on.rectangle")
                    .foregroundStyle(PostmanTheme.textSecondary)
            }
        }
        .background(PostmanTheme.appBackground)
    }
}

private struct RequestTabsBar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.tabs) { tab in
                    HStack(spacing: 8) {
                        requestPill(tab.request)
                        Button {
                            viewModel.selectedTabID = tab.id
                        } label: {
                            Text(tab.request.name)
                                .lineLimit(1)
                                .foregroundStyle(viewModel.selectedTabID == tab.id ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if tab.isSending {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            viewModel.closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(PostmanTheme.textSecondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        viewModel.selectedTabID == tab.id ? PostmanTheme.activeTab : PostmanTheme.tab,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }

                Button {
                    viewModel.newRequest()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(PostmanTheme.tab, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(PostmanTheme.panel)
    }
}

private struct RequestWorkspace: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var editorHeightRatio: CGFloat = 0.52

    var body: some View {
        VStack(spacing: 0) {
            RequestHeader(viewModel: viewModel, tab: tab)
            Divider().overlay(PostmanTheme.border)
            ResizableVerticalSplitView(
                topHeightRatio: $editorHeightRatio,
                minimumTopHeight: 220,
                minimumBottomHeight: 180
            ) {
                RequestEditorView(viewModel: viewModel, tab: tab)
            } bottom: {
                ResponsePane(viewModel: viewModel, tab: tab)
            }
        }
    }
}

private struct ResizableVerticalSplitView<Top: View, Bottom: View>: View {
    @Binding var topHeightRatio: CGFloat
    let minimumTopHeight: CGFloat
    let minimumBottomHeight: CGFloat
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    @State private var dragOriginRatio: CGFloat?
    @State private var isHoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 10
            let totalHeight = geometry.size.height
            let availableHeight = max(totalHeight - dividerHeight, minimumTopHeight + minimumBottomHeight)
            let proposedTopHeight = availableHeight * topHeightRatio
            let topHeight = min(max(proposedTopHeight, minimumTopHeight), availableHeight - minimumBottomHeight)
            let bottomHeight = max(availableHeight - topHeight, minimumBottomHeight)

            VStack(spacing: 0) {
                top
                    .frame(height: topHeight)

                Rectangle()
                    .fill(PostmanTheme.border.opacity(0.8))
                    .frame(height: 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(PostmanTheme.panelElevated)
                            .frame(width: 84, height: dividerHeight)
                            .overlay(
                                HStack(spacing: 5) {
                                    Capsule().fill(PostmanTheme.textSecondary.opacity(0.7)).frame(width: 14, height: 3)
                                    Capsule().fill(PostmanTheme.textSecondary.opacity(0.7)).frame(width: 14, height: 3)
                                }
                            )
                    }
                    .frame(height: dividerHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != isHoveringDivider else { return }
                        isHoveringDivider = hovering
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragOriginRatio == nil {
                                    dragOriginRatio = topHeightRatio
                                }
                                let baseRatio = dragOriginRatio ?? topHeightRatio
                                let deltaRatio = value.translation.height / availableHeight
                                topHeightRatio = min(max(baseRatio + deltaRatio, minimumTopHeight / availableHeight), 1 - (minimumBottomHeight / availableHeight))
                            }
                            .onEnded { _ in
                                dragOriginRatio = nil
                            }
                    )

                bottom
                    .frame(height: bottomHeight)
            }
        }
    }
}

private struct RequestHeader: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var editingEnvironment: EnvironmentProfile?
    @State private var environmentPendingDeletion: EnvironmentProfile?
    @State private var environmentCloneDraft: EnvironmentCloneDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(tab.request.transportKind.displayName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.accent)
                        Text(tab.request.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Text("Environment")
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Picker("Environment", selection: viewModel.environmentPickerBinding(for: tab)) {
                        Text("No Environment").tag(Optional<UUID>.none)
                        ForEach(viewModel.workspace.environments) { environment in
                            Text(environment.name).tag(Optional(environment.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)

                    Button {
                        let environment = viewModel.addEnvironment()
                        viewModel.selectEnvironment(environment, for: tab)
                        editingEnvironment = environment
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        importEnvironmentFromDisk()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        guard let environment = selectedEnvironment else { return }
                        environmentCloneDraft = EnvironmentCloneDraft(source: environment)
                    } label: {
                        Image(systemName: "square.on.square")
                            .foregroundStyle(selectedEnvironment == nil ? PostmanTheme.textSecondary.opacity(0.5) : PostmanTheme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedEnvironment == nil)
                    .help("Clonar entorno (copia variables)")

                    Button {
                        editingEnvironment = selectedEnvironment
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(selectedEnvironment == nil ? PostmanTheme.textSecondary.opacity(0.5) : PostmanTheme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedEnvironment == nil)

                    Button {
                        environmentPendingDeletion = selectedEnvironment
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(selectedEnvironment == nil ? PostmanTheme.textSecondary.opacity(0.5) : PostmanTheme.salmon)
                            .frame(width: 30, height: 30)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedEnvironment == nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(PostmanTheme.appBackground)
        .sheet(item: $editingEnvironment) { environment in
            EnvironmentEditor(viewModel: viewModel, tab: tab, environment: environment)
            .preferredColorScheme(.dark)
        }
        .sheet(item: $environmentCloneDraft) { draft in
            RenameSheet(
                title: "Clonar entorno",
                initialValue: viewModel.suggestedEnvironmentCloneName(for: draft.source),
                validationMessage: { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        return "El nombre es obligatorio."
                    }
                    if viewModel.workspace.environments.contains(where: {
                        $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                    }) {
                        return "Ya existe un entorno con ese nombre."
                    }
                    return nil
                }
            ) { name in
                let copy = viewModel.duplicateEnvironment(draft.source, named: name)
                viewModel.selectEnvironment(copy, for: tab)
            }
            .preferredColorScheme(.dark)
        }
        .alert(
            "Delete Environment",
            isPresented: Binding(
                get: { environmentPendingDeletion != nil },
                set: { if !$0 { environmentPendingDeletion = nil } }
            ),
            presenting: environmentPendingDeletion
        ) { environment in
            Button("Delete", role: .destructive) {
                viewModel.deleteEnvironment(environment)
                environmentPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                environmentPendingDeletion = nil
            }
        } message: { environment in
            Text("Are you sure you want to delete the environment '\(environment.name)'?")
        }
    }

    private var selectedEnvironment: EnvironmentProfile? {
        let selectedID = tab.selectedEnvironmentID ?? viewModel.workspace.activeEnvironmentID
        guard let selectedID,
              var environment = viewModel.workspace.environments.first(where: { $0.id == selectedID }) else {
            return nil
        }

        if let pendingVariables = tab.pendingEnvironmentVariables {
            environment.variables = pendingVariables
        }

        return environment
    }

    private func importEnvironmentFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Select a Postman environment JSON file."

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await viewModel.importDocument(from: url)
                if let environment = viewModel.activeEnvironment {
                    await MainActor.run {
                        viewModel.selectEnvironment(environment, for: tab)
                        editingEnvironment = environment
                    }
                }
            }
        }
    }
}

private enum RequestEditorTab: String, CaseIterable, Identifiable {
    case docs = "Docs"
    case params = "Params"
    case authorization = "Authorization"
    case headers = "Headers"
    case body = "Body"
    case scripts = "Scripts"
    case settings = "Settings"

    var id: String { rawValue }
}

private struct RequestEditorView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var bodyEditorText = ""
    @State private var bodyEditorRequestID: UUID?
    @State private var activeAWSAccessPortalSystemAuthSession: ASWebAuthenticationSession?
    @State private var portalAWSAlertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(RequestTransportKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) {
                            tab.request.transportKind = kind
                            switch kind {
                            case .webSocket:
                                tab.request.method = .get
                            case .http:
                                tab.request.httpRequestTargetKind = .url
                                if tab.request.auth.type == .awsTemporaryCredentials {
                                    tab.request.auth.type = .noAuth
                                }
                            case .invokeLambda:
                                tab.request.httpRequestTargetKind = .invokeLambda
                                tab.request.method = .post
                                tab.request.auth.type = .awsTemporaryCredentials
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(tab.request.transportKind.displayName)
                        .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 120, minHeight: 36, alignment: .leading)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)

                if tab.request.usesHTTPTransport {
                    if tab.request.transportKind == .http {
                        Menu {
                            ForEach(HTTPMethod.allCases, id: \.self) { method in
                                Button(method.rawValue) {
                                    tab.request.method = method
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(tab.request.method.rawValue)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 120, minHeight: 36, alignment: .leading)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                    } else {
                        HStack(spacing: 8) {
                            Text(HTTPMethod.post.rawValue)
                                .lineLimit(1)
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 120, minHeight: 36, alignment: .leading)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                }

                DarkTextInput(text: binding(\.url), placeholder: requestAddressPlaceholder)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Spacer(minLength: 0)

                if tab.request.usesHTTPTransport {
                    Button {
                        synchronizeBodyEditorToRequest()
                        viewModel.sendCurrentRequest()
                    } label: {
                        Text("Send")
                            .frame(width: 86, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                    Button {
                        synchronizeBodyEditorToRequest()
                        viewModel.cancelCurrentRequest()
                    } label: {
                        Text("Cancel")
                            .frame(width: 72, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .disabled(!tab.isSending)
                } else {
                    Button {
                        synchronizeBodyEditorToRequest()
                        viewModel.sendCurrentRequest()
                    } label: {
                        Text("Connect")
                            .frame(width: 92, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(
                        tab.webSocketConnectionState == .connected ||
                        tab.webSocketConnectionState == .connecting ||
                        tab.webSocketConnectionState == .disconnecting
                    )

                    Button {
                        viewModel.disconnectCurrentWebSocket()
                    } label: {
                        Text("Disconnect")
                            .frame(width: 92, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .disabled(tab.webSocketConnectionState == .disconnected)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            HStack(spacing: 18) {
                ForEach(RequestEditorTab.allCases) { editorTab in
                    editorTabButton(editorTab)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .background(PostmanTheme.appBackground)

            Divider().overlay(PostmanTheme.border)

            VStack(spacing: 0) {
                selectedEditorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(PostmanTheme.appBackground)

                if tab.request.isLambdaInvoke {
                    lambdaAWSAccessPortalBar
                }
            }
        }
        .onChange(of: tab.request) { _, _ in
            viewModel.persistPendingChanges(for: tab)
        }
        .onAppear {
            loadBodyEditorIfNeeded(force: true)
        }
        .onChange(of: tab.request.id) { _, _ in
            loadBodyEditorIfNeeded(force: true)
        }
        .onChange(of: tab.editorRefreshToken) { _, _ in
            loadBodyEditorIfNeeded(force: true)
        }
        .onChange(of: tab.request.body.raw) { _, newValue in
            if bodyEditorText != newValue {
                bodyEditorText = newValue
            }
        }
        .alert("Portal AWS", isPresented: Binding(
            get: { portalAWSAlertMessage != nil },
            set: { if !$0 { portalAWSAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { portalAWSAlertMessage = nil }
        } message: {
            Text(portalAWSAlertMessage ?? "")
        }
    }

    private func beginAWSAccessPortalSystemSession() {
        Task { @MainActor in
            await viewModel.synchronizeVariableStoresBeforePortalAWS(for: tab)
            let raw = viewModel.resolvedAWSAccessPortalURL(for: tab)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                portalAWSAlertMessage = "Introduce una URL del portal en el campo inferior (p. ej. {{urlaws}} resuelto por variables de entorno)."
                return
            }
            if raw.contains("{{") {
                portalAWSAlertMessage =
                    "Quedan variables sin resolver en la URL (p. ej. \(raw)). Revisa el nombre en el entorno activo, mayúsculas y que la variable esté habilitada."
                return
            }
            guard let url = AWSAccessPortalResolvedURL.openURL(fromResolvedTemplate: raw) else {
                portalAWSAlertMessage =
                    "La URL resuelta no es válida. Usa `https://…` o un host con ruta; si es variable de entorno, el valor debe ser una URL completa o al menos dominio+ruta."
                return
            }

            activeAWSAccessPortalSystemAuthSession?.cancel()
            activeAWSAccessPortalSystemAuthSession = nil

            activeAWSAccessPortalSystemAuthSession = AWSAccessPortalSystemBrowserAuth.begin(
                url: url,
                prefersEphemeral: false
            ) { result in
                Task { @MainActor in
                    activeAWSAccessPortalSystemAuthSession = nil
                    switch result {
                    case .success:
                        viewModel.persistPendingChanges(for: tab)
                    case let .failure(error):
                        let ns = error as NSError
                        let canceled = ns.domain == ASWebAuthenticationSessionErrorDomain
                            && ns.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
                        if canceled {
                            return
                        }
                        portalAWSAlertMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private var docsView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .docs)) {
            VStack(alignment: .leading, spacing: 12) {
                darkInput("Request Name", text: binding(\.name))
                DarkSection(title: "Request Summary") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transport: \(tab.request.transportKind.displayName)")
                        if tab.request.transportKind == .http {
                            Text("Method: \(tab.request.method.rawValue)")
                        } else if tab.request.transportKind == .invokeLambda {
                            Text("Method: \(HTTPMethod.post.rawValue) (Lambda invoke)")
                        }
                        Text("\(tab.request.isLambdaInvoke ? "Lambda ARN" : "URL"): \(tab.request.url)")
                        Text("Headers: \(tab.request.headers.count)")
                        Text("Params: \(tab.request.queryItems.count)")
                        if tab.request.transportKind == .webSocket {
                            Text("Transcript entries: \(tab.webSocketTranscript.count)")
                            Text("Open timeout: \(formattedSeconds(tab.request.webSocketOpenTimeoutSeconds))")
                            Text("Ping interval: \(formattedSeconds(tab.request.webSocketPingIntervalSeconds))")
                            Text("Keepalive interval: \(formattedSeconds(tab.request.webSocketKeepAliveIntervalSeconds))")
                        }
                    }
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private var paramsView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .params)) {
            VStack(alignment: .leading, spacing: 18) {
                DarkSection(title: "Query Params") {
                    EditableKeyValueList(title: "", entries: binding(\.queryItems))
                }
                DarkSection(title: "Path Params") {
                    EditableKeyValueList(title: "", entries: binding(\.pathVariables))
                }
                DarkSection(title: "Cookies") {
                    EditableKeyValueList(title: "", entries: binding(\.cookies))
                }
            }
            .padding(16)
        }
    }

    private var headersView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .headers)) {
            DarkSection(title: "Headers") {
                EditableKeyValueList(title: "", entries: binding(\.headers))
            }
            .padding(16)
        }
    }

    private var lambdaAWSAccessPortalBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(PostmanTheme.border)
            HStack(spacing: 10) {
                DarkTextInput(
                    text: binding(\.awsAccessPortalURLTemplate),
                    placeholder: "{{urlaws}} o URL del portal…"
                )
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Button {
                    beginAWSAccessPortalSystemSession()
                } label: {
                    Label("Portal AWS…", systemImage: "globe")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                .help("Abre ASWebAuthenticationSession (ventana del sistema) con la URL del campo. El IdP debe redirigir al esquema \(AWSAccessPortalAuthCallback.urlScheme)://… registrado en la app. Tras el login, pega las credenciales temporales en Authorization si el portal no devuelve token en la URL.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PostmanTheme.appBackground)
        }
    }

    private var authView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .authorization)) {
            DarkSection(title: "Authorization") {
                VStack(alignment: .leading, spacing: 12) {
                    if tab.request.isLambdaInvoke {
                        Text("AWS Temporary Credentials")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        Text(
                            "Pega credenciales en formato INI (`aws_access_key_id=…`) o líneas `export AWS_ACCESS_KEY_ID=…`. En la barra inferior del editor, indica la URL del portal (o `{{variable}}`) y pulsa **Portal AWS…** para abrir la **ventana de inicio de sesión del sistema** (MFA/WebAuthn). Si el IdP no redirige al esquema registrado en la app, copia las claves desde el portal y pégalas aquí. La petición firmará Lambda con SigV4 usando el ARN del campo URL."
                        )
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)

                        MacCodeEditor(
                            text: binding(\.auth.token),
                            language: .plainText,
                            showsLineNumbers: true,
                            selectEntireDocumentOnClick: true
                        )
                        .frame(minHeight: 210, maxHeight: 320)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))

                        Text("[profile]\naws_access_key_id=…\n…\n\nexport AWS_ACCESS_KEY_ID=\"…\"\nexport AWS_SECRET_ACCESS_KEY=\"…\"\nexport AWS_SESSION_TOKEN=\"…\"")
                            .font(.caption.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .padding(.top, 4)
                    } else {
                        Picker("Type", selection: binding(\.auth.type)) {
                            ForEach(standardHTTPAuthTypes, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)

                        switch tab.request.auth.type {
                        case .noAuth:
                            mutedText("No Auth")
                        case .basic:
                            darkInput("Username", text: binding(\.auth.username))
                            secureDarkInput("Password", text: binding(\.auth.password))
                        case .bearer:
                            darkInput("Token", text: binding(\.auth.token))
                        case .apiKey:
                            darkInput("Key", text: binding(\.auth.key))
                            darkInput("Value", text: binding(\.auth.value))
                            Picker("Placement", selection: binding(\.auth.addTo)) {
                                ForEach(APIKeyPlacement.allCases, id: \.self) { placement in
                                    Text(placement.rawValue).tag(placement)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        case .oauth2:
                            darkInput("Access Token", text: binding(\.auth.token))
                            darkInput("Token URL", text: binding(\.auth.accessTokenURL))
                            darkInput("Client ID", text: binding(\.auth.clientID))
                            secureDarkInput("Client Secret", text: binding(\.auth.clientSecret))
                            darkInput("Scopes", text: binding(\.auth.scopes))
                        case .awsTemporaryCredentials:
                            mutedText("Switch transport to Invoke Lambda to use AWS temporary credentials.")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var bodyView: some View {
        VStack(spacing: 0) {
            if tab.request.transportKind == .webSocket {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Outgoing Message")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)
                        Spacer()
                        Text("Placeholders like {{token}} are resolved when sending.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Text("Open the socket with `Connect` above, then use `Send Msg` here for manual messages.")
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .padding(.horizontal, 16)

                    MacCodeEditor(
                        text: bodyTextBinding,
                        verticalScrollOffset: scrollOffsetBinding(for: .body),
                        language: .plainText,
                        showsLineNumbers: true,
                        autocompleteContext: .javascript(workspaceUtilities: viewModel.workspace.utilityLibraries)
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                        .padding(16)

                    HStack {
                        Spacer()

                        Button {
                            synchronizeBodyEditorToRequest()
                            viewModel.sendCurrentWebSocketMessage()
                        } label: {
                            Text("Send Msg")
                                .frame(width: 108, height: 40)
                                .contentShape(Rectangle())
                                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .disabled(tab.webSocketConnectionState != .connected)
                        .opacity(tab.webSocketConnectionState == .connected ? 1 : 0.6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            } else {
                BodyModeBar(
                    bodyKind: binding(\.body.kind),
                    jsonValidation: jsonValidationFeedback,
                    canBeautify: canBeautifyBody,
                    onBeautify: beautifyBody
                )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Divider().overlay(PostmanTheme.border)

                if tab.request.body.kind == .urlEncoded || tab.request.body.kind == .formData {
                    RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .body)) {
                        VStack(alignment: .leading, spacing: 16) {
                            DarkSection(title: "Body Fields") {
                                EditableKeyValueList(title: "", entries: binding(\.body.parameters))
                            }
                        }
                        .padding(16)
                    }
                } else {
                    MacCodeEditor(
                        text: bodyTextBinding,
                        verticalScrollOffset: scrollOffsetBinding(for: .body),
                        language: bodyEditorLanguage,
                        showsLineNumbers: true,
                        autocompleteContext: .javascript(workspaceUtilities: viewModel.workspace.utilityLibraries)
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                        .padding(16)
                }
            }
        }
    }

    private var settingsView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .settings)) {
            DarkSection(title: "Request Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    darkInput("Request Name", text: binding(\.name))
                    HStack {
                        Text("Timeout")
                            .foregroundStyle(PostmanTheme.textSecondary)
                        Slider(value: binding(\.timeoutSeconds), in: 5...120, step: 5)
                        Text("\(Int(tab.request.timeoutSeconds))s")
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .frame(width: 44)
                    }

                    if tab.request.usesHTTPTransport {
                        HStack {
                            Text("Retries on HTTP 206")
                                .foregroundStyle(PostmanTheme.textSecondary)
                            Spacer()
                            Text("\(tab.request.retryOn206Count)")
                                .foregroundStyle(PostmanTheme.textPrimary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Stepper("", value: binding(\.retryOn206Count), in: 0...20)
                                .labelsHidden()
                        }
                        webSocketNumericSettingRow(
                            title: "Delay between HTTP 206 retries",
                            description: "Milliseconds to wait after a 206 before running pre-request again and retrying. Use 0 for no delay.",
                            text: webSocketIntegerBinding(\.retryOn206DelayMilliseconds),
                            suffix: "ms"
                        )
                        Text("Default: 5 retries. Set retries to 0 to disable. After each 206, the pre-request script runs again before the next attempt.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }

                    if tab.request.transportKind == .webSocket {
                        webSocketBooleanSettingRow(
                            title: "Enable server certificate verification",
                            description: "Verify the server certificate when connecting over a secure connection.",
                            isOn: Binding(
                                get: { tab.request.tlsValidationMode == .strict },
                                set: { tab.request.tlsValidationMode = $0 ? .strict : .insecure }
                            )
                        )

                        webSocketNumericSettingRow(
                            title: "Handshake request timeout",
                            description: "Set how long the handshake request should wait before timing out in milliseconds. Set 0 to disable the limit.",
                            text: webSocketMillisecondsBinding(\.webSocketOpenTimeoutSeconds),
                            suffix: "ms"
                        )

                        webSocketNumericSettingRow(
                            title: "Reconnection attempts",
                            description: "Maximum reconnection attempts when the connection closes unexpectedly.",
                            text: webSocketIntegerBinding(\.webSocketReconnectAttempts)
                        )

                        webSocketNumericSettingRow(
                            title: "Reconnection intervals",
                            description: "Interval between reconnection attempts in milliseconds.",
                            text: webSocketIntegerBinding(\.webSocketReconnectIntervalMilliseconds),
                            suffix: "ms"
                        )

                        webSocketNumericSettingRow(
                            title: "Maximum message size",
                            description: "Maximum allowed message size in MB. Set 0 to accept messages of any size.",
                            text: webSocketIntegerBinding(\.webSocketMaximumMessageSizeMB),
                            suffix: "MB"
                        )

                        webSocketTextSettingRow(
                            title: "Subprotocols",
                            description: "Optional. Separate multiple subprotocols with commas.",
                            text: binding(\.webSocketSubprotocols),
                            placeholder: "json, chat.v2"
                        )

                        webSocketNumericSettingRow(
                            title: "Ping interval",
                            description: "Send native WebSocket ping frames every N seconds. Set 0 to disable it.",
                            text: webSocketSecondsBinding(\.webSocketPingIntervalSeconds),
                            suffix: "s"
                        )

                        webSocketNumericSettingRow(
                            title: "Keepalive interval",
                            description: "Send the keepalive message every N seconds after connecting. Set 0 to disable it.",
                            text: webSocketSecondsBinding(\.webSocketKeepAliveIntervalSeconds),
                            suffix: "s"
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Keepalive message")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PostmanTheme.textPrimary)

                            Text("If the interval is greater than 0 and this field is not empty, the app sends this message automatically.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.textSecondary)

                            MacCodeEditor(
                                text: binding(\.webSocketKeepAliveMessage),
                                language: .plainText,
                                showsLineNumbers: false
                            )
                            .frame(minHeight: 110, maxHeight: 150)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                        }

                        webSocketPickerSettingRow(
                            title: "Minimum TLS version",
                            description: "Force a minimum TLS version for the WebSocket handshake when needed.",
                            width: 170
                        ) {
                            Picker("Minimum TLS", selection: binding(\.minimumTLSVersion)) {
                                ForEach(TLSMinimumVersionOption.allCases, id: \.self) { version in
                                    Text(version.displayName).tag(version)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        if tab.request.tlsValidationMode == .insecure {
                            Text("Warning: disabling TLS validation is insecure and should only be used for debugging trusted endpoints.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.salmon)
                        }

                        Text("WebSocket connections reuse the configured URL, headers, auth, cookies, query params, and TLS settings.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }

                    if tab.request.usesHTTPTransport {
                        Divider().overlay(PostmanTheme.border)

                        HStack {
                            Text("TLS Validation")
                                .foregroundStyle(PostmanTheme.textSecondary)
                            Spacer()
                            Picker("TLS Validation", selection: binding(\.tlsValidationMode)) {
                                ForEach(TLSValidationMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        HStack {
                            Text("Minimum TLS")
                                .foregroundStyle(PostmanTheme.textSecondary)
                            Spacer()
                            Picker("Minimum TLS", selection: binding(\.minimumTLSVersion)) {
                                ForEach(TLSMinimumVersionOption.allCases, id: \.self) { version in
                                    Text(version.displayName).tag(version)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        if tab.request.tlsValidationMode == .insecure {
                            Text("Warning: disabling TLS validation is insecure and should only be used for debugging trusted endpoints.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.salmon)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func webSocketBooleanSettingRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 8)
    }

    private func webSocketNumericSettingRow(
        title: String,
        description: String,
        text: Binding<String>,
        suffix: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                compactDarkInput(text: text, placeholder: "0", width: 92)
                if let suffix, !suffix.isEmpty {
                    Text(suffix)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PostmanTheme.textSecondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func webSocketTextSettingRow(
        title: String,
        description: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            compactDarkInput(text: text, placeholder: placeholder, width: 180)
        }
        .padding(.vertical, 8)
    }

    private func webSocketPickerSettingRow<PickerContent: View>(
        title: String,
        description: String,
        width: CGFloat,
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            picker()
                .frame(width: width)
        }
        .padding(.vertical, 8)
    }

    private func compactDarkInput(
        text: Binding<String>,
        placeholder: String,
        width: CGFloat
    ) -> some View {
        DarkTextInput(text: text, placeholder: placeholder)
            .padding(.horizontal, 12)
            .frame(width: width, height: 40)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
    }

    private var standardHTTPAuthTypes: [AuthType] {
        AuthType.allCases.filter { $0 != .awsTemporaryCredentials }
    }

    private var requestAddressPlaceholder: String {
        if tab.request.isLambdaInvoke {
            return "arn:aws:lambda:us-east-1:123456789012:function:my-function"
        }

        if tab.request.transportKind == .webSocket {
            return "wss://api.example.com/socket"
        }

        return "https://api.example.com/resource"
    }

    private func webSocketMillisecondsBinding(_ keyPath: WritableKeyPath<APIRequestModel, Double>) -> Binding<String> {
        Binding(
            get: {
                let milliseconds = Int((tab.request[keyPath: keyPath] * 1_000).rounded())
                return String(milliseconds)
            },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                let milliseconds = Int(digits) ?? 0
                tab.request[keyPath: keyPath] = Double(milliseconds) / 1_000
            }
        )
    }

    private func webSocketSecondsBinding(_ keyPath: WritableKeyPath<APIRequestModel, Double>) -> Binding<String> {
        Binding(
            get: {
                let seconds = tab.request[keyPath: keyPath]
                if seconds.rounded() == seconds {
                    return String(Int(seconds))
                }
                return seconds.formatted(.number.precision(.fractionLength(0...2)))
            },
            set: { newValue in
                let sanitized = newValue.filter { $0.isNumber || $0 == "." }
                tab.request[keyPath: keyPath] = max(0, Double(sanitized) ?? 0)
            }
        )
    }

    private func webSocketIntegerBinding(_ keyPath: WritableKeyPath<APIRequestModel, Int>) -> Binding<String> {
        Binding(
            get: { String(tab.request[keyPath: keyPath]) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                tab.request[keyPath: keyPath] = max(0, Int(digits) ?? 0)
            }
        )
    }

    private func formattedSeconds(_ value: Double) -> String {
        if value == 0 {
            return "0s"
        }
        if value.rounded() == value {
            return "\(Int(value))s"
        }
        return "\(value.formatted())s"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<APIRequestModel, Value>) -> Binding<Value> {
        Binding(
            get: { tab.request[keyPath: keyPath] },
            set: { tab.request[keyPath: keyPath] = $0 }
        )
    }

    private var selectedEditorTab: RequestEditorTab {
        get { RequestEditorTab(rawValue: tab.requestEditorSelectedTabRawValue) ?? .body }
        nonmutating set { tab.requestEditorSelectedTabRawValue = newValue.rawValue }
    }

    private var bodyTextBinding: Binding<String> {
        Binding(
            get: { bodyEditorText },
            set: { newValue in
                bodyEditorText = newValue
                tab.request.body.raw = newValue
                if tab.request.body.kind == .none {
                    tab.request.body.kind = .raw
                }
            }
        )
    }

    private func scrollOffsetBinding(for editorTab: RequestEditorTab) -> Binding<Double> {
        Binding(
            get: { tab.requestEditorScrollOffsets[editorTab.rawValue] ?? 0 },
            set: { tab.requestEditorScrollOffsets[editorTab.rawValue] = $0 }
        )
    }

    private func editorTabButton(_ editorTab: RequestEditorTab) -> some View {
        let isSelected = selectedEditorTab == editorTab

        return Button {
            selectedEditorTab = editorTab
        } label: {
            Text(editorTab.rawValue)
                .foregroundStyle(isSelected ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(PostmanTheme.orange)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedEditorContent: AnyView {
        switch selectedEditorTab {
        case .docs:
            AnyView(docsView)
        case .params:
            AnyView(paramsView)
        case .authorization:
            AnyView(authView)
        case .headers:
            AnyView(headersView)
        case .body:
            AnyView(bodyView)
        case .scripts:
            AnyView(
                ScriptsTabView(
                    requestID: tab.request.id,
                    transportKind: tab.request.transportKind,
                    refreshToken: tab.editorRefreshToken,
                    utilityLibraries: viewModel.workspace.utilityLibraries,
                    scripts: binding(\.scripts),
                    selectedPanelRawValue: Binding(
                        get: { tab.requestScriptsSelectedPanelRawValue },
                        set: { tab.requestScriptsSelectedPanelRawValue = $0 }
                    ),
                    scrollOffsets: Binding(
                        get: { tab.requestEditorScrollOffsets },
                        set: { tab.requestEditorScrollOffsets = $0 }
                    )
                )
            )
        case .settings:
            AnyView(settingsView)
        }
    }

    private var canBeautifyBody: Bool {
        switch tab.request.body.kind {
        case .raw, .json:
            return !tab.request.body.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .none, .urlEncoded, .formData:
            return false
        }
    }

    private var shouldValidateJSONBody: Bool {
        if tab.request.body.kind == .json {
            return true
        }

        let trimmed = bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return tab.request.body.kind == .raw && (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))
    }

    private var bodyEditorLanguage: CodeEditorLanguage {
        shouldValidateJSONBody ? .json : .plainText
    }

    private var jsonValidationFeedback: (message: String, color: Color, isValid: Bool)? {
        guard shouldValidateJSONBody else { return nil }

        let trimmed = bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("JSON body is empty.", .red, false)
        }

        do {
            _ = try parseJSONObject(from: trimmed)
            return ("Valid JSON body.", PostmanTheme.green, true)
        } catch {
            return (error.localizedDescription, .red, false)
        }
    }

    private func beautifyBody() {
        let trimmed = bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let prepared = try prepareJSONForValidation(from: trimmed)
            let object = try JSONSerialization.jsonObject(with: Data(prepared.sanitized.utf8))
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            if let text = String(data: formatted, encoding: .utf8) {
                let indented = reindentJSON(text, spacesPerLevel: 4)
                let restored = restoreJSONPlaceholders(in: indented, placeholders: prepared.placeholders)
                bodyEditorText = restored
                tab.request.body.raw = restored
                if tab.request.body.kind == .raw {
                    tab.request.body.kind = .json
                }
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func loadBodyEditorIfNeeded(force: Bool = false) {
        guard force || bodyEditorRequestID != tab.request.id else { return }
        bodyEditorRequestID = tab.request.id
        bodyEditorText = tab.request.body.raw
    }

    private func synchronizeBodyEditorToRequest() {
        if tab.request.body.raw != bodyEditorText {
            tab.request.body.raw = bodyEditorText
        }
        if tab.request.body.kind == .none && !bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.request.body.kind = .raw
        }
    }

    private func parseJSONObject(from text: String) throws -> Any {
        do {
            let prepared = try prepareJSONForValidation(from: text)
            return try JSONSerialization.jsonObject(with: Data(prepared.sanitized.utf8))
        } catch {
            throw AppError.invalidDocument("Invalid JSON body: \(error.localizedDescription)")
        }
    }

    private func prepareJSONForValidation(from text: String) throws -> (sanitized: String, placeholders: [String: String]) {
        let pattern = #"(?<!["\\])(\{\{\s*[^{}\n]+\s*\}\})(?!\s*")"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else {
            return (text, [:])
        }

        var sanitized = text
        var placeholders: [String: String] = [:]

        for (index, match) in matches.enumerated().reversed() {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            let token = nsText.substring(with: range)
            let marker = "__EFBY_PLACEHOLDER_\(index)__"
            let replacement = "\"\(marker)\""
            let swiftRange = Range(range, in: sanitized)!
            sanitized.replaceSubrange(swiftRange, with: replacement)
            placeholders[marker] = token
        }

        return (sanitized, placeholders)
    }

    private func restoreJSONPlaceholders(in text: String, placeholders: [String: String]) -> String {
        var restored = text
        for (marker, token) in placeholders {
            restored = restored.replacingOccurrences(of: "\"\(marker)\"", with: token)
        }
        return restored
    }

    private func reindentJSON(_ text: String, spacesPerLevel: Int) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let leadingSpaces = line.prefix { $0 == " " }.count
                guard leadingSpaces > 0 else { return String(line) }
                let level = leadingSpaces / 2
                return String(repeating: " ", count: level * spacesPerLevel) + line.dropFirst(leadingSpaces)
            }
            .joined(separator: "\n")
    }

    private func darkInput(_ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: text, placeholder: placeholder)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        }
    }

    private func secureDarkInput(_ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: text, placeholder: placeholder, isSecure: true)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        }
    }

    private func mutedText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(PostmanTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

private struct BodyModeBar: View {
    @Binding var bodyKind: RequestBodyKind
    let jsonValidation: (message: String, color: Color, isValid: Bool)?
    let canBeautify: Bool
    let onBeautify: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            mode("none", .none)
            mode("form-data", .formData)
            mode("x-www-form-urlencoded", .urlEncoded)
            mode("raw", .raw)
            mode("JSON", .json)
            Spacer()

            if let jsonValidation {
                HStack(spacing: 6) {
                    Image(systemName: jsonValidation.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(jsonValidation.message)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(jsonValidation.color)
            }

            Button(action: onBeautify) {
                Text("Beautify")
                    .font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canBeautify ? PostmanTheme.accent : PostmanTheme.textSecondary)
            .frame(width: 84, height: 28)
            .disabled(!canBeautify)
        }
    }

    private func mode(_ title: String, _ kind: RequestBodyKind) -> some View {
        Button {
            bodyKind = kind
        } label: {
            HStack(spacing: 6) {
                Image(systemName: bodyKind == kind ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(bodyKind == kind ? PostmanTheme.accent : PostmanTheme.textSecondary)
                Text(title)
                    .foregroundStyle(PostmanTheme.textPrimary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DarkSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(PostmanTheme.textPrimary)
            content
        }
        .padding(14)
        .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
    }
}

private struct EditableKeyValueList: View {
    let title: String
    @Binding var entries: [KeyValueEntry]
    @State private var previewPayload: CodeValuePreviewPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PostmanTheme.textPrimary)
                    Spacer()
                    addButton
                }
            } else {
                HStack {
                    Spacer()
                    addButton
                }
            }

            if entries.isEmpty {
                Text("No entries.")
                    .foregroundStyle(PostmanTheme.textSecondary)
            } else {
                ForEach(entries.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Toggle("", isOn: binding(for: index, keyPath: \.isEnabled))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .foregroundStyle(PostmanTheme.textSecondary)

                        darkRowInput("Key", text: binding(for: index, keyPath: \.key))
                        darkRowInput("Value", text: binding(for: index, keyPath: \.value))
                        previewButton(
                            title: entries[index].key.isEmpty ? "Value" : entries[index].key,
                            value: entries[index].value
                        )

                        Button {
                            entries.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(PostmanTheme.textSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $previewPayload) { payload in
            CodeValuePreviewSheet(payload: payload)
                .preferredColorScheme(.dark)
        }
    }

    private var addButton: some View {
        Button {
            entries.append(KeyValueEntry())
        } label: {
            Text("Add")
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.accent)
    }

    private func darkRowInput(_ placeholder: String, text: Binding<String>) -> some View {
        DarkTextInput(text: text, placeholder: placeholder)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
    }

    private func previewButton(title: String, value: String) -> some View {
        Button("Preview", systemImage: "magnifyingglass") {
            previewPayload = CodeValuePreviewPayload(title: title, value: value)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textSecondary)
        .frame(width: 28, height: 28)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        .accessibilityLabel("Preview \(title)")
    }

    private func binding<Value>(for index: Int, keyPath: WritableKeyPath<KeyValueEntry, Value>) -> Binding<Value> {
        Binding(
            get: { entries[index][keyPath: keyPath] },
            set: { entries[index][keyPath: keyPath] = $0 }
        )
    }
}

private enum ResponseTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case response = "Response"
    case headers = "Headers"
    case exchange = "HTTP"
    case logs = "Console"

    var id: String { rawValue }
}

private enum WebSocketTranscriptFilter: String, CaseIterable, Identifiable {
    case all = "All Messages"
    case incoming = "Incoming"
    case outgoing = "Outgoing"
    case system = "Events"

    var id: String { rawValue }

    func includes(_ direction: WebSocketTranscriptDirection) -> Bool {
        switch self {
        case .all:
            return true
        case .incoming:
            return direction == .incoming
        case .outgoing:
            return direction == .outgoing
        case .system:
            return direction == .system
        }
    }
}

private struct ResponsePane: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var selectedPane: ResponseTab = .response
    @State private var transcriptSearchText = ""
    @State private var transcriptFilter: WebSocketTranscriptFilter = .all
    @State private var consoleSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 18) {
                    ForEach(availablePanes) { pane in
                        paneButton(pane)
                    }
                }

                Spacer()

                if tab.request.transportKind == .webSocket {
                    Text(tab.webSocketConnectionState.displayName)
                        .foregroundStyle(webSocketStateColor)
                    Text("•")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("\(tab.webSocketTranscript.count) events")
                        .foregroundStyle(PostmanTheme.textSecondary)
                } else if let response = tab.response {
                    Text("\(response.statusCode) \(response.statusText)")
                        .foregroundStyle(statusColor(response.statusCode))
                    Text("•")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("\(Int(response.durationMilliseconds)) ms")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("•")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("\(response.sizeBytes) bytes")
                        .foregroundStyle(PostmanTheme.textSecondary)
                } else if tab.isSending {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Sending request...")
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }
                } else {
                    Text("Send a request to visualize response")
                        .foregroundStyle(PostmanTheme.textSecondary)
                }

                Button {
                    copyCurrentPaneContent()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(!canCopyCurrentPaneContent)

                Button {
                    viewModel.saveResponseToDisk()
                } label: {
                    Text(tab.request.transportKind == .webSocket ? "Save Transcript" : "Save Response")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(tab.request.transportKind == .webSocket ? tab.webSocketTranscript.isEmpty : tab.response == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(PostmanTheme.panel)

            Divider().overlay(PostmanTheme.border)

            Group {
                switch selectedPane {
                case .transcript:
                    transcriptViewer
                case .response:
                    VStack(alignment: .leading, spacing: 0) {
                        if tab.isSending {
                            loadingPlaceholder
                                .padding(18)
                        } else if let response = tab.response {
                            responseViewer(for: response)
                                .padding(18)
                        } else {
                            responsePlaceholder
                                .padding(18)
                        }
                    }
                case .headers:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if tab.isSending {
                                loadingPlaceholder
                            } else {
                                ForEach(tab.response?.headers ?? []) { header in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(header.key)
                                            .font(.body.monospaced())
                                            .foregroundStyle(PostmanTheme.textPrimary)
                                            .frame(width: 220, alignment: .leading)
                                        Text(header.value)
                                            .font(.body.monospaced())
                                            .foregroundStyle(PostmanTheme.textSecondary)
                                            .textSelection(.enabled)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding(18)
                    }
                case .exchange:
                    exchangeViewer
                case .logs:
                    consoleViewer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PostmanTheme.appBackground)
        }
        .onAppear {
            ensureValidSelectedPane()
        }
        .onChange(of: tab.request.transportKind) { _, _ in
            ensureValidSelectedPane()
        }
    }

    private var exchangeViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rawHTTPSection(
                    title: tab.request.transportKind == .webSocket ? "Handshake" : "Request",
                    text: tab.rawRequestText,
                    placeholder: tab.isSending
                        ? (tab.request.transportKind == .webSocket ? "Preparing handshake..." : "Capturing request...")
                        : (tab.request.transportKind == .webSocket ? "Connect to capture the WebSocket handshake request." : "Send a request to capture the raw HTTP request.")
                )

                rawHTTPSection(
                    title: tab.request.transportKind == .webSocket ? "Notes" : "Response",
                    text: tab.rawResponseText,
                    placeholder: tab.request.transportKind == .webSocket
                        ? "Incoming frames are shown in the Transcript tab."
                        : (tab.isSending ? "Waiting for response..." : "Send a request to capture the raw HTTP response.")
                )
            }
            .padding(18)
        }
    }

    private var consoleViewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                terminalWindowDot(Color(nsColor: .systemRed))
                terminalWindowDot(Color(nsColor: .systemYellow))
                terminalWindowDot(Color(nsColor: .systemGreen))

                Text(tab.request.transportKind == .webSocket ? "websocket-console" : "response-console")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(PostmanTheme.textSecondary)

                Spacer()

                Text(consoleSummaryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(PostmanTheme.textSecondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(consoleHeaderBackground)

            Divider().overlay(PostmanTheme.border)

            consoleSearchField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(consoleHeaderBackground)

            Divider().overlay(PostmanTheme.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tab.isSending {
                        loadingPlaceholder
                            .padding(.vertical, 24)
                    } else if tab.consoleLogs.isEmpty {
                        Text("No console output yet.")
                            .font(.body.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if filteredConsoleLogEntries.isEmpty {
                        Text("No lines match “\(consoleSearchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                            .font(.body.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(filteredConsoleLogEntries, id: \.index) { entry in
                            consoleLineRow(index: entry.index, line: entry.line)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(consoleBackground)
        }
        .background(consoleBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
        .padding(18)
    }

    private var transcriptViewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                transcriptSearchField

                Picker("Messages", selection: $transcriptFilter) {
                    ForEach(WebSocketTranscriptFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Button("Clear Messages", systemImage: "trash") {
                    tab.webSocketTranscript.removeAll()
                    transcriptSearchText = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(tab.webSocketTranscript.isEmpty)

                Spacer()

                if tab.request.transportKind == .webSocket {
                    Text(tab.webSocketConnectionState.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(webSocketStateColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(webSocketStateColor.opacity(0.16), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(PostmanTheme.border)

            if tab.request.webSocketPingIntervalSeconds > 0 {
                pingSummaryView
                Divider().overlay(PostmanTheme.border)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredTranscriptEntries.isEmpty {
                        Text(tab.webSocketTranscript.isEmpty ? "No WebSocket messages yet." : "No messages match the current filters.")
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(Array(filteredTranscriptEntries.enumerated()), id: \.element.id) { _, entry in
                            transcriptRow(for: entry)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var pingSummaryView: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(PostmanTheme.orange)
                .frame(width: 30, height: 30)
                .background(PostmanTheme.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Ping Monitor")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(pingSummaryText)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Count: \(tab.webSocketPingSentCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text("Interval: \(formattedWebSocketSeconds(tab.request.webSocketPingIntervalSeconds))")
                    .font(.caption.monospaced())
                    .foregroundStyle(PostmanTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PostmanTheme.panel.opacity(0.45))
    }

    private var availablePanes: [ResponseTab] {
        if tab.request.transportKind == .webSocket {
            return [.transcript, .exchange, .logs]
        }
        return [.response, .headers, .exchange, .logs]
    }

    private func paneButton(_ tab: ResponseTab) -> some View {
        Button {
            selectedPane = tab
        } label: {
            Text(tab.rawValue)
                .foregroundStyle(selectedPane == tab ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if selectedPane == tab {
                        Rectangle()
                            .fill(PostmanTheme.orange)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ensureValidSelectedPane() {
        if !availablePanes.contains(selectedPane) {
            selectedPane = availablePanes.first ?? .logs
        }
    }

    private var responsePlaceholder: some View {
        Text("No response yet.")
            .foregroundStyle(PostmanTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func responseViewer(for response: HTTPResponseModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(documentTypeLabel(for: response))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(PostmanTheme.panel, in: Capsule())

                if let mimeType = response.mimeType, !mimeType.isEmpty {
                    Text(mimeType)
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary)
                }

                Spacer()
            }

            MacCodeEditor(
                text: .constant(response.body),
                language: responseEditorLanguage(for: response),
                showsLineNumbers: false,
                isEditable: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(tab.request.transportKind == .webSocket ? "Connecting WebSocket..." : "Sending request...")
                .foregroundStyle(PostmanTheme.textPrimary)
            Text(
                tab.request.transportKind == .webSocket
                    ? "Waiting for the handshake and the first incoming frames."
                    : "Waiting for response, headers, and console output."
            )
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func rawHTTPSection(title: String, text: String?, placeholder: String) -> some View {
        let display: String = {
            guard let text, !text.isEmpty else { return placeholder }
            return text
        }()
        let isPlaceholder = text?.isEmpty ?? true

        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)

            Text(display)
                .font(.body.monospaced())
                .foregroundStyle(isPlaceholder ? PostmanTheme.textSecondary : PostmanTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
        }
    }

    private func responseEditorLanguage(for response: HTTPResponseModel) -> CodeEditorLanguage {
        let mimeType = response.mimeType?.lowercased() ?? ""
        let body = response.body.trimmingCharacters(in: .whitespacesAndNewlines)

        if mimeType.contains("json") || body.hasPrefix("{") || body.hasPrefix("[") {
            return .json
        }

        if mimeType.contains("html") || body.lowercased().contains("<html") {
            return .html
        }

        if mimeType.contains("xml") || body.hasPrefix("<") {
            return .xml
        }

        if mimeType.contains("markdown") {
            return .markdown
        }

        return .plainText
    }

    private func documentTypeLabel(for response: HTTPResponseModel) -> String {
        switch responseEditorLanguage(for: response) {
        case .json:
            return "JSON"
        case .xml:
            return "XML"
        case .html:
            return "HTML"
        case .javascript:
            return "JavaScript"
        case .markdown:
            return "Markdown"
        case .plainText:
            return "Text"
        }
    }

    private func statusColor(_ statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300:
            return PostmanTheme.green
        case 400..<600:
            return .red
        default:
            return PostmanTheme.textPrimary
        }
    }

    private var webSocketStateColor: Color {
        switch tab.webSocketConnectionState {
        case .connected:
            return PostmanTheme.green
        case .failed:
            return PostmanTheme.salmon
        case .connecting, .disconnecting:
            return PostmanTheme.orange
        case .disconnected:
            return PostmanTheme.textSecondary
        }
    }

    private func transcriptColor(for direction: WebSocketTranscriptDirection) -> Color {
        switch direction {
        case .incoming:
            return PostmanTheme.green
        case .outgoing:
            return PostmanTheme.accent
        case .system:
            return PostmanTheme.orange
        }
    }

    private func consoleLineCopyButton(line: String) -> some View {
        Button {
            PlatformClipboard.copyPlainText(line)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PostmanTheme.textSecondary.opacity(0.85))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 22, minHeight: 22)
        .help("Copiar solo esta línea")
        .accessibilityLabel("Copiar esta línea al portapapeles")
    }

    private func consoleLineRow(index: Int, line: String) -> some View {
        Group {
            if let inline = WorkspaceFlowInlineImageLogLine.parse(line) {
                HStack(alignment: .top, spacing: 12) {
                    Text(String(format: "%03d", index + 1))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)

                    Text("▣")
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 14, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(inline.caption)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        if let nsImage = NSImage(contentsOf: inline.fileURL) {
                            Image(nsImage: nsImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 280, maxHeight: 280)
                                .padding(6)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("PNG no disponible (temporal borrado o ruta inválida).")
                                .font(.caption.monospaced())
                                .foregroundStyle(PostmanTheme.salmon)
                        }

                        Text(inline.fileURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary.opacity(0.85))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    consoleLineCopyButton(line: line)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.015))
            } else if let md = MarkdownLogFormatting.attributedLogLine(line) {
                HStack(alignment: .top, spacing: 12) {
                    Text(String(format: "%03d", index + 1))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)

                    Text("MD")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 18, alignment: .leading)

                    Text(md)
                        .font(.system(size: 13))
                        .foregroundStyle(PostmanTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    consoleLineCopyButton(line: line)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.015))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Text(String(format: "%03d", index + 1))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)

                    Text(consolePrompt(for: line))
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(consoleColor(for: line))
                        .frame(width: 14, alignment: .leading)

                    Text(line)
                        .font(.body.monospaced())
                        .foregroundStyle(consoleColor(for: line))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    consoleLineCopyButton(line: line)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.015))
            }
        }
    }

    private func consolePrompt(for line: String) -> String {
        let normalized = line.lowercased()
        if normalized.hasPrefix("error") || normalized.contains(" error") {
            return "!"
        }
        if normalized.contains("completed successfully") || normalized.contains("connected.") || normalized.contains("reconnected.") {
            return ">"
        }
        if normalized.contains("warning") || normalized.contains("reconnect") {
            return "~"
        }
        return "$"
    }

    private func consoleColor(for line: String) -> Color {
        let normalized = line.lowercased()
        if normalized.hasPrefix("error") || normalized.contains(" error") {
            return PostmanTheme.salmon
        }
        if normalized.contains("completed successfully") || normalized.contains("connected.") || normalized.contains("reconnected.") {
            return PostmanTheme.green
        }
        if normalized.contains("warning") || normalized.contains("reconnect") {
            return PostmanTheme.orange
        }
        return PostmanTheme.textPrimary
    }

    private func terminalWindowDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var consoleSummaryText: String {
        if tab.isSending {
            return tab.request.transportKind == .webSocket ? "connecting..." : "sending..."
        }
        let total = tab.consoleLogs.count
        let query = consoleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, total > 0 else {
            return "\(total) line" + (total == 1 ? "" : "s")
        }
        let shown = filteredConsoleLogEntries.count
        return "\(shown) of \(total) lines"
    }

    /// Líneas de contexto por encima y debajo de cada coincidencia, y **todo el tramo** entre la primera y la última coincidencia,
    /// para que permanezcan visibles los `PASS`/`FAIL` de `pm.test` y el resto del log de los casos en esa ejecución.
    private static let consoleSearchNeighborLineCount = 4

    /// Pairs `(originalLineIndex, line)` for display; indices are 0-based into `tab.consoleLogs`.
    private var filteredConsoleLogEntries: [(index: Int, line: String)] {
        let query = consoleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let logs = tab.consoleLogs
        let enumerated = Array(logs.enumerated())
        guard !query.isEmpty else {
            return enumerated.map { ($0.offset, $0.element) }
        }
        let matchIndices = enumerated.compactMap { idx, line in
            lineMatchesConsoleSearch(line, query: query) ? idx : nil
        }
        guard let firstMatch = matchIndices.min(), let lastMatch = matchIndices.max() else {
            return []
        }
        let radius = Self.consoleSearchNeighborLineCount
        let lo = max(0, firstMatch - radius)
        let hi = min(logs.count - 1, lastMatch + radius)
        return (lo...hi).map { index in (index, logs[index]) }
    }

    private func lineMatchesConsoleSearch(_ line: String, query: String) -> Bool {
        if line.localizedCaseInsensitiveContains(query) {
            return true
        }
        if let inline = WorkspaceFlowInlineImageLogLine.parse(line) {
            if inline.caption.localizedCaseInsensitiveContains(query) { return true }
            if inline.fileURL.path.localizedCaseInsensitiveContains(query) { return true }
            if inline.fileURL.lastPathComponent.localizedCaseInsensitiveContains(query) { return true }
        }
        return false
    }

    private var consoleSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: $consoleSearchText, placeholder: "Search console…")
            if !consoleSearchText.isEmpty {
                Button {
                    consoleSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PostmanTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        .help("Matches plus nearby lines and everything between the first and last match (keeps pm.test PASS/FAIL and run context).")
    }

    private var consoleBackground: Color {
        Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1))
    }

    private var consoleHeaderBackground: Color {
        Color(nsColor: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1))
    }

    private var filteredTranscriptEntries: [WebSocketTranscriptEntry] {
        Array(
            tab.webSocketTranscript
            .filter { entry in
                transcriptFilter.includes(entry.direction)
            }
            .filter { entry in
                let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                return entry.body.localizedCaseInsensitiveContains(query)
                    || entry.direction.rawValue.localizedCaseInsensitiveContains(query)
            }
            .reversed()
        )
    }

    private var transcriptSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: $transcriptSearchText, placeholder: "Search")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
        .frame(maxWidth: 300)
    }

    private func transcriptRow(for entry: WebSocketTranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: transcriptIcon(for: entry.direction))
                .font(.headline.weight(.semibold))
                .foregroundStyle(transcriptColor(for: entry.direction))
                .frame(width: 28, height: 28)
                .background(transcriptColor(for: entry.direction).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(transcriptTitle(for: entry.direction))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Text(transcriptPreview(for: entry.body))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(entry.createdAt.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary)
                }

                Text(entry.body)
                    .font(.body.monospaced())
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
    }

    private func transcriptTitle(for direction: WebSocketTranscriptDirection) -> String {
        switch direction {
        case .incoming:
            return "Incoming"
        case .outgoing:
            return "Outgoing"
        case .system:
            return "Event"
        }
    }

    private func transcriptIcon(for direction: WebSocketTranscriptDirection) -> String {
        switch direction {
        case .incoming:
            return "arrow.down"
        case .outgoing:
            return "arrow.up"
        case .system:
            return "checkmark.circle"
        }
    }

    private func transcriptPreview(for body: String) -> String {
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(firstLine.prefix(80))
    }

    private var pingSummaryText: String {
        if let lastPing = tab.webSocketLastPingSentAt {
            return "Last sent at \(lastPing.formatted(date: .omitted, time: .standard))."
        }
        return "No ping frames sent yet in this session."
    }

    private func formattedWebSocketSeconds(_ value: Double) -> String {
        if value == 0 {
            return "0s"
        }
        if value.rounded() == value {
            return "\(Int(value))s"
        }
        return "\(value.formatted())s"
    }

    private var canCopyCurrentPaneContent: Bool {
        switch selectedPane {
        case .transcript:
            return !tab.webSocketTranscript.isEmpty
        case .response:
            return tab.response?.body.isEmpty == false
        case .headers:
            return !(tab.response?.headers.isEmpty ?? true)
        case .exchange:
            return !(tab.rawRequestText?.isEmpty ?? true) || !(tab.rawResponseText?.isEmpty ?? true)
        case .logs:
            return !filteredConsoleLogEntries.isEmpty
        }
    }

    private func copyCurrentPaneContent() {
        let content: String

        switch selectedPane {
        case .transcript:
            guard !tab.webSocketTranscript.isEmpty else { return }
            content = tab.webSocketTranscript
                .map { "[\($0.createdAt.formatted(date: .omitted, time: .standard))] \($0.direction.rawValue.uppercased()): \($0.body)" }
                .joined(separator: "\n\n")
        case .response:
            guard let body = tab.response?.body, !body.isEmpty else { return }
            content = body
        case .headers:
            let headers = tab.response?.headers ?? []
            guard !headers.isEmpty else { return }
            content = headers
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        case .exchange:
            let sections = [
                tab.rawRequestText.map { "Request\n\($0)" },
                tab.rawResponseText.map { "Response\n\($0)" },
            ]
            .compactMap { $0 }

            guard !sections.isEmpty else { return }
            content = sections.joined(separator: "\n\n")
        case .logs:
            guard !filteredConsoleLogEntries.isEmpty else { return }
            content = filteredConsoleLogEntries.map(\.line).joined(separator: "\n")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }
}

private struct EnvironmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    let environmentID: UUID
    @State private var editableEnvironment: EnvironmentProfile

    init(viewModel: MainViewModel, tab: RequestTabState, environment: EnvironmentProfile) {
        self.viewModel = viewModel
        self.tab = tab
        self.environmentID = environment.id
        var initialEnvironment = environment
        if (tab.selectedEnvironmentID ?? viewModel.workspace.activeEnvironmentID) == environment.id,
           let pendingVariables = tab.pendingEnvironmentVariables {
            initialEnvironment.variables = pendingVariables
        }
        self._editableEnvironment = State(initialValue: initialEnvironment)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Edit Environment")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        Spacer()

                        Button {
                            dismiss()
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

                    DarkTextInput(text: environmentNameBinding, placeholder: "Environment Name")
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                    EditableVariableList(variables: environmentVariablesBinding)
                }
                .padding(24)
            }

            Divider()
                .overlay(PostmanTheme.border)

            HStack {
                Button {
                    commitChanges()
                    dismiss()
                } label: {
                    Text("Close")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)

                Spacer()

                Button {
                    commitChanges()
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 460)
        .background(PostmanTheme.appBackground)
        .onDisappear {
            commitChanges()
        }
    }

    private func commitChanges() {
        guard let currentEnvironment = viewModel.workspace.environments.first(where: { $0.id == environmentID }) else {
            return
        }

        guard currentEnvironment != editableEnvironment else {
            return
        }

        viewModel.updateEnvironment(editableEnvironment)
    }

    private var environmentNameBinding: Binding<String> {
        Binding(
            get: { editableEnvironment.name },
            set: { newValue in
                var updated = editableEnvironment
                updated.name = newValue
                editableEnvironment = updated
            }
        )
    }

    private var environmentVariablesBinding: Binding<[VariableValue]> {
        Binding(
            get: { editableEnvironment.variables },
            set: { newValue in
                var updated = editableEnvironment
                updated.variables = newValue
                editableEnvironment = updated
            }
        )
    }
}

private struct RenameRequestTarget: Identifiable {
    let collection: CollectionModel
    let node: CollectionNode

    var id: UUID { node.id }
}

private struct EnvironmentCloneDraft: Identifiable {
    let id = UUID()
    let source: EnvironmentProfile
}

private struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let validationMessage: ((String) -> String?)?
    @State private var value: String
    let onSave: (String) -> Void

    init(
        title: String,
        initialValue: String,
        validationMessage: ((String) -> String?)? = nil,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.validationMessage = validationMessage
        self._value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentValidationMessage: String? {
        validationMessage?(value)
    }

    private var canSave: Bool {
        !trimmedValue.isEmpty && currentValidationMessage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)

                Spacer()

                Button {
                    dismiss()
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

            DarkTextInput(
                text: $value,
                placeholder: "Name",
                onSubmit: {
                    guard canSave else { return }
                    onSave(trimmedValue)
                    dismiss()
                }
            )
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            if let currentValidationMessage {
                Text(currentValidationMessage)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.salmon)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)

                Button {
                    onSave(trimmedValue)
                    dismiss()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                .opacity(canSave ? 1 : 0.55)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 420, height: currentValidationMessage == nil ? 170 : 194)
        .background(PostmanTheme.appBackground)
    }
}

private struct TextInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let isProcessing: Bool
    let processingTitle: String
    let output: String?
    let autoDismissOnComplete: Bool
    @State private var value: String
    @State private var didSubmit = false
    private let outputBottomAnchor = "text-input-sheet-output-bottom"
    let onSave: (String) -> Void

    init(
        title: String,
        placeholder: String,
        initialValue: String,
        isProcessing: Bool = false,
        processingTitle: String = "Saving...",
        output: String? = nil,
        autoDismissOnComplete: Bool = true,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.isProcessing = isProcessing
        self.processingTitle = processingTitle
        self.output = output
        self.autoDismissOnComplete = autoDismissOnComplete
        self._value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)

                Spacer()

                Button {
                    dismiss()
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

            Text(placeholder)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            DarkTextInput(
                text: $value,
                placeholder: placeholder,
                isEnabled: !isProcessing,
                onSubmit: submit
            )
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            if output?.isEmpty == false {
                HStack {
                    Text("Output")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)

                    Spacer()

                    Button("Copy") {
                        copyOutput()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.accent)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(output ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(PostmanTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)

                            Color.clear
                                .frame(height: 1)
                                .id(outputBottomAnchor)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
                    .onAppear {
                        proxy.scrollTo(outputBottomAnchor, anchor: .bottom)
                    }
                    .onChange(of: output ?? "") { _, _ in
                        proxy.scrollTo(outputBottomAnchor, anchor: .bottom)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(didSubmit && !isProcessing && !autoDismissOnComplete ? "Accept" : "Cancel")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(isProcessing && autoDismissOnComplete)
                .opacity(isProcessing ? 0.55 : 1)

                if !(didSubmit && !isProcessing && !autoDismissOnComplete) {
                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(isProcessing ? processingTitle : "Connect")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isProcessing || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity((isProcessing || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.7 : 1)
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: output?.isEmpty == false ? 520 : 220)
        .background(PostmanTheme.appBackground)
        .onChange(of: isProcessing) { _, newValue in
            guard autoDismissOnComplete, didSubmit, !newValue else { return }
            dismiss()
        }
    }

    private func submit() {
        guard !isProcessing else { return }
        didSubmit = true
        onSave(value)
    }

    private func copyOutput() {
        guard let output, !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }
}

private struct GitCredentialsSheet: View {
    let prompt: MainViewModel.GitCredentialPrompt
    let onCancel: () -> Void
    let onSave: (GitCredentialMode, String, String) -> Void
    @State private var mode: GitCredentialMode
    @State private var username: String
    @State private var secret = ""

    init(
        prompt: MainViewModel.GitCredentialPrompt,
        onCancel: @escaping () -> Void,
        onSave: @escaping (GitCredentialMode, String, String) -> Void
    ) {
        self.prompt = prompt
        self.onCancel = onCancel
        self.onSave = onSave
        _mode = State(initialValue: prompt.preferredMode)
        _username = State(initialValue: Self.defaultUsername(for: prompt))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Git Authentication")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)

                Spacer()

                Button {
                    onCancel()
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
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(PostmanTheme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(prompt.message)
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    infoRow("Provider", value: prompt.provider.displayLabel)
                    infoRow("Remote", value: prompt.remoteURL)
                    infoRow("How to authenticate", value: prompt.instructions)

                    HStack(alignment: .center, spacing: 12) {
                        Text("Auth")
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .frame(width: 60, alignment: .leading)

                        Picker("Auth", selection: $mode) {
                            ForEach(availableModes, id: \.self) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(usernameTitle)
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                        DarkTextInput(text: $username, placeholder: "Username")
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(secretTitle)
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                        DarkTextInput(text: $secret, placeholder: secretTitle, isSecure: true)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(PostmanTheme.border)

            HStack {
                Button {
                    if let helpURL = prompt.helpURL {
                        NSWorkspace.shared.open(helpURL)
                    }
                } label: {
                    Text("Open Help")
                        .frame(width: 110, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                .opacity(prompt.helpURL == nil ? 0.5 : 1)
                .disabled(prompt.helpURL == nil)

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Text("Close")
                        .frame(width: 110, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Button {
                    onSave(mode, username, secret)
                } label: {
                    Text("Connect")
                        .frame(width: 120, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                .opacity(canSubmit ? 1 : 0.55)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 760, height: 560)
        .background(PostmanTheme.appBackground)
        .onChange(of: mode) { _, newMode in
            if newMode == .token && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                username = Self.defaultUsername(for: prompt)
            }
        }
    }

    private var availableModes: [GitCredentialMode] {
        switch prompt.provider {
        case .bitbucket:
            return [.token]
        case .github, .gitlab, .unknown:
            return GitCredentialMode.allCases
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
            Text(value)
                .foregroundStyle(PostmanTheme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private var usernameTitle: String {
        switch (prompt.provider, mode) {
        case (.bitbucket, _):
            return "Username"
        case (_, .usernamePassword):
            return "Username"
        case (_, .token):
            return "Username (Optional)"
        }
    }

    private var secretTitle: String {
        switch (prompt.provider, mode) {
        case (.bitbucket, .token):
            return "API Token / App Password"
        case (.bitbucket, .usernamePassword):
            return "API Token / App Password"
        case (_, .usernamePassword):
            return "Password"
        case (_, .token):
            return "Token / API Key"
        }
    }

    private var canSubmit: Bool {
        let hasSecret = !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch (prompt.provider, mode) {
        case (.bitbucket, _):
            return hasSecret && hasUsername
        case (_, .usernamePassword):
            return hasSecret && hasUsername
        case (_, .token):
            return hasSecret
        }
    }

    private static func defaultUsername(for prompt: MainViewModel.GitCredentialPrompt) -> String {
        guard prompt.preferredMode == .token else {
            return ""
        }

        switch prompt.provider {
        case .github:
            return "x-access-token"
        case .gitlab:
            return "oauth2"
        case .bitbucket, .unknown:
            return ""
        }
    }
}

private struct EditableVariableList: View {
    @Binding var variables: [VariableValue]
    @State private var previewPayload: CodeValuePreviewPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Variables")
                    .font(.headline)
                    .foregroundStyle(PostmanTheme.textPrimary)
                Spacer()
                Button {
                    variables.append(VariableValue())
                } label: {
                    Text("Add Variable")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.accent)
            }

            ForEach(variables.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Toggle("", isOn: binding(for: index, keyPath: \.isEnabled))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    DarkTextInput(text: binding(for: index, keyPath: \.key), placeholder: "Key")
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    DarkTextInput(text: binding(for: index, keyPath: \.value), placeholder: "Value")
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    previewButton(
                        title: variables[index].key.isEmpty ? "Value" : variables[index].key,
                        value: variables[index].value
                    )
                    Button {
                        variables.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $previewPayload) { payload in
            CodeValuePreviewSheet(payload: payload)
                .preferredColorScheme(.dark)
        }
    }

    private func binding<Value>(for index: Int, keyPath: WritableKeyPath<VariableValue, Value>) -> Binding<Value> {
        Binding(
            get: { variables[index][keyPath: keyPath] },
            set: { variables[index][keyPath: keyPath] = $0 }
        )
    }

    private func previewButton(title: String, value: String) -> some View {
        Button("Preview", systemImage: "magnifyingglass") {
            previewPayload = CodeValuePreviewPayload(title: title, value: value)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textSecondary)
        .frame(width: 28, height: 28)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        .accessibilityLabel("Preview \(title)")
    }
}

private func methodPill(_ method: HTTPMethod) -> some View {
    Text(method.rawValue)
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(methodColor(method))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(methodColor(method).opacity(0.15), in: Capsule())
}

private func requestPill(_ request: APIRequestModel) -> some View {
    Group {
        if request.transportKind == .webSocket {
            Text("WS")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(PostmanTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(PostmanTheme.accent.opacity(0.15), in: Capsule())
        } else if request.isLambdaInvoke {
            Text("λ")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(PostmanTheme.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(PostmanTheme.orange.opacity(0.15), in: Capsule())
        } else {
            methodPill(request.method)
        }
    }
}

private func methodColor(_ method: HTTPMethod) -> Color {
    switch method {
    case .get:
        return PostmanTheme.green
    case .post:
        return PostmanTheme.orange
    case .put:
        return .yellow
    case .patch:
        return .mint
    case .delete:
        return .red
    case .head:
        return .teal
    case .options:
        return .blue
    }
}
