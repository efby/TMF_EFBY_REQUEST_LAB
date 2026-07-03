import EfbyPresentation
import SwiftUI

struct WorkspaceUtilityEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var utility: WorkspaceScriptUtility
    let workspaceUtilities: [WorkspaceScriptUtility]
    let nameValidationMessage: (String, UUID?) -> String?
    let sourceValidationMessage: (String, UUID?) -> String?
    let onSave: (WorkspaceScriptUtility) -> Bool

    init(
        utility: WorkspaceScriptUtility,
        workspaceUtilities: [WorkspaceScriptUtility],
        nameValidationMessage: @escaping (String, UUID?) -> String?,
        sourceValidationMessage: @escaping (String, UUID?) -> String?,
        onSave: @escaping (WorkspaceScriptUtility) -> Bool
    ) {
        self._utility = State(initialValue: utility)
        self.workspaceUtilities = workspaceUtilities
        self.nameValidationMessage = nameValidationMessage
        self.sourceValidationMessage = sourceValidationMessage
        self.onSave = onSave
    }

    private var currentValidationMessage: String? {
        nameValidationMessage(utility.name, utility.id)
            ?? sourceValidationMessage(utility.source, utility.id)
    }

    private var canSave: Bool {
        currentValidationMessage == nil && !utility.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func formatUtilitySource() {
        let formatted = JavaScriptSourceFormatter.format(utility.source)
        if formatted != utility.source {
            utility.source = formatted
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace Utility")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        Text("Functions declared here are available in HTTP scripts and WebSocket hooks across the active workspace.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)

                        DarkTextInput(text: $utility.name, placeholder: "Utility name")
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)

                        Toggle(isOn: $utility.isEnabled) {
                            Text(utility.isEnabled ? "Enabled" : "Disabled")
                                .foregroundStyle(PostmanTheme.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                    .frame(width: 180)
                }

                if let currentValidationMessage {
                    Text(currentValidationMessage)
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.salmon)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("JavaScript Source")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)

                        Spacer()

                        Button {
                            formatUtilitySource()
                        } label: {
                            Text("Format")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PostmanTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(PostmanTheme.panel, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Text("Global scope")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(PostmanTheme.panel, in: Capsule())
                    }

                    MacCodeEditor(
                        text: $utility.source,
                        language: .javascript,
                        showsLineNumbers: true,
                        autocompleteContext: .javascript(workspaceUtilities: workspaceUtilities)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
                }
            }
            .padding(24)

            Divider()
                .overlay(PostmanTheme.border)

            HStack {
                Button {
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
                    guard canSave else { return }
                    utility.name = utility.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    formatUtilitySource()
                    if onSave(utility) {
                        dismiss()
                    }
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(width: 120, height: 34)
                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                .opacity(canSave ? 1 : 0.55)
                .disabled(!canSave)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(PostmanTheme.appBackground)
    }
}
