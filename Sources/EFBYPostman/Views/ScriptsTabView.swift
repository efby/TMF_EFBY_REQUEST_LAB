import EfbyPresentation
import OSLog
import SwiftUI

struct ScriptsTabView: View {
    private static let logger = Logger(subsystem: "com.efby.requestlabs", category: "ScriptsTab")

    let requestID: UUID
    let transportKind: RequestTransportKind
    let refreshToken: UUID
    let utilityLibraries: [WorkspaceScriptUtility]
    @Binding var scripts: [ScriptDefinition]
    @Binding var selectedPanelRawValue: String
    @Binding var scrollOffsets: [String: Double]

    @State private var preRequestSource = ""
    @State private var testSource = ""
    @State private var hasLoadedScripts = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            MacCodeEditor(
                text: activeScriptBinding,
                verticalScrollOffset: activeScrollOffsetBinding,
                language: .javascript,
                showsLineNumbers: true,
                autocompleteContext: .javascript(workspaceUtilities: utilityLibraries)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
            .padding(16)
        }
        .background(PostmanTheme.panelElevated)
        .onAppear {
            loadScriptsIfNeeded()
            Self.logger.notice("Scripts tab appeared. preRequestLength=\(preRequestSource.count, privacy: .public) testLength=\(testSource.count, privacy: .public)")
        }
        .onDisappear {
            Self.logger.notice("Scripts tab disappeared.")
        }
        .onChange(of: selectedScriptPanel) { _, newValue in
            selectedPanelRawValue = newValue.storageKey
            Self.logger.notice("Scripts tab switched panel to \(newValue.sidebarTitle(for: transportKind), privacy: .public). length=\(source(for: newValue).count, privacy: .public)")
        }
        .onChange(of: preRequestSource) { _, newValue in
            guard hasLoadedScripts else { return }
            persistScript(.preRequest, source: newValue)
        }
        .onChange(of: testSource) { _, newValue in
            guard hasLoadedScripts else { return }
            persistScript(.test, source: newValue)
        }
        .onChange(of: requestID) { _, _ in
            reloadScriptsForCurrentRequest()
        }
        .onChange(of: refreshToken) { _, _ in
            reloadScriptsForCurrentRequest()
        }
        .onAppear {
            selectedPanelRawValue = selectedScriptPanel.storageKey
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            modeButton(.preRequest)
            modeButton(.test)
            Spacer()

            Button {
                formatSelectedScriptSource()
            } label: {
                Text("Format")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(currentScriptHasContent ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(PostmanTheme.panel, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!currentScriptHasContent)

            Text("JavaScript")
                .font(.caption.weight(.medium))
                .foregroundStyle(PostmanTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(PostmanTheme.panel, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var currentScriptHasContent: Bool {
        !source(for: selectedScriptPanel).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedScriptPanel: ScriptPanel {
        get { ScriptPanel(storageKey: selectedPanelRawValue) ?? .preRequest }
        nonmutating set { selectedPanelRawValue = newValue.storageKey }
    }

    private var activeScriptBinding: Binding<String> {
        Binding(
            get: { source(for: selectedScriptPanel) },
            set: { newValue in
                switch selectedScriptPanel {
                case .preRequest:
                    preRequestSource = newValue
                case .test:
                    testSource = newValue
                }
            }
        )
    }

    private var activeScrollOffsetBinding: Binding<Double> {
        Binding(
            get: { scrollOffsets[selectedScriptPanel.scrollStorageKey] ?? 0 },
            set: { scrollOffsets[selectedScriptPanel.scrollStorageKey] = $0 }
        )
    }

    private func modeButton(_ panel: ScriptPanel) -> some View {
        Button {
            selectedScriptPanel = panel
        } label: {
            HStack(spacing: 8) {
                Text(panel.sidebarTitle(for: transportKind))
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .lineLimit(1)

                if panel == .test && transportKind == .webSocket {
                    Text("Incoming")
                        .font(.caption2)
                        .foregroundStyle(PostmanTheme.textSecondary)
                }
                if !source(for: panel).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Circle()
                        .fill(PostmanTheme.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                selectedScriptPanel == panel ? PostmanTheme.activeTab : PostmanTheme.panel,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selectedScriptPanel == panel ? PostmanTheme.border.opacity(0.6) : PostmanTheme.border)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(panel.sidebarTitle(for: transportKind))
    }

    private func loadScriptsIfNeeded() {
        guard !hasLoadedScripts else { return }
        reloadScriptsForCurrentRequest()
        hasLoadedScripts = true
    }

    private func reloadScriptsForCurrentRequest() {
        preRequestSource = sourceForLatestScript(listeningTo: .preRequest)
        testSource = sourceForLatestScript(listeningTo: .test)
    }

    private func source(for panel: ScriptPanel) -> String {
        switch panel {
        case .preRequest:
            return preRequestSource
        case .test:
            return testSource
        }
    }

    private func persistScript(_ panel: ScriptPanel, source: String) {
        let event = panel.event
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)

        scripts.removeAll(where: { $0.listen == event })

        if !trimmedSource.isEmpty {
            scripts.append(
                ScriptDefinition(
                    name: event.rawValue,
                    listen: event,
                    language: "javascript",
                    source: source
                )
            )
        }
    }

    private func sourceForLatestScript(listeningTo event: ScriptEventType) -> String {
        scripts.last(where: { $0.listen == event })?.source ?? ""
    }

    private func formatSelectedScriptSource() {
        let formatted = JavaScriptSourceFormatter.format(source(for: selectedScriptPanel))

        guard formatted != source(for: selectedScriptPanel) else { return }

        switch selectedScriptPanel {
        case .preRequest:
            preRequestSource = formatted
        case .test:
            testSource = formatted
        }
    }
}
