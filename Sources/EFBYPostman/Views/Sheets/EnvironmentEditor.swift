import EfbyPresentation
import SwiftUI

struct EnvironmentEditor: View {
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
                            .accessibilityIdentifier("environment.editor")
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
                        .accessibilityIdentifier("environment.close")
                        .accessibilityLabel("Close Environment")
                    }

                    DarkTextInput(text: environmentNameBinding, placeholder: "Environment Name", controlIdentifier: "environment.name")
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
                .accessibilityIdentifier("environment.done")
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
