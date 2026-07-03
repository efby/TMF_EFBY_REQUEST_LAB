import EfbyPresentation
import AuthenticationServices
import SwiftUI
import UIKit

// MARK: - Credenciales AWS (UITextView: seleccionar todo al tocar)

private struct PadAWSCredentialsTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        tv.delegate = context.coordinator
        tv.text = text
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.textContentType = .none
        tv.keyboardType = .asciiCapable
        tv.isScrollEnabled = true
        if #available(iOS 18.0, *) {
            // Evita la hoja del sistema "Rewrite" / Writing Tools (puede quedar colgada al pegar credenciales).
            tv.writingToolsBehavior = .none
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectAllAfterTap))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        context.coordinator.textView = tv
        tv.inputAccessoryView = Self.keyboardAccessoryView(target: context.coordinator)
        return tv
    }

    private static func keyboardAccessoryView(target: Coordinator) -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(
            title: PadKeyboardDismiss.toolbarTitle,
            style: .done,
            target: target,
            action: #selector(Coordinator.dismissKeyboard)
        )
        done.setTitleTextAttributes(
            [.font: PadKeyboardDismiss.accessoryBarButtonFont],
            for: .normal
        )
        done.setTitleTextAttributes(
            [.font: PadKeyboardDismiss.accessoryBarButtonFont],
            for: .highlighted
        )
        done.accessibilityLabel = PadKeyboardDismiss.accessibilityLabel
        toolbar.items = [flex, done]
        return toolbar
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.binding = $text
        if uiView.text != text {
            context.coordinator.isUpdatingFromParent = true
            uiView.text = text
            context.coordinator.isUpdatingFromParent = false
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var binding: Binding<String>
        weak var textView: UITextView?
        var isUpdatingFromParent = false

        init(binding: Binding<String>) {
            self.binding = binding
        }

        @objc func selectAllAfterTap() {
            DispatchQueue.main.async { [weak self] in
                self?.textView?.selectAll(nil)
            }
        }

        @objc func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdatingFromParent else { return }
            binding.wrappedValue = textView.text
        }
    }
}

// MARK: - Tema compacto (similar a la barra oscura de Mac)

private enum PadRequestChrome {
    static let barBackground = Color(.secondarySystemFill)
    static let panelBackground = Color(.tertiarySystemGroupedBackground)
    static let accent = Color.cyan
}

// MARK: - Writing Tools (iOS 18+)

private extension View {
    /// Desactiva Apple Writing Tools en campos donde solo pegamos datos (evita el modal "Rewrite").
    @ViewBuilder
    func padDisableWritingToolsIfAvailable() -> some View {
        if #available(iOS 18.0, *) {
            self.writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}

@MainActor
private var padIsPhoneIdiom: Bool {
    UIDevice.current.userInterfaceIdiom == .phone
}

// MARK: - Workspace petición (URL + Request / Script | Response / Consola / …)

struct PadRequestWorkspaceView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState

