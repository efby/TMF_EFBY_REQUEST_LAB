import AuthenticationServices
import EfbyPresentation
import Foundation
import SwiftUI

private enum RequestEditorTab: String, CaseIterable, Identifiable {
    case docs = "Docs"
    case params = "Params"
    case authorization = "Authorization"
    case headers = "Headers"
    case body = "Body"
    case scripts = "Scripts"
    case settings = "Settings"

    var id: String { rawValue }
}

struct RequestEditorView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var bodyEditorText = ""
    @State private var bodyEditorRequestID: UUID?
    @State private var activeAWSAccessPortalSystemAuthSession: ASWebAuthenticationSession?
    @State private var portalAWSAlertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
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
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(tab.request.transportKind.displayName)
                        .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 120, minHeight: 36, alignment: .leading)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)

                if tab.request.usesHTTPTransport {
                    if tab.request.transportKind == .http {
                        Menu {
                            ForEach(HTTPMethod.allCases, id: \.self) { method in
                                Button(method.rawValue) {
                                    tab.request.method = method
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(tab.request.method.rawValue)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 120, minHeight: 36, alignment: .leading)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                    } else {
                        HStack(spacing: 8) {
                            Text(HTTPMethod.post.rawValue)
                                .lineLimit(1)
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 120, minHeight: 36, alignment: .leading)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                }

                DarkTextInput(text: binding(\.url), placeholder: requestAddressPlaceholder, controlIdentifier: "request.url")
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Spacer(minLength: 0)

                if tab.request.usesHTTPTransport {
                    Button {
                        synchronizeBodyEditorToRequest()
                        viewModel.sendCurrentRequest()
                    } label: {
                        Text("Send")
                            .frame(width: 86, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("request.send")

                    Button {
                        synchronizeBodyEditorToRequest()
                        viewModel.cancelCurrentRequest()
                    } label: {
                        Text("Cancel")
                            .frame(width: 72, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .disabled(!tab.isSending)
                    .accessibilityIdentifier("request.cancel")
                } else {
                    Button {
                        synchronizeBodyEditorToRequest()
                        viewModel.sendCurrentRequest()
                    } label: {
                        Text("Connect")
                            .frame(width: 92, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(
                        tab.webSocketConnectionState == .connected ||
                        tab.webSocketConnectionState == .connecting ||
                        tab.webSocketConnectionState == .disconnecting
                    )

                    Button {
                        viewModel.disconnectCurrentWebSocket()
                    } label: {
                        Text("Disconnect")
                            .frame(width: 92, height: 36)
                            .contentShape(Rectangle())
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .disabled(tab.webSocketConnectionState == .disconnected)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            HStack(spacing: 18) {
                ForEach(RequestEditorTab.allCases) { editorTab in
                    editorTabButton(editorTab)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .background(PostmanTheme.appBackground)

            Divider().overlay(PostmanTheme.border)

            VStack(spacing: 0) {
                selectedEditorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(PostmanTheme.appBackground)

                if tab.request.isLambdaInvoke {
                    lambdaAWSAccessPortalBar
                }
            }
        }
        .onChange(of: tab.request) { _, _ in
            viewModel.persistPendingChanges(for: tab)
        }
        .onAppear {
            loadBodyEditorIfNeeded(force: true)
        }
        .onChange(of: tab.request.id) { _, _ in
            loadBodyEditorIfNeeded(force: true)
        }
        .onChange(of: tab.editorRefreshToken) { _, _ in
            loadBodyEditorIfNeeded(force: true)
        }
        .onChange(of: tab.request.body.raw) { _, newValue in
            if bodyEditorText != newValue {
                bodyEditorText = newValue
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

    private var docsView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .docs)) {
            VStack(alignment: .leading, spacing: 12) {
                darkInput("Request Name", text: binding(\.name))
                DarkSection(title: "Request Summary") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transport: \(tab.request.transportKind.displayName)")
                        if tab.request.transportKind == .http {
                            Text("Method: \(tab.request.method.rawValue)")
                        } else if tab.request.transportKind == .invokeLambda {
                            Text("Method: \(HTTPMethod.post.rawValue) (Lambda invoke)")
                        }
                        Text("\(tab.request.isLambdaInvoke ? "Lambda ARN" : "URL"): \(tab.request.url)")
                        Text("Headers: \(tab.request.headers.count)")
                        Text("Params: \(tab.request.queryItems.count)")
                        if tab.request.transportKind == .webSocket {
                            Text("Transcript entries: \(tab.webSocketTranscript.count)")
                            Text("Open timeout: \(formattedSeconds(tab.request.webSocketOpenTimeoutSeconds))")
                            Text("Ping interval: \(formattedSeconds(tab.request.webSocketPingIntervalSeconds))")
                            Text("Keepalive interval: \(formattedSeconds(tab.request.webSocketKeepAliveIntervalSeconds))")
                        }
                    }
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private var paramsView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .params)) {
            VStack(alignment: .leading, spacing: 18) {
                DarkSection(title: "Query Params") {
                    EditableKeyValueList(title: "", entries: binding(\.queryItems))
                }
                DarkSection(title: "Path Params") {
                    EditableKeyValueList(title: "", entries: binding(\.pathVariables))
                }
                DarkSection(title: "Cookies") {
                    EditableKeyValueList(title: "", entries: binding(\.cookies))
                }
            }
            .padding(16)
        }
    }

    private var headersView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .headers)) {
            DarkSection(title: "Headers") {
                EditableKeyValueList(title: "", entries: binding(\.headers))
            }
            .padding(16)
        }
    }

    private var lambdaAWSAccessPortalBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(PostmanTheme.border)
            HStack(spacing: 10) {
                DarkTextInput(
                    text: binding(\.awsAccessPortalURLTemplate),
                    placeholder: "{{urlaws}} o URL del portal…"
                )
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Button {
                    beginAWSAccessPortalSystemSession()
                } label: {
                    Label("Portal AWS…", systemImage: "globe")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                .help("Abre ASWebAuthenticationSession (ventana del sistema) con la URL del campo. El IdP debe redirigir al esquema \(AWSAccessPortalAuthCallback.urlScheme)://… registrado en la app. Tras el login, pega las credenciales temporales en Authorization si el portal no devuelve token en la URL.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PostmanTheme.appBackground)
        }
    }

    private var authView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .authorization)) {
            DarkSection(title: "Authorization") {
                VStack(alignment: .leading, spacing: 12) {
                    if tab.request.isLambdaInvoke {
                        Text("AWS Temporary Credentials")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        Text(
                            "Pega credenciales en formato INI (`aws_access_key_id=…`) o líneas `export AWS_ACCESS_KEY_ID=…`. En la barra inferior del editor, indica la URL del portal (o `{{variable}}`) y pulsa **Portal AWS…** para abrir la **ventana de inicio de sesión del sistema** (MFA/WebAuthn). Si el IdP no redirige al esquema registrado en la app, copia las claves desde el portal y pégalas aquí. La petición firmará Lambda con SigV4 usando el ARN del campo URL."
                        )
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)

                        MacCodeEditor(
                            text: binding(\.auth.token),
                            language: .plainText,
                            showsLineNumbers: true,
                            selectEntireDocumentOnClick: true
                        )
                        .frame(minHeight: 210, maxHeight: 320)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))

                        Text("[profile]\naws_access_key_id=…\n…\n\nexport AWS_ACCESS_KEY_ID=\"…\"\nexport AWS_SECRET_ACCESS_KEY=\"…\"\nexport AWS_SESSION_TOKEN=\"…\"")
                            .font(.caption.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .padding(.top, 4)
                    } else {
                        Picker("Type", selection: binding(\.auth.type)) {
                            ForEach(standardHTTPAuthTypes, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)

                        switch tab.request.auth.type {
                        case .noAuth:
                            mutedText("No Auth")
                        case .basic:
                            darkInput("Username", text: binding(\.auth.username))
                            secureDarkInput("Password", text: binding(\.auth.password))
                        case .bearer:
                            darkInput("Token", text: binding(\.auth.token))
                        case .apiKey:
                            darkInput("Key", text: binding(\.auth.key))
                            darkInput("Value", text: binding(\.auth.value))
                            Picker("Placement", selection: binding(\.auth.addTo)) {
                                ForEach(APIKeyPlacement.allCases, id: \.self) { placement in
                                    Text(placement.rawValue).tag(placement)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        case .oauth2:
                            darkInput("Access Token", text: binding(\.auth.token))
                            darkInput("Token URL", text: binding(\.auth.accessTokenURL))
                            darkInput("Client ID", text: binding(\.auth.clientID))
                            secureDarkInput("Client Secret", text: binding(\.auth.clientSecret))
                            darkInput("Scopes", text: binding(\.auth.scopes))
                        case .awsTemporaryCredentials:
                            mutedText("Switch transport to Invoke Lambda to use AWS temporary credentials.")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var bodyView: some View {
        VStack(spacing: 0) {
            if tab.request.transportKind == .webSocket {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Outgoing Message")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)
                        Spacer()
                        Text("Placeholders like {{token}} are resolved when sending.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Text("Open the socket with `Connect` above, then use `Send Msg` here for manual messages.")
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .padding(.horizontal, 16)

                    MacCodeEditor(
                        text: bodyTextBinding,
                        verticalScrollOffset: scrollOffsetBinding(for: .body),
                        language: .plainText,
                        showsLineNumbers: true,
                        autocompleteContext: .javascript(workspaceUtilities: viewModel.workspace.utilityLibraries)
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                        .padding(16)

                    HStack {
                        Spacer()

                        Button {
                            synchronizeBodyEditorToRequest()
                            viewModel.sendCurrentWebSocketMessage()
                        } label: {
                            Text("Send Msg")
                                .frame(width: 108, height: 40)
                                .contentShape(Rectangle())
                                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .disabled(tab.webSocketConnectionState != .connected)
                        .opacity(tab.webSocketConnectionState == .connected ? 1 : 0.6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            } else {
                BodyModeBar(
                    bodyKind: binding(\.body.kind),
                    jsonValidation: jsonValidationFeedback,
                    canBeautify: canBeautifyBody,
                    onBeautify: beautifyBody
                )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Divider().overlay(PostmanTheme.border)

                if tab.request.body.kind == .urlEncoded || tab.request.body.kind == .formData {
                    RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .body)) {
                        VStack(alignment: .leading, spacing: 16) {
                            DarkSection(title: "Body Fields") {
                                EditableKeyValueList(title: "", entries: binding(\.body.parameters))
                            }
                        }
                        .padding(16)
                    }
                } else {
                    MacCodeEditor(
                        text: bodyTextBinding,
                        verticalScrollOffset: scrollOffsetBinding(for: .body),
                        language: bodyEditorLanguage,
                        showsLineNumbers: true,
                        autocompleteContext: .javascript(workspaceUtilities: viewModel.workspace.utilityLibraries)
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                        .padding(16)
                }
            }
        }
    }

    private var settingsView: some View {
        RememberingVerticalScrollView(scrollOffset: scrollOffsetBinding(for: .settings)) {
            DarkSection(title: "Request Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    darkInput("Request Name", text: binding(\.name))
                    HStack {
                        Text("Timeout")
                            .foregroundStyle(PostmanTheme.textSecondary)
                        Slider(value: binding(\.timeoutSeconds), in: 5...120, step: 5)
                        Text("\(Int(tab.request.timeoutSeconds))s")
                            .foregroundStyle(PostmanTheme.textPrimary)
                            .frame(width: 44)
                    }

                    if tab.request.usesHTTPTransport {
                        HStack {
                            Text("Retries on HTTP 206")
                                .foregroundStyle(PostmanTheme.textSecondary)
                            Spacer()
                            Text("\(tab.request.retryOn206Count)")
                                .foregroundStyle(PostmanTheme.textPrimary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Stepper("", value: binding(\.retryOn206Count), in: 0...20)
                                .labelsHidden()
                        }
                        webSocketNumericSettingRow(
                            title: "Delay between HTTP 206 retries",
                            description: "Milliseconds to wait after a 206 before running pre-request again and retrying. Use 0 for no delay.",
                            text: webSocketIntegerBinding(\.retryOn206DelayMilliseconds),
                            suffix: "ms"
                        )
                        Text("Default: 5 retries. Set retries to 0 to disable. After each 206, the pre-request script runs again before the next attempt.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }

                    if tab.request.transportKind == .webSocket {
                        webSocketBooleanSettingRow(
                            title: "Enable server certificate verification",
                            description: "Verify the server certificate when connecting over a secure connection.",
                            isOn: Binding(
                                get: { tab.request.tlsValidationMode == .strict },
                                set: { tab.request.tlsValidationMode = $0 ? .strict : .insecure }
                            )
                        )

                        webSocketNumericSettingRow(
                            title: "Handshake request timeout",
                            description: "Set how long the handshake request should wait before timing out in milliseconds. Set 0 to disable the limit.",
                            text: webSocketMillisecondsBinding(\.webSocketOpenTimeoutSeconds),
                            suffix: "ms"
                        )

                        webSocketNumericSettingRow(
                            title: "Reconnection attempts",
                            description: "Maximum reconnection attempts when the connection closes unexpectedly.",
                            text: webSocketIntegerBinding(\.webSocketReconnectAttempts)
                        )

                        webSocketNumericSettingRow(
                            title: "Reconnection intervals",
                            description: "Interval between reconnection attempts in milliseconds.",
                            text: webSocketIntegerBinding(\.webSocketReconnectIntervalMilliseconds),
                            suffix: "ms"
                        )

                        webSocketNumericSettingRow(
                            title: "Maximum message size",
                            description: "Maximum allowed message size in MB. Set 0 to accept messages of any size.",
                            text: webSocketIntegerBinding(\.webSocketMaximumMessageSizeMB),
                            suffix: "MB"
                        )

                        webSocketTextSettingRow(
                            title: "Subprotocols",
                            description: "Optional. Separate multiple subprotocols with commas.",
                            text: binding(\.webSocketSubprotocols),
                            placeholder: "json, chat.v2"
                        )

                        webSocketNumericSettingRow(
                            title: "Ping interval",
                            description: "Send native WebSocket ping frames every N seconds. Set 0 to disable it.",
                            text: webSocketSecondsBinding(\.webSocketPingIntervalSeconds),
                            suffix: "s"
                        )

                        webSocketNumericSettingRow(
                            title: "Keepalive interval",
                            description: "Send the keepalive message every N seconds after connecting. Set 0 to disable it.",
                            text: webSocketSecondsBinding(\.webSocketKeepAliveIntervalSeconds),
                            suffix: "s"
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Keepalive message")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PostmanTheme.textPrimary)

                            Text("If the interval is greater than 0 and this field is not empty, the app sends this message automatically.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.textSecondary)

                            MacCodeEditor(
                                text: binding(\.webSocketKeepAliveMessage),
                                language: .plainText,
                                showsLineNumbers: false
                            )
                            .frame(minHeight: 110, maxHeight: 150)
                            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
                        }

                        webSocketPickerSettingRow(
                            title: "Minimum TLS version",
                            description: "Force a minimum TLS version for the WebSocket handshake when needed.",
                            width: 170
                        ) {
                            Picker("Minimum TLS", selection: binding(\.minimumTLSVersion)) {
                                ForEach(TLSMinimumVersionOption.allCases, id: \.self) { version in
                                    Text(version.displayName).tag(version)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        if tab.request.tlsValidationMode == .insecure {
                            Text("Warning: disabling TLS validation is insecure and should only be used for debugging trusted endpoints.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.salmon)
                        }

                        Text("WebSocket connections reuse the configured URL, headers, auth, cookies, query params, and TLS settings.")
                            .font(.caption)
                            .foregroundStyle(PostmanTheme.textSecondary)
                    }

                    if tab.request.usesHTTPTransport {
                        Divider().overlay(PostmanTheme.border)

                        HStack {
                            Text("TLS Validation")
                                .foregroundStyle(PostmanTheme.textSecondary)
                            Spacer()
                            Picker("TLS Validation", selection: binding(\.tlsValidationMode)) {
                                ForEach(TLSValidationMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        HStack {
                            Text("Minimum TLS")
                                .foregroundStyle(PostmanTheme.textSecondary)
                            Spacer()
                            Picker("Minimum TLS", selection: binding(\.minimumTLSVersion)) {
                                ForEach(TLSMinimumVersionOption.allCases, id: \.self) { version in
                                    Text(version.displayName).tag(version)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 170)
                        }

                        if tab.request.tlsValidationMode == .insecure {
                            Text("Warning: disabling TLS validation is insecure and should only be used for debugging trusted endpoints.")
                                .font(.caption)
                                .foregroundStyle(PostmanTheme.salmon)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func webSocketBooleanSettingRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 8)
    }

    private func webSocketNumericSettingRow(
        title: String,
        description: String,
        text: Binding<String>,
        suffix: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                compactDarkInput(text: text, placeholder: "0", width: 92)
                if let suffix, !suffix.isEmpty {
                    Text(suffix)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PostmanTheme.textSecondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func webSocketTextSettingRow(
        title: String,
        description: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            compactDarkInput(text: text, placeholder: placeholder, width: 180)
        }
        .padding(.vertical, 8)
    }

    private func webSocketPickerSettingRow<PickerContent: View>(
        title: String,
        description: String,
        width: CGFloat,
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer(minLength: 16)

            picker()
                .frame(width: width)
        }
        .padding(.vertical, 8)
    }

    private func compactDarkInput(
        text: Binding<String>,
        placeholder: String,
        width: CGFloat
    ) -> some View {
        DarkTextInput(text: text, placeholder: placeholder)
            .padding(.horizontal, 12)
            .frame(width: width, height: 40)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
    }

    private var standardHTTPAuthTypes: [AuthType] {
        AuthType.allCases.filter { $0 != .awsTemporaryCredentials }
    }

    private var requestAddressPlaceholder: String {
        if tab.request.isLambdaInvoke {
            return "arn:aws:lambda:us-east-1:123456789012:function:my-function"
        }

        if tab.request.transportKind == .webSocket {
            return "wss://api.example.com/socket"
        }

        return "https://api.example.com/resource"
    }

    private func webSocketMillisecondsBinding(_ keyPath: WritableKeyPath<APIRequestModel, Double>) -> Binding<String> {
        Binding(
            get: {
                let milliseconds = Int((tab.request[keyPath: keyPath] * 1_000).rounded())
                return String(milliseconds)
            },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                let milliseconds = Int(digits) ?? 0
                tab.request[keyPath: keyPath] = Double(milliseconds) / 1_000
            }
        )
    }

    private func webSocketSecondsBinding(_ keyPath: WritableKeyPath<APIRequestModel, Double>) -> Binding<String> {
        Binding(
            get: {
                let seconds = tab.request[keyPath: keyPath]
                if seconds.rounded() == seconds {
                    return String(Int(seconds))
                }
                return seconds.formatted(.number.precision(.fractionLength(0...2)))
            },
            set: { newValue in
                let sanitized = newValue.filter { $0.isNumber || $0 == "." }
                tab.request[keyPath: keyPath] = max(0, Double(sanitized) ?? 0)
            }
        )
    }

    private func webSocketIntegerBinding(_ keyPath: WritableKeyPath<APIRequestModel, Int>) -> Binding<String> {
        Binding(
            get: { String(tab.request[keyPath: keyPath]) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                tab.request[keyPath: keyPath] = max(0, Int(digits) ?? 0)
            }
        )
    }

    private func formattedSeconds(_ value: Double) -> String {
        if value == 0 {
            return "0s"
        }
        if value.rounded() == value {
            return "\(Int(value))s"
        }
        return "\(value.formatted())s"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<APIRequestModel, Value>) -> Binding<Value> {
        Binding(
            get: { tab.request[keyPath: keyPath] },
            set: { tab.request[keyPath: keyPath] = $0 }
        )
    }

    private var selectedEditorTab: RequestEditorTab {
        get { RequestEditorTab(rawValue: tab.requestEditorSelectedTabRawValue) ?? .body }
        nonmutating set { tab.requestEditorSelectedTabRawValue = newValue.rawValue }
    }

    private var bodyTextBinding: Binding<String> {
        Binding(
            get: { bodyEditorText },
            set: { newValue in
                bodyEditorText = newValue
                tab.request.body.raw = newValue
                if tab.request.body.kind == .none {
                    tab.request.body.kind = .raw
                }
            }
        )
    }

    private func scrollOffsetBinding(for editorTab: RequestEditorTab) -> Binding<Double> {
        Binding(
            get: { tab.requestEditorScrollOffsets[editorTab.rawValue] ?? 0 },
            set: { tab.requestEditorScrollOffsets[editorTab.rawValue] = $0 }
        )
    }

    private func editorTabButton(_ editorTab: RequestEditorTab) -> some View {
        let isSelected = selectedEditorTab == editorTab

        return Button {
            selectedEditorTab = editorTab
        } label: {
            Text(editorTab.rawValue)
                .foregroundStyle(isSelected ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(PostmanTheme.orange)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("request.editor.tab.\(editorTab.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "unselected")
    }

    private var selectedEditorContent: AnyView {
        switch selectedEditorTab {
        case .docs:
            AnyView(docsView)
        case .params:
            AnyView(paramsView)
        case .authorization:
            AnyView(authView)
        case .headers:
            AnyView(headersView)
        case .body:
            AnyView(bodyView)
        case .scripts:
            AnyView(
                ScriptsTabView(
                    requestID: tab.request.id,
                    transportKind: tab.request.transportKind,
                    refreshToken: tab.editorRefreshToken,
                    utilityLibraries: viewModel.workspace.utilityLibraries,
                    scripts: binding(\.scripts),
                    selectedPanelRawValue: Binding(
                        get: { tab.requestScriptsSelectedPanelRawValue },
                        set: { tab.requestScriptsSelectedPanelRawValue = $0 }
                    ),
                    scrollOffsets: Binding(
                        get: { tab.requestEditorScrollOffsets },
                        set: { tab.requestEditorScrollOffsets = $0 }
                    )
                )
            )
        case .settings:
            AnyView(settingsView)
        }
    }

    private var canBeautifyBody: Bool {
        switch tab.request.body.kind {
        case .raw, .json:
            return !tab.request.body.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .none, .urlEncoded, .formData:
            return false
        }
    }

    private var shouldValidateJSONBody: Bool {
        if tab.request.body.kind == .json {
            return true
        }

        let trimmed = bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return tab.request.body.kind == .raw && (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))
    }

    private var bodyEditorLanguage: CodeEditorLanguage {
        shouldValidateJSONBody ? .json : .plainText
    }

    private var jsonValidationFeedback: (message: String, color: Color, isValid: Bool)? {
        guard shouldValidateJSONBody else { return nil }

        let trimmed = bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("JSON body is empty.", .red, false)
        }

        do {
            _ = try parseJSONObject(from: trimmed)
            return ("Valid JSON body.", PostmanTheme.green, true)
        } catch {
            return (error.localizedDescription, .red, false)
        }
    }

    private func beautifyBody() {
        let trimmed = bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let prepared = try prepareJSONForValidation(from: trimmed)
            let object = try JSONSerialization.jsonObject(with: Data(prepared.sanitized.utf8))
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            if let text = String(data: formatted, encoding: .utf8) {
                let indented = reindentJSON(text, spacesPerLevel: 4)
                let restored = restoreJSONPlaceholders(in: indented, placeholders: prepared.placeholders)
                bodyEditorText = restored
                tab.request.body.raw = restored
                if tab.request.body.kind == .raw {
                    tab.request.body.kind = .json
                }
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func loadBodyEditorIfNeeded(force: Bool = false) {
        guard force || bodyEditorRequestID != tab.request.id else { return }
        bodyEditorRequestID = tab.request.id
        bodyEditorText = tab.request.body.raw
    }

    private func synchronizeBodyEditorToRequest() {
        if tab.request.body.raw != bodyEditorText {
            tab.request.body.raw = bodyEditorText
        }
        if tab.request.body.kind == .none && !bodyEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.request.body.kind = .raw
        }
    }

    private func parseJSONObject(from text: String) throws -> Any {
        do {
            let prepared = try prepareJSONForValidation(from: text)
            return try JSONSerialization.jsonObject(with: Data(prepared.sanitized.utf8))
        } catch {
            throw AppError.invalidDocument("Invalid JSON body: \(error.localizedDescription)")
        }
    }

    private func prepareJSONForValidation(from text: String) throws -> (sanitized: String, placeholders: [String: String]) {
        let pattern = #"(?<!["\\])(\{\{\s*[^{}\n]+\s*\}\})(?!\s*")"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else {
            return (text, [:])
        }

        var sanitized = text
        var placeholders: [String: String] = [:]

        for (index, match) in matches.enumerated().reversed() {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            let token = nsText.substring(with: range)
            let marker = "__EFBY_PLACEHOLDER_\(index)__"
            let replacement = "\"\(marker)\""
            let swiftRange = Range(range, in: sanitized)!
            sanitized.replaceSubrange(swiftRange, with: replacement)
            placeholders[marker] = token
        }

        return (sanitized, placeholders)
    }

    private func restoreJSONPlaceholders(in text: String, placeholders: [String: String]) -> String {
        var restored = text
        for (marker, token) in placeholders {
            restored = restored.replacingOccurrences(of: "\"\(marker)\"", with: token)
        }
        return restored
    }

    private func reindentJSON(_ text: String, spacesPerLevel: Int) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let leadingSpaces = line.prefix { $0 == " " }.count
                guard leadingSpaces > 0 else { return String(line) }
                let level = leadingSpaces / 2
                return String(repeating: " ", count: level * spacesPerLevel) + line.dropFirst(leadingSpaces)
            }
            .joined(separator: "\n")
    }

    private func darkInput(_ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: text, placeholder: placeholder)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        }
    }

    private func secureDarkInput(_ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(placeholder)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: text, placeholder: placeholder, isSecure: true)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        }
    }

    private func mutedText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(PostmanTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}
