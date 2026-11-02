import AppKit
import EfbyPresentation
import SwiftUI

private extension GitProvider {
    var displayLabel: String {
        displayName
    }
}

struct GitCredentialsSheet: View {
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