    @State private var mainColumn: PadRequestMainColumn = .request
    @State private var requestSection: PadRequestSection = .params
    @State private var scriptPanel: PadScriptPanel = .preRequest
    @State private var responseColumn: PadResponseColumn = .response
    @State private var preRequestSource = ""
    @State private var testScriptSource = ""
    @State private var scriptsLoaded = false
    @State private var activeAWSAccessPortalSystemAuthSession: ASWebAuthenticationSession?
    @State private var portalAWSAlertMessage: String?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    urlAndActionBar
                    if tab.request.transportKind == .webSocket, tab.webSocketConnectionState == .connected {
                        webSocketOutboundPanel
                    }
                    environmentRow
                    if tab.request.isLambdaInvoke {
                        padInvokeLambdaCredentialsSection
                    }
                    Divider()
                    upperEditorBlock
                    if tab.request.isLambdaInvoke {
                        Divider()
                        padLambdaPortalAWSBar
                    }
                    Divider()
                    lowerResponseBlock
                    Color.clear.frame(height: 24)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            loadScriptsFromRequest()
        }
        .onChange(of: tab.request.id) { _, _ in
            loadScriptsFromRequest()
        }
        .onChange(of: tab.editorRefreshToken) { _, _ in
            loadScriptsFromRequest()
        }
        .onChange(of: tab.request) { _, _ in
            viewModel.persistPendingChanges(for: tab)
        }
        .onChange(of: tab.request.transportKind) { _, _ in
            if tab.request.transportKind != .webSocket, responseColumn == .transcript {
                responseColumn = .response
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

    private var padLambdaPortalAWSBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Portal AWS (sesión del sistema)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField(
                    "{{urlaws}} o URL del portal…",
                    text: Binding(
                        get: { tab.request.awsAccessPortalURLTemplate },
                        set: {
                            tab.request.awsAccessPortalURLTemplate = $0
                            viewModel.persistPendingChanges(for: tab)
                        }
                    )
                )
                .padDisableWritingToolsIfAvailable()
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.caption.monospaced())
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(PadRequestChrome.barBackground, in: RoundedRectangle(cornerRadius: 8))

                Button {
                    beginAWSAccessPortalSystemSession()
                } label: {
                    Label("Portal AWS…", systemImage: "globe")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(
                    "Abre ASWebAuthenticationSession. El IdP debe redirigir al esquema \(AWSAccessPortalAuthCallback.urlScheme)."
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    private var webSocketOutboundPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mensaje saliente")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(
                text: Binding(
                    get: { tab.request.body.raw },
                    set: {
                        tab.request.body.raw = $0
                        viewModel.persistPendingChanges(for: tab)
                    }
                )
            )
            .padDisableWritingToolsIfAvailable()
            .font(.caption.monospaced())
            .frame(minHeight: 88)
            .scrollDisabled(true)
            .padding(8)
            .background(PadRequestChrome.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button {
                viewModel.sendWebSocketMessage(forTabID: tab.id)
            } label: {
                Label("Enviar mensaje", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PadRequestChrome.accent)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .background(Color(.systemBackground))
    }

    /// En iPhone con transporte HTTP (GET/POST/… o Lambda) no mostramos selector de transporte ni método (fijos; más espacio para URL/ARN).
    private var padHideTransportAndHTTPMethodOnPhone: Bool {
        padIsPhoneIdiom && tab.request.usesHTTPTransport
    }

    // MARK: Barra URL (método + URL + enviar)

    private var urlAndActionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tab.request.isLambdaInvoke ? "ARN o alias (plantilla; se resuelve al invocar)" : "URL (plantilla; se resuelve al enviar)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
            if !padHideTransportAndHTTPMethodOnPhone {
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
                            viewModel.persistPendingChanges(for: tab)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.request.transportKind.displayName)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(PadRequestChrome.barBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if tab.request.usesHTTPTransport {
                if tab.request.transportKind == .http {
                    Menu {
                        ForEach(HTTPMethod.allCases, id: \.self) { m in
                            Button(m.rawValue) {
                                tab.request.method = m
                                viewModel.persistPendingChanges(for: tab)
                            }
                        }
                    } label: {
                        Text(tab.request.method.rawValue)
                            .font(.subheadline.monospaced().weight(.bold))
                            .frame(minWidth: 56, minHeight: 36)
                            .background(PadRequestChrome.barBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                } else if !padHideTransportAndHTTPMethodOnPhone {
                    Text(HTTPMethod.post.rawValue)
                        .font(.subheadline.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56, minHeight: 36)
                        .background(PadRequestChrome.barBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            TextField(
                tab.request.isLambdaInvoke ? "ARN o URL de invoke…" : "https://…",
                text: Binding(
                    get: { tab.request.url },
                    set: {
                        tab.request.url = $0
                        viewModel.persistPendingChanges(for: tab)
                    }
                )
            )
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#if os(iOS)
            .keyboardType(.URL)
#endif
            .font(.subheadline.monospaced())
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(PadRequestChrome.barBackground, in: RoundedRectangle(cornerRadius: 8))
            .padDisableWritingToolsIfAvailable()

            if tab.request.usesHTTPTransport {
                Button {
                    viewModel.sendRequest(forTabID: tab.id)
                } label: {
                    Text(tab.request.isLambdaInvoke ? "Invoke" : "Send")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 72, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(PadRequestChrome.accent)
                .disabled(tab.isSending)

                Button {
                    viewModel.cancelRequest(forTabID: tab.id)
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 64, height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(!tab.isSending)
            } else if tab.request.transportKind == .webSocket {
                Button {
                    viewModel.sendRequest(forTabID: tab.id)
                } label: {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 84, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(PadRequestChrome.accent)
                .disabled(
                    tab.webSocketConnectionState == .connected
                        || tab.webSocketConnectionState == .connecting
                        || tab.webSocketConnectionState == .disconnecting
                )

                Button {
                    viewModel.disconnectWebSocket(forTabID: tab.id)
                } label: {
                    Text("Disconnect")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 92, height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(tab.webSocketConnectionState == .disconnected)
            }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private var environmentRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.request.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Ejecución: \(viewModel.executionEnvironmentDisplayName(for: tab))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !viewModel.workspace.environments.isEmpty {
                Picker("Entorno", selection: viewModel.environmentPickerBinding(for: tab)) {
                    Text("Sin entorno (usa activo del workspace)").tag(Optional<UUID>.none)
                    ForEach(viewModel.workspace.environments) { env in
                        Text(env.name).tag(Optional(env.id))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: Columna superior — Request | Script

    private var upperEditorBlock: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mainColumn) {
                Text("Request").tag(PadRequestMainColumn.request)
                Text("Script").tag(PadRequestMainColumn.script)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch mainColumn {
                case .request:
                    requestColumnContent
                case .script:
                    scriptColumnContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(.systemBackground))
    }

    private var requestColumnContent: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PadRequestSection.allCases) { section in
                        Button {
                            requestSection = section
                        } label: {
                            Text(section.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    requestSection == section
                                        ? PadRequestChrome.accent.opacity(0.25)
                                        : PadRequestChrome.barBackground,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // Todo el workspace usa un único `ScrollView` en `body`; aquí solo apilamos contenido.
            if requestSection == .body {
                bodySection
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                requestNonBodySections
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var requestNonBodySections: some View {
        switch requestSection {
        case .body:
            EmptyView()
        case .params:
            PadKeyValueSection(title: "Query params", entries: queryItemsBinding)
            PadKeyValueSection(title: "Path variables", entries: pathVariablesBinding)
            PadKeyValueSection(title: "Cookies", entries: cookiesBinding)
        case .headers:
            PadKeyValueSection(title: "Headers", entries: headersBinding)
        case .auth:
            authSummarySection
        }
    }

    private var queryItemsBinding: Binding<[KeyValueEntry]> {
        Binding(
            get: { tab.request.queryItems },
            set: {
                tab.request.queryItems = $0
                viewModel.persistPendingChanges(for: tab)
            }
        )
    }

    private var pathVariablesBinding: Binding<[KeyValueEntry]> {
        Binding(
            get: { tab.request.pathVariables },
            set: {
                tab.request.pathVariables = $0
                viewModel.persistPendingChanges(for: tab)
            }
        )
    }

    private var cookiesBinding: Binding<[KeyValueEntry]> {
        Binding(
            get: { tab.request.cookies },
            set: {
                tab.request.cookies = $0
                viewModel.persistPendingChanges(for: tab)
            }
        )
    }

    private var headersBinding: Binding<[KeyValueEntry]> {
        Binding(
            get: { tab.request.headers },
            set: {
                tab.request.headers = $0
                viewModel.persistPendingChanges(for: tab)
            }
        )
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tipo", selection: Binding(
                get: { tab.request.body.kind },
                set: {
                    tab.request.body.kind = $0
                    viewModel.persistPendingChanges(for: tab)
                }
            )) {
                Text("None").tag(RequestBodyKind.none)
                Text("Raw").tag(RequestBodyKind.raw)
                Text("JSON").tag(RequestBodyKind.json)
                Text("Form").tag(RequestBodyKind.urlEncoded)
            }
            .pickerStyle(.segmented)

            if tab.request.body.kind != .none {
                TextEditor(
                    text: Binding(
                        get: { tab.request.body.raw },
                        set: {
                            tab.request.body.raw = $0
                            viewModel.persistPendingChanges(for: tab)
                        }
                    )
                )
                .padDisableWritingToolsIfAvailable()
                .font(.caption.monospaced())
                .frame(minHeight: 220)
                .scrollDisabled(true)
                .padding(8)
                .background(PadRequestChrome.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var authSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tab.request.isLambdaInvoke {
                Text(
                    "Invoke Lambda usa credenciales temporales en el bloque bajo el entorno. Debajo del editor (Request/Script) indica la URL del portal y pulsa Portal AWS… para la sesión del sistema; si el IdP no redirige al esquema \(AWSAccessPortalAuthCallback.urlScheme), pega aquí las claves export/INI."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tipo: \(tab.request.auth.type.rawValue)")
                    .font(.subheadline)
                Text("La edición detallada de autorización sigue disponible en la app Mac; aquí solo se muestra el tipo activo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mismo formato que espera `RequestExecutionService.parseTemporaryAWSCredentials` (INI / export).
    private var padInvokeLambdaCredentialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AWS temporary credentials")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(
                "Pega las tres claves (por ejemplo salida de STS o copiadas del portal). Líneas tipo `aws_access_key_id=…`, `aws_secret_access_key=…`, `aws_session_token=…` o con prefijo `export`. Para login web con MFA, pulsa Portal AWS… bajo el editor con la URL del portal (o `{{variable}}`)."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            PadAWSCredentialsTextEditor(
                text: Binding(
                    get: { tab.request.auth.token },
                    set: { newValue in
                        tab.request.auth.type = .awsTemporaryCredentials
                        tab.request.auth.token = newValue
                        viewModel.persistPendingChanges(for: tab)
                    }
                )
            )
            .padDisableWritingToolsIfAvailable()
            .frame(minHeight: 120)
            .padding(8)
            .background(PadRequestChrome.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    private var scriptColumnContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scriptPanel) {
                Text("Pre-request").tag(PadScriptPanel.preRequest)
                Text(tab.request.transportKind == .webSocket ? "On message" : "Tests")
                    .tag(PadScriptPanel.test)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            TextEditor(text: activeScriptTextBinding)
                .padDisableWritingToolsIfAvailable()
                .font(.caption.monospaced())
                .frame(minHeight: 260)
                .scrollDisabled(true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(PadRequestChrome.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(12)
        }
        .onChange(of: preRequestSource) { _, _ in
            guard scriptsLoaded else { return }
            persistScriptPanel(.preRequest, source: preRequestSource)
        }
        .onChange(of: testScriptSource) { _, _ in
            guard scriptsLoaded else { return }
            persistScriptPanel(.test, source: testScriptSource)
        }
    }

    private var activeScriptTextBinding: Binding<String> {
        Binding(
            get: { scriptPanel == .preRequest ? preRequestSource : testScriptSource },
            set: { newVal in
                if scriptPanel == .preRequest {
                    preRequestSource = newVal
                } else {
                    testScriptSource = newVal
                }
            }
        )
    }

    private func loadScriptsFromRequest() {
        scriptsLoaded = false
        preRequestSource = tab.request.scripts.last(where: { $0.listen == .preRequest })?.source ?? ""
        testScriptSource = tab.request.scripts.last(where: { $0.listen == .test })?.source ?? ""
        scriptsLoaded = true
    }

    private func persistScriptPanel(_ panel: PadScriptPanel, source: String) {
        let event: ScriptEventType = panel == .preRequest ? .preRequest : .test
        tab.request.scripts.removeAll { $0.listen == event }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.request.scripts.append(
                ScriptDefinition(name: event.rawValue, listen: event, language: "javascript", source: source)
            )
        }
        viewModel.persistPendingChanges(for: tab)
    }

    // MARK: Columna inferior — Response | Console | …

    private var lowerResponseBlock: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $responseColumn) {
                    ForEach(PadResponseColumn.columns(for: tab.request.transportKind)) { col in
                        switch col {
                        case .response: Text("Response").tag(col)
                        case .console: Text("Console").tag(col)
                        case .transcript: Text("Transcript").tag(col)
                        }
                    }
                }
                .pickerStyle(.segmented)

                Spacer()

                if responseColumn == .console, !tab.consoleLogs.isEmpty {
                    Button {
                        PadPasteboard.copy(tab.consoleLogs.joined(separator: "\n"))
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .accessibilityHint("Copia la consola al portapapeles")
                }

                if responseColumn == .transcript, !tab.webSocketTranscript.isEmpty {
                    Button {
                        let text = tab.webSocketTranscript.suffix(200).map { entry in
                            "\(entry.direction.rawValue.uppercased())\t\(entry.body)"
                        }.joined(separator: "\n")
                        PadPasteboard.copy(text)
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .accessibilityHint("Copia el transcript al portapapeles")
                }

                if tab.request.transportKind == .webSocket {
                    Text(tab.webSocketConnectionState.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let r = tab.response {
                    Text("\(r.statusCode) · \(Int(r.durationMilliseconds)) ms")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            Divider()

            lowerResponsePaneContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
                .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private var lowerResponsePaneContent: some View {
        switch responseColumn {
        case .response:
            if tab.isSending, tab.request.usesHTTPTransport {
                ProgressView("Esperando respuesta…")
                    .padding()
            } else if let response = tab.response {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(response.statusCode) \(response.statusText)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(response.sizeBytes) bytes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(response.body)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Text("Envía la petición para ver la respuesta.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        case .console:
            if tab.consoleLogs.isEmpty {
                Text("Sin salida de consola.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(tab.consoleLogs.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                PlatformClipboard.copyPlainText(line)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Copiar esta línea")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .transcript:
            if tab.webSocketTranscript.isEmpty {
                Text("Sin mensajes WebSocket.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tab.webSocketTranscript.suffix(200)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.direction.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(entry.body)
                                .font(.caption2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Subtipos UI

private enum PadRequestMainColumn: String, CaseIterable, Identifiable {
    case request
    case script
    var id: String { rawValue }
}

private enum PadRequestSection: String, CaseIterable, Identifiable {
    case params = "Params"
    case headers = "Headers"
    case body = "Body"
    case auth = "Auth"
    var id: String { rawValue }
}

private enum PadScriptPanel: Hashable {
    case preRequest
    case test
}

private enum PadResponseColumn: String, CaseIterable, Identifiable {
    case response
    case console
    case transcript

    var id: String { rawValue }

    static func columns(for transport: RequestTransportKind) -> [PadResponseColumn] {
        transport == .webSocket ? [.response, .console, .transcript] : [.response, .console]
    }
}

// MARK: - Lista clave-valor

private struct PadKeyValueSection: View {
    let title: String
    @Binding var entries: [KeyValueEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    entries.append(KeyValueEntry(key: "", value: ""))
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: 8) {
                    TextField("Key", text: bindingForEntryKey(at: index))
                        .padDisableWritingToolsIfAvailable()
                        .textInputAutocapitalization(.never)
                        .font(.caption.monospaced())
                    TextField("Value", text: bindingForEntryValue(at: index))
                        .padDisableWritingToolsIfAvailable()
                        .textInputAutocapitalization(.never)
                        .font(.caption.monospaced())
                    Toggle("", isOn: Binding(
                        get: { entries[index].isEnabled },
                        set: { entries[index].isEnabled = $0 }
                    ))
                    .labelsHidden()
                    .frame(width: 44)
                    Button(role: .destructive) {
                        guard entries.indices.contains(index) else { return }
                        entries.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(PadRequestChrome.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 6)
    }

    private func bindingForEntryKey(at index: Int) -> Binding<String> {
        Binding(
            get: { entries.indices.contains(index) ? entries[index].key : "" },
            set: { newVal in
                guard entries.indices.contains(index) else { return }
                entries[index].key = newVal
            }
        )
    }

    private func bindingForEntryValue(at index: Int) -> Binding<String> {
        Binding(
            get: { entries.indices.contains(index) ? entries[index].value : "" },
            set: { newVal in
                guard entries.indices.contains(index) else { return }
                entries[index].value = newVal
            }
        )
    }
}
