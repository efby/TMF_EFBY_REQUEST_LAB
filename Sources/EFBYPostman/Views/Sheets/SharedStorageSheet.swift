import AppKit
import EfbyPresentation
import SwiftUI

enum SharedStorageQuickAction {
    case repo
    case newWorkspace
    case connectGit
    case status
    case pull
    case push
}

struct SharedStorageSheet: View {
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
