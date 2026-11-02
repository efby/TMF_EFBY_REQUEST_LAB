import EfbyPresentation
import SwiftUI

struct SidebarPane: View {
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
                                .accessibilityIdentifier("sidebar.history.\(entry.id.uuidString)")
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

private struct RenameRequestTarget: Identifiable {
    let collection: CollectionModel
    let node: CollectionNode

    var id: UUID { node.id }
}
