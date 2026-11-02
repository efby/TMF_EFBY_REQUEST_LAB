import AppKit
import EfbyPresentation
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
                    .accessibilityIdentifier("workspace.directory.required")
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
