import AppKit
import EfbyPresentation
import SwiftUI
import UniformTypeIdentifiers

struct RequestHeader: View {
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
                            .accessibilityIdentifier("request.name")
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
                    .accessibilityIdentifier("environment.selector")

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
                    .accessibilityIdentifier("environment.edit")
                    .accessibilityLabel("Edit Environment")

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

private struct EnvironmentCloneDraft: Identifiable {
    let id = UUID()
    let source: EnvironmentProfile
}
