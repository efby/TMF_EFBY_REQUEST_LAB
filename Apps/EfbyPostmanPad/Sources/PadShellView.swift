import EfbyPresentation
import Darwin
import SwiftUI
import UIKit

private enum PadShellDevice {
    @MainActor
    static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}

private enum PadSidebarItem: Hashable, Identifiable {
    case home
    case collection(UUID)
    case requestTab(UUID)
    case workspaceFlow(UUID)
    case environment(UUID)

    var id: String {
        switch self {
        case .home: "home"
        case .collection(let id): id.uuidString
        case .requestTab(let id): "tab-\(id.uuidString)"
        case .workspaceFlow(let id): "flow-\(id.uuidString)"
        case .environment(let id): "env-\(id.uuidString)"
        }
    }
}

/// Shell principal optimizado para iPad (NavigationSplitView + contenido desde `MainViewModel` / EfbyPresentation).
struct PadShellView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var selectedItem: PadSidebarItem? = .home
    @State private var bitbucketCloneURL: String = ""
    @State private var bitbucketBranch: String = ""
    @State private var bitbucketUser: String = ""
    @State private var bitbucketAppPassword: String = ""
    /// Evita leer el llavero en cada render del `body`.
    @State private var hasBitbucketKeychainToken: Bool = false

    private var padWorkspacePickerSelection: Binding<String> {
        Binding(
            get: {
                let names = viewModel.availableWorkspaceNames
                let current = viewModel.workspace.activeWorkspaceName
                if let current, names.contains(current) { return current }
                return names.first ?? ""
            },
            set: { name in
                guard !name.isEmpty else { return }
                viewModel.selectWorkspace(named: name)
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.cyan)
        .padKeyboardDismissToolbar()
        .onChange(of: selectedItem) { _, newItem in
            if case .requestTab(let tid) = newItem {
                viewModel.selectedTabID = tid
            }
        }
        .onChange(of: viewModel.workspace.activeWorkspaceName) { _, _ in
            selectedItem = .home
        }
    }

    /// Cierra la pestaña, ajusta el destino del split si hacía falta y evita que `selectedTabID` salte a otra colección.
    private func closePadRequestTab(_ tab: RequestTabState) {
        if case .requestTab(let tid) = selectedItem, tid == tab.id {
            if let cid = tab.sourceCollectionID {
                selectedItem = .collection(cid)
            } else {
                selectedItem = .home
            }
        }

        let sourceCollectionID = tab.sourceCollectionID
        viewModel.closeTab(tab)

        guard let cid = sourceCollectionID else { return }
        let peers = viewModel.tabs.filter { $0.sourceCollectionID == cid }
        guard let sid = viewModel.selectedTabID else {
            viewModel.selectedTabID = peers.first?.id ?? viewModel.tabs.last?.id
            return
        }
        guard viewModel.tabs.contains(where: { $0.id == sid }) else {
            viewModel.selectedTabID = peers.first?.id ?? viewModel.tabs.last?.id
            return
        }
        if !peers.isEmpty, !peers.contains(where: { $0.id == sid }) {
            viewModel.selectedTabID = peers.first?.id
        }
    }

    @MainActor
    private func openRequestFromSidebar(_ node: CollectionNode, collection: CollectionModel) async {
        guard node.kind == .request else { return }
        await viewModel.open(request: node, in: collection)
        if let tab = viewModel.tabs.first(where: { $0.sourceNodeID == node.id && $0.sourceCollectionID == collection.id }) {
            selectedItem = .requestTab(tab.id)
        }
    }

    private var sidebar: some View {
        List(selection: $selectedItem) {
            Section {
                Label("Inicio", systemImage: "house.fill")
                    .tag(PadSidebarItem.home)
            }

            Section("Flows") {
                if viewModel.workspace.flows.isEmpty {
                    Text("Sin flows en el workspace")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.workspace.flows) { flow in
                        Label(flow.name, systemImage: "arrow.triangle.branch")
                            .tag(PadSidebarItem.workspaceFlow(flow.id))
                    }
                }
            }

            Section("Workspace") {
                if viewModel.availableWorkspaceNames.isEmpty {
                    Text(viewModel.activeWorkspaceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Workspace activo", selection: padWorkspacePickerSelection) {
                        ForEach(viewModel.availableWorkspaceNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("Colecciones") {
                if viewModel.workspace.collections.isEmpty {
                    Text("Sin colecciones")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.workspace.collections) { collection in
                        DisclosureGroup {
                            PadSidebarRequestList(
                                nodes: collection.items,
                                collection: collection,
                                viewModel: viewModel
                            ) { node in
                                await openRequestFromSidebar(node, collection: collection)
                            }
                        } label: {
                            Label(collection.info.name, systemImage: "folder.fill")
                        }
                    }
                }
            }

            Section("Entornos") {
                if viewModel.workspace.environments.isEmpty {
                    Text("Sin entornos")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.workspace.environments) { env in
                        Label(env.name, systemImage: env.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(env.isEnabled ? .primary : .secondary)
                            .tag(PadSidebarItem.environment(env.id))
                    }
                }
            }

            Section("Almacenamiento") {
                LabeledContent("Repositorio") {
                    Text(shortPath(viewModel.sharedCollectionsDirectoryDescription))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                LabeledContent("Workspace") {
                    Text(viewModel.activeWorkspaceDescription)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("EFBY")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 14) {
                    Button {
                        Task { await viewModel.reloadWorkspaceResyncingBitbucketIfNeeded() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                    .accessibilityLabel("Recargar")

                    Button {
                        exit(0)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cerrar aplicación")
                }
            }
        }
    }

    private var hasPadDetailBanners: Bool {
        let err = (viewModel.errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let info = (viewModel.infoMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !err.isEmpty || !info.isEmpty
    }

    @ViewBuilder
    private var padDetailBanners: some View {
        VStack(spacing: 10) {
            if let message = viewModel.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Aviso", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        viewModel.dismissErrorMessageBanner()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cerrar aviso")
                }
                .padding()
                .background(.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let info = viewModel.infoMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !info.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Información", systemImage: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text(info)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        viewModel.dismissInfoMessageBanner()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cerrar mensaje")
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if hasPadDetailBanners {
                padDetailBanners
                    .padding(.bottom, 8)
            }

            Group {
                switch selectedItem ?? .home {
                case .home:
                    homePanel
                case .collection(let id):
                    collectionPanel(collectionID: id)
                case .requestTab(let id):
                    requestTabPanel(tabID: id)
                case .workspaceFlow(let id):
                    flowPanel(flowID: id)
                case .environment(let id):
                    environmentDetailPanel(environmentID: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
    }

    private var homePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Request Lab")
                    .font(.largeTitle.bold())

                Text("Esta es la app para iPad. Comparte AppCore con la app de Mac; la UI completa de editor y Git avanzado sigue en escritorio.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                    GridRow {
                        statTile(title: "Colecciones", value: "\(viewModel.workspace.collections.count)", icon: "square.stack.3d.up.fill")
                        statTile(title: "Entornos", value: "\(viewModel.workspace.environments.count)", icon: "globe")
                    }
                    GridRow {
                        statTile(
                            title: "Peticiones en sesión",
                            value: "\(viewModel.tabs.count)",
                            icon: "doc.on.doc"
                        )
                        statTile(
                            title: "Carga inicial",
                            value: viewModel.didFinishInitialWorkspaceLoad ? "Lista" : "…",
                            icon: "checkmark.seal"
                        )
                    }
                }

                if let remote = viewModel.gitRemoteDescription {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Git remoto")
                            .font(.headline)
                        Text(remote)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Bitbucket (descarga y sincronización ZIP)")
                        .font(.headline)
                    Text(
                        "Puedes pegar la URL del navegador (…/src/main/…) o la del repo. Si el campo rama está vacío, se usa la rama de la URL o «main». **API token** (Bitbucket Cloud): en «Usuario» pon tu **correo Atlassian** (Personal settings → Email), no el username «efby». **App password** (legacy): usuario = **username** de Bitbucket. Contraseña = token o app password, una sola línea. Tras una descarga correcta se guardan URL, rama y usuario en el workspace; el token se guarda en el **llavero** del iPad (no en el JSON). **Sincronizar** y **Recargar** (barra superior) vuelven a descargar desde Bitbucket y **sustituyen** el contenido local del almacenamiento compartido por el del remoto; **no se sube nada** a Bitbucket desde esta app. La app reintenta ZIP/REST con `x-bitbucket-api-token-auth` si hace falta; si sigue 401, suele ser correo equivocado o token sin scope de lectura del repo."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    TextField("https://bitbucket.org/espacio/repo", text: $bitbucketCloneURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
#endif

                    TextField(
                        "Rama",
                        text: $bitbucketBranch,
                        prompt: Text("Vacío = main o rama de …/src/rama en la URL")
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField("Usuario Bitbucket (opcional, repos públicos vacío)", text: $bitbucketUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Contraseña o token Bitbucket (opcional)", text: $bitbucketAppPassword)

                    if viewModel.isBitbucketArchiveDownloadBusy {
                        ProgressView("Descargando y descomprimiendo…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        viewModel.downloadBitbucketHTTPSRepositoryAndConfigure(
                            cloneHTTPSURL: bitbucketCloneURL,
                            branch: bitbucketBranch,
                            bitbucketUsername: bitbucketUser,
                            bitbucketAppPassword: bitbucketAppPassword
                        )
                    } label: {
                        Label("Descargar y usar como repositorio compartido", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBitbucketArchiveDownloadBusy || bitbucketCloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        viewModel.resyncBitbucketSharedFromBitbucket(
                            cloneHTTPSURL: bitbucketCloneURL,
                            branch: bitbucketBranch,
                            bitbucketUsername: bitbucketUser,
                            bitbucketAppPassword: bitbucketAppPassword
                        )
                    } label: {
                        Label("Sincronizar desde Bitbucket", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        viewModel.isBitbucketArchiveDownloadBusy
                            || viewModel.sharedRepositoryURL == nil
                            || !canResyncBitbucket
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .task(id: bitbucketWorkspaceHydrationTaskID) {
                    hydrateBitbucketFieldsIfNeeded()
                    refreshBitbucketKeychainTokenFlag()
                }
                .onChange(of: viewModel.isBitbucketArchiveDownloadBusy) { _, busy in
                    if !busy {
                        refreshBitbucketKeychainTokenFlag()
                    }
                }

                Text("En **Colecciones** despliega una carpeta y toca una petición: se abre el editor completo (URL, Request, Script, Response, consola). En **Flows** tienes diagrama de solo lectura, runs batch y ejecución completa (el editor BPMN visual sigue en Mac).")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
        }
    }

    private func collectionPanel(collectionID: UUID) -> some View {
        Group {
            if let collection = viewModel.workspace.collections.first(where: { $0.id == collectionID }) {
                let tabsForCollection = viewModel.tabs.filter { $0.sourceCollectionID == collectionID }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(collection.info.name)
                            .font(.title.bold())
                        if !collection.info.description.isEmpty {
                            Text(collection.info.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Variables de colección", value: "\(collection.variables.count)")

                        if tabsForCollection.isEmpty {
                            Text("Elige una petición en la barra lateral: despliega esta colección y tócala.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    collectionTabsSendSection(collectionID: collection.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Colección no encontrada", systemImage: "folder.badge.questionmark")
            }
        }
    }

    @ViewBuilder
    private func collectionTabsSendSection(collectionID: UUID) -> some View {
        let collectionTabs = viewModel.tabs.filter { $0.sourceCollectionID == collectionID }
        if collectionTabs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Petición abierta")
                        .font(.headline)
                    Spacer()
                    if let current = collectionTabs.first(where: { $0.id == viewModel.selectedTabID })
                        ?? collectionTabs.first
                    {
                        Button(role: .destructive) {
                            closePadRequestTab(current)
                        } label: {
                            Label("Cerrar", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cerrar pestaña")
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(collectionTabs) { tab in
                            let selectedID = collectionTabs.contains(where: { $0.id == viewModel.selectedTabID })
                                ? viewModel.selectedTabID
                                : collectionTabs.first?.id
                            let isSelected = tab.id == selectedID
                            Button {
                                viewModel.selectedTabID = tab.id
                            } label: {
                                HStack(spacing: 6) {
                                    PadRequestSidebarPills.requestPill(tab.request)
                                    Text(tab.request.name)
                                        .lineLimit(1)
                                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected ? Color.cyan.opacity(0.22) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isSelected ? Color.cyan.opacity(0.55) : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if let tab = collectionTabs.first(where: { $0.id == viewModel.selectedTabID })
                    ?? collectionTabs.first
                {
                    PadRequestWorkspaceView(viewModel: viewModel, tab: tab)
                        .id(tab.id)
                        .frame(minHeight: 480, maxHeight: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear {
                let ids = Set(collectionTabs.map(\.id))
                if let sid = viewModel.selectedTabID, ids.contains(sid) { return }
                viewModel.selectedTabID = collectionTabs.first?.id
            }
            .onChange(of: collectionTabs.map(\.id)) { _, newIDs in
                guard let sid = viewModel.selectedTabID, newIDs.contains(sid) else {
                    viewModel.selectedTabID = collectionTabs.first?.id
                    return
                }
            }
        }
    }

    private func flowPanel(flowID: UUID) -> some View {
        Group {
            if let flow = viewModel.workspace.flows.first(where: { $0.id == flowID }) {
                PadFlowDetailView(flow: flow, viewModel: viewModel)
            } else {
                ContentUnavailableView("Flow no encontrado", systemImage: "arrow.triangle.branch")
            }
        }
    }

    private func requestTabPanel(tabID: UUID) -> some View {
        Group {
            if let tab = viewModel.tabs.first(where: { $0.id == tabID }) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        if !PadShellDevice.isPhone {
                            PadRequestSidebarPills.requestPill(tab.request)
                        }
                        Text(tab.request.name)
                            .font(.title2.bold())
                            .lineLimit(1)
                        Spacer()
                        Group {
                            if PadShellDevice.isPhone {
                                Button(role: .destructive) {
                                    closePadRequestTab(tab)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title2)
                                        .symbolRenderingMode(.hierarchical)
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Button(role: .destructive) {
                                    closePadRequestTab(tab)
                                } label: {
                                    Label("Cerrar pestaña", systemImage: "xmark.circle.fill")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .accessibilityLabel("Cerrar pestaña")
                        if !PadShellDevice.isPhone,
                            let cid = tab.sourceCollectionID,
                            viewModel.workspace.collections.contains(where: { $0.id == cid })
                        {
                            Button {
                                selectedItem = .collection(cid)
                            } label: {
                                Label("Colección", systemImage: "folder.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    PadRequestWorkspaceView(viewModel: viewModel, tab: tab)
                        .id(tab.id)
                }
            } else {
                ContentUnavailableView(
                    "Pestaña cerrada",
                    systemImage: "doc.text",
                    description: Text("Esa pestaña ya no existe.")
                )
            }
        }
    }

    private func statTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func shortPath(_ path: String) -> String {
        guard path.count > 48 else { return path }
        let end = path.suffix(40)
        return "…\(end)"
    }

    /// Cambia cuando el workspace guarda URL/rama/usuario Bitbucket para volver a hidratar el formulario.
    private var bitbucketWorkspaceHydrationTaskID: String {
        let u = viewModel.workspace.bitbucketPadCloneHTTPSURL ?? ""
        let b = viewModel.workspace.bitbucketPadBranch ?? ""
        let user = viewModel.workspace.bitbucketPadUsername ?? ""
        return u + "|" + b + "|" + user
    }

    private var effectiveBitbucketCloneURL: String {
        let typed = bitbucketCloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return (viewModel.workspace.bitbucketPadCloneHTTPSURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canResyncBitbucket: Bool {
        guard !effectiveBitbucketCloneURL.isEmpty else { return false }
        let typedPass = bitbucketAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedPass.isEmpty { return true }
        return hasBitbucketKeychainToken
    }

    private func hydrateBitbucketFieldsIfNeeded() {
        if bitbucketCloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let saved = viewModel.workspace.bitbucketPadCloneHTTPSURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !saved.isEmpty
        {
            bitbucketCloneURL = saved
        }
        if bitbucketBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let saved = viewModel.workspace.bitbucketPadBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
            !saved.isEmpty
        {
            bitbucketBranch = saved
        }
        if bitbucketUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let saved = viewModel.workspace.bitbucketPadUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
            !saved.isEmpty
        {
            bitbucketUser = saved
        }
    }

    private func refreshBitbucketKeychainTokenFlag() {
        hasBitbucketKeychainToken = BitbucketPadCredentialStore.loadAPIToken() != nil
    }

    @ViewBuilder
    private func environmentDetailPanel(environmentID: UUID) -> some View {
        if viewModel.workspace.environments.contains(where: { $0.id == environmentID }) {
            PadEnvironmentInspectorView(viewModel: viewModel, environmentID: environmentID)
        } else {
            ContentUnavailableView(
                "Entorno no encontrado",
                systemImage: "globe",
                description: Text("Puede haberse eliminado o haber cambiado el workspace. Elige otro entorno en la barra lateral.")
            )
        }
    }
}

// MARK: - Inspector de entorno (edición + copiar)

private struct PadEnvironmentInspectorView: View {
    @ObservedObject var viewModel: MainViewModel
    let environmentID: UUID

    @State private var draft: EnvironmentProfile = .init(name: "")
    @State private var showDeleteConfirm = false

    private var isWorkspaceActiveBinding: Binding<Bool> {
        Binding(
            get: { viewModel.workspace.activeEnvironmentID == environmentID },
            set: { on in
                if on {
                    viewModel.activateEnvironment(draft)
                } else if viewModel.workspace.activeEnvironmentID == environmentID {
                    viewModel.activateEnvironment(nil)
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre del entorno", text: $draft.name)
                    LabeledContent("ID") {
                        Text(draft.id.uuidString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Toggle("Perfil habilitado (datos / exportación)", isOn: $draft.isEnabled)
                    Toggle("Entorno activo del workspace", isOn: isWorkspaceActiveBinding)
                } header: {
                    Text("Entorno")
                } footer: {
                    Text("El entorno activo es el que usan las pestañas por defecto cuando no eligen otro en la petición.")
                }

                Section {
                    ForEach($draft.variables) { $variable in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Clave", text: $variable.key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Valor", text: $variable.value, axis: .vertical)
                                .lineLimit(3...10)
                                .font(.body.monospaced())
                            Toggle("Variable activa", isOn: $variable.isEnabled)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        draft.variables.remove(atOffsets: offsets)
                    }

                    Button {
                        draft.variables.append(VariableValue())
                    } label: {
                        Label("Añadir variable", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Variables (\(draft.variables.count))")
                } footer: {
                    Text("Clave y valor se sustituyen en URLs y cuerpos como {{nombre}}. Desactiva una variable para ignorarla al resolver.")
                }

                Section {
                    Button(role: .destructive) {
                        persistDraftIfNeeded()
                        showDeleteConfirm = true
                    } label: {
                        Label("Eliminar entorno", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(draft.name.isEmpty ? "Entorno" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .padKeyboardDismissToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        PadPasteboard.copy(Self.fullExportText(for: draft))
                    } label: {
                        Label("Copiar todo", systemImage: "doc.on.doc")
                    }
                    .accessibilityHint("Copia nombre, metadatos, lista de variables y JSON al portapapeles")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        persistDraftIfNeeded()
                    }
                    .fontWeight(.semibold)
                    .disabled(workspaceSnapshot == nil)
                }
            }
            .onAppear {
                reloadDraftFromWorkspace()
            }
            .onChange(of: environmentID) { _, _ in
                persistDraftIfNeeded()
                reloadDraftFromWorkspace()
            }
            .onDisappear {
                persistDraftIfNeeded()
            }
            .confirmationDialog(
                "¿Eliminar el entorno «\(draft.name)»?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Eliminar", role: .destructive) {
                    viewModel.deleteEnvironment(draft)
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se quitará del workspace y de las pestañas que lo usaban. No se puede deshacer.")
            }
        }
    }

    private var workspaceSnapshot: EnvironmentProfile? {
        viewModel.workspace.environments.first(where: { $0.id == environmentID })
    }

    private func reloadDraftFromWorkspace() {
        guard let env = workspaceSnapshot else { return }
        draft = env
    }

    private func persistDraftIfNeeded() {
        guard let current = workspaceSnapshot else { return }
        guard draft != current else { return }
        viewModel.updateEnvironment(draft)
    }

    private static func fullExportText(for environment: EnvironmentProfile) -> String {
        var lines: [String] = []
        lines.append("=== EFBY Request Lab · entorno ===")
        lines.append("Nombre: \(environment.name)")
        lines.append("ID: \(environment.id.uuidString)")
        lines.append("Perfil habilitado en workspace (datos compartidos): \(environment.isEnabled ? "sí" : "no")")
        lines.append("Número de variables: \(environment.variables.count)")
        lines.append("")
        let sorted = environment.variables.sorted {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }
        for v in sorted {
            let state = v.isEnabled ? "activa" : "desactivada"
            lines.append("[\(state)] \(v.key) = \(v.value)")
        }
        lines.append("")
        lines.append("--- JSON (Codable `EnvironmentProfile`) ---")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(environment), let json = String(data: data, encoding: .utf8) {
            lines.append(json)
        } else {
            lines.append("(No se pudo generar JSON.)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Píldoras GET/POST/λ/WS (paridad con escritorio `requestPill` / `methodPill`)

private enum PadRequestSidebarPills {
    private static func methodColor(_ method: HTTPMethod) -> Color {
        switch method {
        case .get: return .green
        case .post: return .orange
        case .put: return .yellow
        case .patch: return .mint
        case .delete: return .red
        case .head: return .teal
        case .options: return .blue
        }
    }

    @ViewBuilder
    static func methodPill(_ method: HTTPMethod) -> some View {
        let tint = methodColor(method)
        Text(method.rawValue)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    static func requestPill(_ request: APIRequestModel) -> some View {
        if request.transportKind == .webSocket {
            Text("WS")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(Color.cyan)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.cyan.opacity(0.15), in: Capsule())
        } else if request.isLambdaInvoke {
            Text("λ")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: Capsule())
        } else {
            methodPill(request.method)
        }
    }
}

// MARK: - Lista de peticiones bajo una colección (sidebar)

private struct PadSidebarRequestList: View {
    let nodes: [CollectionNode]
    let collection: CollectionModel
    @ObservedObject var viewModel: MainViewModel
    let onOpenRequest: (CollectionNode) async -> Void

    var body: some View {
        ForEach(nodes) { node in
            switch node.kind {
            case .folder:
                DisclosureGroup {
                    if !node.children.isEmpty {
                        PadSidebarRequestList(
                            nodes: node.children,
                            collection: collection,
                            viewModel: viewModel,
                            onOpenRequest: onOpenRequest
                        )
                    }
                } label: {
                    Label(node.name, systemImage: "folder.fill")
                }
            case .request:
                Button {
                    Task { await onOpenRequest(node) }
                } label: {
                    HStack(spacing: 8) {
                        if let request = node.request {
                            PadRequestSidebarPills.requestPill(request)
                        } else {
                            PadRequestSidebarPills.methodPill(.get)
                        }
                        Text(node.name)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Flow (visor + runs + ejecución)

private enum PadFlowMainTab: String, CaseIterable, Identifiable {
    case diagram = "Diagrama"
    case liveLog = "Log"
    case runs = "Runs"
    case execute = "Ejecutar"

    var id: String { rawValue }
}

private struct PadFlowDetailView: View {
    let flow: WorkspaceFlowDefinition
    @ObservedObject var viewModel: MainViewModel

    @State private var mainTab: PadFlowMainTab = .diagram
    @State private var graph: WorkspaceFlowGraphSnapshot?
    @State private var graphParseError: String?
    @State private var batchTask: Task<Void, Never>?
    @State private var transcriptCaseID: UUID?
    /// `nil` = usar el entorno activo del workspace (`activeEnvironmentID`).
    @State private var selectedRunEnvironmentID: UUID?

    private var liveFlow: WorkspaceFlowDefinition {
        viewModel.workspace.flows.first(where: { $0.id == flow.id }) ?? flow
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(liveFlow.name)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if !viewModel.workspace.environments.isEmpty {
                HStack {
                    Text("Entorno de ejecución")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Entorno de ejecución", selection: $selectedRunEnvironmentID) {
                        Text("Activo del workspace").tag(Optional<UUID>.none)
                        ForEach(viewModel.workspace.environments) { env in
                            Text(env.name).tag(Optional(env.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Picker("", selection: $mainTab) {
                ForEach(PadFlowMainTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch mainTab {
                case .diagram:
                    diagramPane
                case .liveLog:
                    liveLogPane
                case .runs:
                    runsPane
                case .execute:
                    executePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { refreshParsedGraph() }
        .onChange(of: liveFlow.bpmnXML) { _, _ in refreshParsedGraph() }
        .onDisappear { batchTask?.cancel() }
        .sheet(isPresented: Binding(
            get: { transcriptCaseID != nil },
            set: { if !$0 { transcriptCaseID = nil } }
        )) {
            NavigationStack {
                ScrollView {
                    if let caseID = transcriptCaseID {
                        PadFlowRunLogLinesView(
                            lines: viewModel.workspaceFlowBatchCaseTranscript(flowID: liveFlow.id, caseID: caseID)
                        )
                        .padding()
                    }
                }
                .navigationTitle("Log del caso")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { transcriptCaseID = nil }
                    }
                }
                .padKeyboardDismissToolbar()
            }
        }
    }

    private func refreshParsedGraph() {
        graphParseError = nil
        let trimmed = liveFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            graph = nil
            return
        }
        do {
            graph = try WorkspaceFlowBPMNParser().parse(xml: liveFlow.bpmnXML)
        } catch {
            graph = nil
            graphParseError = error.localizedDescription
        }
    }

    private var bpmnWebBundleAvailable: Bool {
        Bundle.main.url(forResource: "bpmn-editor", withExtension: "html", subdirectory: "BPMN") != nil
    }

    private var diagramPane: some View {
        // No envolver el `WKWebView` en un `ScrollView` de SwiftUI: compite con el scroll del lienzo BPMN.
        VStack(alignment: .leading, spacing: 16) {
            Text("Solo lectura (edición en Mac). El lienzo es el mismo motor BPMN que en escritorio.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let graphParseError {
                Text(graphParseError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if bpmnWebBundleAvailable,
               !liveFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                PadBPMNReadOnlyWebView(bpmnXML: liveFlow.bpmnXML, diagramViewport: liveFlow.diagramViewport)
                    .frame(minHeight: 440)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if !bpmnWebBundleAvailable {
                Text("No se encontraron los recursos BPMN embebidos (BPMN/bpmn-editor.html).")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let graph {
                let nameByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.name) })
                ScrollView {
                    DisclosureGroup("Nodos y enlaces (lista)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nodos (\(graph.nodes.count))")
                                .font(.headline)
                            ForEach(graph.nodes) { node in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: iconForNodeType(node.nodeType))
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name.isEmpty ? node.id : node.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(node.nodeType.rawValue) · \(node.bpmnType)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }

                            Text("Enlaces (\(graph.connections.count))")
                                .font(.headline)
                                .padding(.top, 8)
                            ForEach(graph.connections) { link in
                                let from = nameByID[link.sourceID] ?? link.sourceID
                                let to = nameByID[link.targetID] ?? link.targetID
                                Text("\(from)  →  \(to)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.vertical, 4)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollClipDisabled()
            } else if liveFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Sin BPMN en el workspace.")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var liveLogPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Salida de la última ejecución del flow o del batch (misma sesión que antes en Runs / Ejecutar).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let session = viewModel.flowRunSession(for: liveFlow.id), !session.logs.isEmpty {
                    if session.isRunning {
                        ProgressView("Ejecutando…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let err = session.lastErrorDescription, !err.isEmpty {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    PadFlowRunLogLinesView(lines: session.logs)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ContentUnavailableView(
                        "Sin log aún",
                        systemImage: "text.alignleft",
                        description: Text("Ejecuta el flow completo o un caso batch para ver líneas aquí.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(.top, 24)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runsPane: some View {
        let rows = liveFlow.batchRunCases ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Casos batch definidos en Mac. «Ejecutar» corre solo este caso; «Todos» los encadena.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if rows.isEmpty {
                    Text("No hay filas en este flow. Añádelas en la pestaña Runs del editor Mac.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Button {
                            batchTask?.cancel()
                            batchTask = Task {
                                await viewModel.runPadFlowBatchAllCasesSequentially(
                                    flowID: liveFlow.id,
                                    executionEnvironmentID: selectedRunEnvironmentID
                                )
                            }
                        } label: {
                            Label("Ejecutar todos", systemImage: "play.square.stack")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.hasActiveFlowRun(for: liveFlow.id))

                        Button("Cancelar batch") {
                            batchTask?.cancel()
                            viewModel.cancelFlowExecution(flowID: liveFlow.id)
                        }
                        .buttonStyle(.bordered)
                    }

                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Run \(index + 1)" : row.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Log") {
                                    transcriptCaseID = row.id
                                }
                                .buttonStyle(.bordered)
                            }
                            Text(row.parametersJSON)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)

                            Button {
                                batchTask?.cancel()
                                batchTask = Task {
                                    await viewModel.runPadFlowBatchSingleCase(
                                        flowID: liveFlow.id,
                                        caseID: row.id,
                                        executionEnvironmentID: selectedRunEnvironmentID
                                    )
                                }
                            } label: {
                                Label("Ejecutar este caso", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.hasActiveFlowRun(for: liveFlow.id))
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var executePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabeledContent("Tareas enlazadas", value: "\(liveFlow.taskBindings.count)")
                LabeledContent(
                    "BPMN",
                    value: liveFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Vacío"
                        : "\(liveFlow.bpmnXML.count) caracteres"
                )
                LabeledContent("Actualizado", value: liveFlow.updatedAt.formatted(date: .abbreviated, time: .shortened))

                HStack(spacing: 12) {
                    Button {
                        startPadFlowRun()
                    } label: {
                        Label(
                            viewModel.hasActiveFlowRun(for: liveFlow.id) ? "Ejecutando…" : "Ejecutar flow completo",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        liveFlow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.hasActiveFlowRun(for: liveFlow.id)
                    )

                    Button {
                        viewModel.cancelFlowExecution(flowID: liveFlow.id)
                    } label: {
                        Label("Cancelar", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.hasActiveFlowRun(for: liveFlow.id))
                }

                if let session = viewModel.flowRunSession(for: liveFlow.id) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sesión de ejecución")
                            .font(.headline)
                        if session.isRunning {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let err = session.lastErrorDescription, !err.isEmpty {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Text("El log detallado está en la pestaña «Log».")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconForNodeType(_ t: WorkspaceFlowNodeType) -> String {
        switch t {
        case .startEvent: "circle.circle"
        case .endEvent, .terminateEndEvent: "circle.fill"
        case .task: "square.and.pencil"
        case .timerEvent: "timer"
        case .exclusiveGateway: "arrow.triangle.branch"
        case .parallelGateway: "arrow.triangle.merge"
        case .unsupported: "questionmark.square.dashed"
        }
    }

    @MainActor
    private func startPadFlowRun() {
        viewModel.dismissErrorMessageBanner()
        do {
            let g = try WorkspaceFlowBPMNParser().parse(xml: liveFlow.bpmnXML)
            try viewModel.startBackgroundFlowExecution(
                liveFlow,
                graph: g,
                executionEnvironmentID: selectedRunEnvironmentID
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
