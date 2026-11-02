import SwiftUI

struct TopChromeBar: View {
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
                        .accessibilityIdentifier("workspace.option.\(name)")
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
                .accessibilityIdentifier("workspace.selector")
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
