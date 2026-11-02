import AppKit
import EfbyPresentation
import SwiftUI

private enum ResponseTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case response = "Response"
    case headers = "Headers"
    case exchange = "HTTP"
    case logs = "Console"

    var id: String { rawValue }
}

private enum WebSocketTranscriptFilter: String, CaseIterable, Identifiable {
    case all = "All Messages"
    case incoming = "Incoming"
    case outgoing = "Outgoing"
    case system = "Events"

    var id: String { rawValue }

    func includes(_ direction: WebSocketTranscriptDirection) -> Bool {
        switch self {
        case .all:
            return true
        case .incoming:
            return direction == .incoming
        case .outgoing:
            return direction == .outgoing
        case .system:
            return direction == .system
        }
    }
}

struct ResponsePane: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var selectedPane: ResponseTab = .response
    @State private var transcriptSearchText = ""
    @State private var transcriptFilter: WebSocketTranscriptFilter = .all
    @State private var consoleSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 18) {
                    ForEach(availablePanes) { pane in
                        paneButton(pane)
                    }
                }

                Spacer()

                if tab.request.transportKind == .webSocket {
                    Text(tab.webSocketConnectionState.displayName)
                        .foregroundStyle(webSocketStateColor)
                    Text("•")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("\(tab.webSocketTranscript.count) events")
                        .foregroundStyle(PostmanTheme.textSecondary)
                } else if let response = tab.response {
                    Text("\(response.statusCode) \(response.statusText)")
                        .foregroundStyle(statusColor(response.statusCode))
                        .accessibilityIdentifier("response.status")
                    Text("•")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("\(Int(response.durationMilliseconds)) ms")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("•")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    Text("\(response.sizeBytes) bytes")
                        .foregroundStyle(PostmanTheme.textSecondary)
                } else if tab.isSending {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Sending request...")
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .accessibilityIdentifier("response.sending")
                    }
                } else {
                    Text("Send a request to visualize response")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .accessibilityIdentifier("response.empty")
                }

                Button {
                    copyCurrentPaneContent()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(!canCopyCurrentPaneContent)

                Button {
                    viewModel.saveResponseToDisk()
                } label: {
                    Text(tab.request.transportKind == .webSocket ? "Save Transcript" : "Save Response")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(tab.request.transportKind == .webSocket ? tab.webSocketTranscript.isEmpty : tab.response == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(PostmanTheme.panel)

            Divider().overlay(PostmanTheme.border)

            Group {
                switch selectedPane {
                case .transcript:
                    transcriptViewer
                case .response:
                    VStack(alignment: .leading, spacing: 0) {
                        if tab.isSending {
                            loadingPlaceholder
                                .padding(18)
                        } else if let response = tab.response {
                            responseViewer(for: response)
                                .padding(18)
                        } else {
                            responsePlaceholder
                                .padding(18)
                        }
                    }
                case .headers:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if tab.isSending {
                                loadingPlaceholder
                            } else {
                                ForEach(tab.response?.headers ?? []) { header in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(header.key)
                                            .font(.body.monospaced())
                                            .foregroundStyle(PostmanTheme.textPrimary)
                                            .frame(width: 220, alignment: .leading)
                                        Text(header.value)
                                            .font(.body.monospaced())
                                            .foregroundStyle(PostmanTheme.textSecondary)
                                            .textSelection(.enabled)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding(18)
                    }
                case .exchange:
                    exchangeViewer
                case .logs:
                    consoleViewer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PostmanTheme.appBackground)
        }
        .onAppear {
            ensureValidSelectedPane()
        }
        .onChange(of: tab.request.transportKind) { _, _ in
            ensureValidSelectedPane()
        }
    }

    private var exchangeViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rawHTTPSection(
                    title: tab.request.transportKind == .webSocket ? "Handshake" : "Request",
                    text: tab.rawRequestText,
                    placeholder: tab.isSending
                        ? (tab.request.transportKind == .webSocket ? "Preparing handshake..." : "Capturing request...")
                        : (tab.request.transportKind == .webSocket ? "Connect to capture the WebSocket handshake request." : "Send a request to capture the raw HTTP request.")
                )

                rawHTTPSection(
                    title: tab.request.transportKind == .webSocket ? "Notes" : "Response",
                    text: tab.rawResponseText,
                    placeholder: tab.request.transportKind == .webSocket
                        ? "Incoming frames are shown in the Transcript tab."
                        : (tab.isSending ? "Waiting for response..." : "Send a request to capture the raw HTTP response.")
                )
            }
            .padding(18)
        }
    }

    private var consoleViewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                terminalWindowDot(Color(nsColor: .systemRed))
                terminalWindowDot(Color(nsColor: .systemYellow))
                terminalWindowDot(Color(nsColor: .systemGreen))

                Text(tab.request.transportKind == .webSocket ? "websocket-console" : "response-console")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(PostmanTheme.textSecondary)

                Spacer()

                Text(consoleSummaryText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(PostmanTheme.textSecondary.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(consoleHeaderBackground)

            Divider().overlay(PostmanTheme.border)

            consoleSearchField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(consoleHeaderBackground)

            Divider().overlay(PostmanTheme.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if tab.isSending {
                        loadingPlaceholder
                            .padding(.vertical, 24)
                    } else if tab.consoleLogs.isEmpty {
                        Text("No console output yet.")
                            .font(.body.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if filteredConsoleLogEntries.isEmpty {
                        Text("No lines match “\(consoleSearchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                            .font(.body.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(filteredConsoleLogEntries, id: \.index) { entry in
                            consoleLineRow(index: entry.index, line: entry.line)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(consoleBackground)
        }
        .background(consoleBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
        .padding(18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("response.console")
    }

    private var transcriptViewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                transcriptSearchField

                Picker("Messages", selection: $transcriptFilter) {
                    ForEach(WebSocketTranscriptFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Button("Clear Messages", systemImage: "trash") {
                    tab.webSocketTranscript.removeAll()
                    transcriptSearchText = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(tab.webSocketTranscript.isEmpty)

                Spacer()

                if tab.request.transportKind == .webSocket {
                    Text(tab.webSocketConnectionState.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(webSocketStateColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(webSocketStateColor.opacity(0.16), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(PostmanTheme.border)

            if tab.request.webSocketPingIntervalSeconds > 0 {
                pingSummaryView
                Divider().overlay(PostmanTheme.border)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredTranscriptEntries.isEmpty {
                        Text(tab.webSocketTranscript.isEmpty ? "No WebSocket messages yet." : "No messages match the current filters.")
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(Array(filteredTranscriptEntries.enumerated()), id: \.element.id) { _, entry in
                            transcriptRow(for: entry)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var pingSummaryView: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(PostmanTheme.orange)
                .frame(width: 30, height: 30)
                .background(PostmanTheme.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Ping Monitor")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text(pingSummaryText)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Count: \(tab.webSocketPingSentCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(PostmanTheme.textPrimary)
                Text("Interval: \(formattedWebSocketSeconds(tab.request.webSocketPingIntervalSeconds))")
                    .font(.caption.monospaced())
                    .foregroundStyle(PostmanTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PostmanTheme.panel.opacity(0.45))
    }

    private var availablePanes: [ResponseTab] {
        if tab.request.transportKind == .webSocket {
            return [.transcript, .exchange, .logs]
        }
        return [.response, .headers, .exchange, .logs]
    }

    private func paneButton(_ tab: ResponseTab) -> some View {
        Button {
            selectedPane = tab
        } label: {
            Text(tab.rawValue)
                .foregroundStyle(selectedPane == tab ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if selectedPane == tab {
                        Rectangle()
                            .fill(PostmanTheme.orange)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("response.tab.\(tab.rawValue)")
        .accessibilityValue(selectedPane == tab ? "selected" : "unselected")
    }

    private func ensureValidSelectedPane() {
        if !availablePanes.contains(selectedPane) {
            selectedPane = availablePanes.first ?? .logs
        }
    }

    private var responsePlaceholder: some View {
        Text("No response yet.")
            .foregroundStyle(PostmanTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func responseViewer(for response: HTTPResponseModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(documentTypeLabel(for: response))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(PostmanTheme.panel, in: Capsule())

                if let mimeType = response.mimeType, !mimeType.isEmpty {
                    Text(mimeType)
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary)
                }

                Spacer()
            }

            MacCodeEditor(
                text: .constant(response.body),
                language: responseEditorLanguage(for: response),
                showsLineNumbers: false,
                isEditable: false
            )
            .accessibilityIdentifier("response.body")
            .accessibilityLabel("Response body")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(tab.request.transportKind == .webSocket ? "Connecting WebSocket..." : "Sending request...")
                .foregroundStyle(PostmanTheme.textPrimary)
            Text(
                tab.request.transportKind == .webSocket
                    ? "Waiting for the handshake and the first incoming frames."
                    : "Waiting for response, headers, and console output."
            )
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func rawHTTPSection(title: String, text: String?, placeholder: String) -> some View {
        let display: String = {
            guard let text, !text.isEmpty else { return placeholder }
            return text
        }()
        let isPlaceholder = text?.isEmpty ?? true

        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(PostmanTheme.textSecondary)

            Text(display)
                .font(.body.monospaced())
                .foregroundStyle(isPlaceholder ? PostmanTheme.textSecondary : PostmanTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
        }
    }

    private func responseEditorLanguage(for response: HTTPResponseModel) -> CodeEditorLanguage {
        let mimeType = response.mimeType?.lowercased() ?? ""
        let body = response.body.trimmingCharacters(in: .whitespacesAndNewlines)

        if mimeType.contains("json") || body.hasPrefix("{") || body.hasPrefix("[") {
            return .json
        }

        if mimeType.contains("html") || body.lowercased().contains("<html") {
            return .html
        }

        if mimeType.contains("xml") || body.hasPrefix("<") {
            return .xml
        }

        if mimeType.contains("markdown") {
            return .markdown
        }

        return .plainText
    }

    private func documentTypeLabel(for response: HTTPResponseModel) -> String {
        switch responseEditorLanguage(for: response) {
        case .json:
            return "JSON"
        case .xml:
            return "XML"
        case .html:
            return "HTML"
        case .javascript:
            return "JavaScript"
        case .markdown:
            return "Markdown"
        case .plainText:
            return "Text"
        }
    }

    private func statusColor(_ statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300:
            return PostmanTheme.green
        case 400..<600:
            return .red
        default:
            return PostmanTheme.textPrimary
        }
    }

    private var webSocketStateColor: Color {
        switch tab.webSocketConnectionState {
        case .connected:
            return PostmanTheme.green
        case .failed:
            return PostmanTheme.salmon
        case .connecting, .disconnecting:
            return PostmanTheme.orange
        case .disconnected:
            return PostmanTheme.textSecondary
        }
    }

    private func transcriptColor(for direction: WebSocketTranscriptDirection) -> Color {
        switch direction {
        case .incoming:
            return PostmanTheme.green
        case .outgoing:
            return PostmanTheme.accent
        case .system:
            return PostmanTheme.orange
        }
    }

    private func consoleLineCopyButton(line: String) -> some View {
        Button {
            PlatformClipboard.copyPlainText(line)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PostmanTheme.textSecondary.opacity(0.85))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 22, minHeight: 22)
        .help("Copiar solo esta línea")
        .accessibilityLabel("Copiar esta línea al portapapeles")
    }

    private func consoleLineRow(index: Int, line: String) -> some View {
        Group {
            if let inline = WorkspaceFlowInlineImageLogLine.parse(line) {
                HStack(alignment: .top, spacing: 12) {
                    Text(String(format: "%03d", index + 1))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)

                    Text("▣")
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 14, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(inline.caption)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PostmanTheme.textPrimary)

                        if let nsImage = NSImage(contentsOf: inline.fileURL) {
                            Image(nsImage: nsImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 280, maxHeight: 280)
                                .padding(6)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("PNG no disponible (temporal borrado o ruta inválida).")
                                .font(.caption.monospaced())
                                .foregroundStyle(PostmanTheme.salmon)
                        }

                        Text(inline.fileURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(PostmanTheme.textSecondary.opacity(0.85))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    consoleLineCopyButton(line: line)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.015))
            } else if let md = MarkdownLogFormatting.attributedLogLine(line) {
                HStack(alignment: .top, spacing: 12) {
                    Text(String(format: "%03d", index + 1))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)

                    Text("MD")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 18, alignment: .leading)

                    Text(md)
                        .font(.system(size: 13))
                        .foregroundStyle(PostmanTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    consoleLineCopyButton(line: line)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.015))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Text(String(format: "%03d", index + 1))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary.opacity(0.7))
                        .frame(width: 34, alignment: .trailing)

                    Text(consolePrompt(for: line))
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(consoleColor(for: line))
                        .frame(width: 14, alignment: .leading)

                    Text(line)
                        .accessibilityIdentifier("response.console.line.\(index)")
                        .font(.body.monospaced())
                        .foregroundStyle(consoleColor(for: line))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    consoleLineCopyButton(line: line)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.015))
            }
        }
    }

    private func consolePrompt(for line: String) -> String {
        let normalized = line.lowercased()
        if normalized.hasPrefix("error") || normalized.contains(" error") {
            return "!"
        }
        if normalized.contains("completed successfully") || normalized.contains("connected.") || normalized.contains("reconnected.") {
            return ">"
        }
        if normalized.contains("warning") || normalized.contains("reconnect") {
            return "~"
        }
        return "$"
    }

    private func consoleColor(for line: String) -> Color {
        let normalized = line.lowercased()
        if normalized.hasPrefix("error") || normalized.contains(" error") {
            return PostmanTheme.salmon
        }
        if normalized.contains("completed successfully") || normalized.contains("connected.") || normalized.contains("reconnected.") {
            return PostmanTheme.green
        }
        if normalized.contains("warning") || normalized.contains("reconnect") {
            return PostmanTheme.orange
        }
        return PostmanTheme.textPrimary
    }

    private func terminalWindowDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private var consoleSummaryText: String {
        if tab.isSending {
            return tab.request.transportKind == .webSocket ? "connecting..." : "sending..."
        }
        let total = tab.consoleLogs.count
        let query = consoleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, total > 0 else {
            return "\(total) line" + (total == 1 ? "" : "s")
        }
        let shown = filteredConsoleLogEntries.count
        return "\(shown) of \(total) lines"
    }

    /// Líneas de contexto por encima y debajo de cada coincidencia, y **todo el tramo** entre la primera y la última coincidencia,
    /// para que permanezcan visibles los `PASS`/`FAIL` de `pm.test` y el resto del log de los casos en esa ejecución.
    private static let consoleSearchNeighborLineCount = 4

    /// Pairs `(originalLineIndex, line)` for display; indices are 0-based into `tab.consoleLogs`.
    private var filteredConsoleLogEntries: [(index: Int, line: String)] {
        let query = consoleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let logs = tab.consoleLogs
        let enumerated = Array(logs.enumerated())
        guard !query.isEmpty else {
            return enumerated.map { ($0.offset, $0.element) }
        }
        let matchIndices = enumerated.compactMap { idx, line in
            lineMatchesConsoleSearch(line, query: query) ? idx : nil
        }
        guard let firstMatch = matchIndices.min(), let lastMatch = matchIndices.max() else {
            return []
        }
        let radius = Self.consoleSearchNeighborLineCount
        let lo = max(0, firstMatch - radius)
        let hi = min(logs.count - 1, lastMatch + radius)
        return (lo...hi).map { index in (index, logs[index]) }
    }

    private func lineMatchesConsoleSearch(_ line: String, query: String) -> Bool {
        if line.localizedCaseInsensitiveContains(query) {
            return true
        }
        if let inline = WorkspaceFlowInlineImageLogLine.parse(line) {
            if inline.caption.localizedCaseInsensitiveContains(query) { return true }
            if inline.fileURL.path.localizedCaseInsensitiveContains(query) { return true }
            if inline.fileURL.lastPathComponent.localizedCaseInsensitiveContains(query) { return true }
        }
        return false
    }

    private var consoleSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: $consoleSearchText, placeholder: "Search console…")
            if !consoleSearchText.isEmpty {
                Button {
                    consoleSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PostmanTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        .help("Matches plus nearby lines and everything between the first and last match (keeps pm.test PASS/FAIL and run context).")
    }

    private var consoleBackground: Color {
        Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1))
    }

    private var consoleHeaderBackground: Color {
        Color(nsColor: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1))
    }

    private var filteredTranscriptEntries: [WebSocketTranscriptEntry] {
        Array(
            tab.webSocketTranscript
            .filter { entry in
                transcriptFilter.includes(entry.direction)
            }
            .filter { entry in
                let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                return entry.body.localizedCaseInsensitiveContains(query)
                    || entry.direction.rawValue.localizedCaseInsensitiveContains(query)
            }
            .reversed()
        )
    }

    private var transcriptSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PostmanTheme.textSecondary)
            DarkTextInput(text: $transcriptSearchText, placeholder: "Search")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PostmanTheme.border))
        .frame(maxWidth: 300)
    }

    private func transcriptRow(for entry: WebSocketTranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: transcriptIcon(for: entry.direction))
                .font(.headline.weight(.semibold))
                .foregroundStyle(transcriptColor(for: entry.direction))
                .frame(width: 28, height: 28)
                .background(transcriptColor(for: entry.direction).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(transcriptTitle(for: entry.direction))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Text(transcriptPreview(for: entry.body))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(entry.createdAt.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospaced())
                        .foregroundStyle(PostmanTheme.textSecondary)
                }

                Text(entry.body)
                    .font(.body.monospaced())
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
    }

    private func transcriptTitle(for direction: WebSocketTranscriptDirection) -> String {
        switch direction {
        case .incoming:
            return "Incoming"
        case .outgoing:
            return "Outgoing"
        case .system:
            return "Event"
        }
    }

    private func transcriptIcon(for direction: WebSocketTranscriptDirection) -> String {
        switch direction {
        case .incoming:
            return "arrow.down"
        case .outgoing:
            return "arrow.up"
        case .system:
            return "checkmark.circle"
        }
    }

    private func transcriptPreview(for body: String) -> String {
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(firstLine.prefix(80))
    }

    private var pingSummaryText: String {
        if let lastPing = tab.webSocketLastPingSentAt {
            return "Last sent at \(lastPing.formatted(date: .omitted, time: .standard))."
        }
        return "No ping frames sent yet in this session."
    }

    private func formattedWebSocketSeconds(_ value: Double) -> String {
        if value == 0 {
            return "0s"
        }
        if value.rounded() == value {
            return "\(Int(value))s"
        }
        return "\(value.formatted())s"
    }

    private var canCopyCurrentPaneContent: Bool {
        switch selectedPane {
        case .transcript:
            return !tab.webSocketTranscript.isEmpty
        case .response:
            return tab.response?.body.isEmpty == false
        case .headers:
            return !(tab.response?.headers.isEmpty ?? true)
        case .exchange:
            return !(tab.rawRequestText?.isEmpty ?? true) || !(tab.rawResponseText?.isEmpty ?? true)
        case .logs:
            return !filteredConsoleLogEntries.isEmpty
        }
    }

    private func copyCurrentPaneContent() {
        let content: String

        switch selectedPane {
        case .transcript:
            guard !tab.webSocketTranscript.isEmpty else { return }
            content = tab.webSocketTranscript
                .map { "[\($0.createdAt.formatted(date: .omitted, time: .standard))] \($0.direction.rawValue.uppercased()): \($0.body)" }
                .joined(separator: "\n\n")
        case .response:
            guard let body = tab.response?.body, !body.isEmpty else { return }
            content = body
        case .headers:
            let headers = tab.response?.headers ?? []
            guard !headers.isEmpty else { return }
            content = headers
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        case .exchange:
            let sections = [
                tab.rawRequestText.map { "Request\n\($0)" },
                tab.rawResponseText.map { "Response\n\($0)" },
            ]
            .compactMap { $0 }

            guard !sections.isEmpty else { return }
            content = sections.joined(separator: "\n\n")
        case .logs:
            guard !filteredConsoleLogEntries.isEmpty else { return }
            content = filteredConsoleLogEntries.map(\.line).joined(separator: "\n")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }
}
