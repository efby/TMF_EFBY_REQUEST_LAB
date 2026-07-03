import EfbyPresentation
import Foundation
import SwiftUI
import WebKit

struct BPMNEditorSelection: Equatable {
    var elementID: String?
    var name: String
    var bpmnType: String
    var nodeType: WorkspaceFlowNodeType

    static let empty = BPMNEditorSelection(
        elementID: nil,
        name: "",
        bpmnType: "",
        nodeType: .unsupported
    )
}

/// Renombrado de tarea BPMN solicitado desde Swift (p. ej. hoja de configuración); `requestID` desduplica aplicaciones.
struct BPMNPendingTaskRename: Equatable {
    var elementID: String
    var name: String
    var requestID: UUID
}

struct BPMNPendingElementRemoval: Equatable {
    var elementID: String
    var requestID: UUID
}

struct BPMNFlowWebEditor: NSViewRepresentable {
    @Binding var xml: String
    @Binding var graph: WorkspaceFlowGraphSnapshot
    @Binding var selection: BPMNEditorSelection
    @Binding var diagramViewport: WorkspaceFlowDiagramViewport?

    var taskBindings: [WorkspaceFlowTaskBinding]
    var availableRequests: [WorkspaceFlowRequestReference]
    /// Element ids to outline on the diagram (e.g. while a workspace flow run is in progress).
    var executionHighlightElementIDs: [String] = []
    @Binding var pendingTaskRename: BPMNPendingTaskRename?
    @Binding var pendingElementRemoval: BPMNPendingElementRemoval?
    var onError: (String) -> Void = { _ in }
    /// Invoked when the user double-clicks a task shape (not on single selection).
    var onTaskDoubleClicked: (BPMNEditorSelection) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            xml: $xml,
            graph: $graph,
            selection: $selection,
            diagramViewport: $diagramViewport,
            pendingTaskRename: $pendingTaskRename,
            pendingElementRemoval: $pendingElementRemoval,
            onError: onError,
            onTaskDoubleClicked: onTaskDoubleClicked
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: Coordinator.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(webView)

        guard let resolvedResource = Self.resolveEditorResources() else {
            onError("Could not find local BPMN editor resources in the app bundle.")
            return webView
        }

        webView.loadFileURL(resolvedResource.htmlURL, allowingReadAccessTo: resolvedResource.directoryURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            xml: xml,
            diagramViewport: diagramViewport,
            taskBindings: taskBindings,
            availableRequests: availableRequests,
            executionHighlightElementIDs: executionHighlightElementIDs,
            pendingTaskRename: pendingTaskRename,
            pendingElementRemoval: pendingElementRemoval,
            onTaskDoubleClicked: onTaskDoubleClicked
        )
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: nsView)
    }

    private static func resolveEditorResources() -> (htmlURL: URL, directoryURL: URL)? {
        for bundle in candidateBundles() {
            if let resolved = resolveEditorResources(in: bundle) {
                return resolved
            }
        }

        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/BPMN", isDirectory: true)
        let sourceHTMLURL = sourceDirectory.appendingPathComponent("bpmn-editor.html")
        if FileManager.default.fileExists(atPath: sourceHTMLURL.path) {
            return (sourceHTMLURL, sourceDirectory)
        }

        return nil
    }

    private static func candidateBundles() -> [Bundle] {
        final class BundleSentinel {}

        var bundles: [Bundle] = [Bundle.main, Bundle(for: BundleSentinel.self)]
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(contentsOf: Bundle.allFrameworks)

        var uniqueBundles: [Bundle] = []
        var seenPaths = Set<String>()

        for bundle in bundles {
            let bundlePath = bundle.bundleURL.standardizedFileURL.path
            guard seenPaths.insert(bundlePath).inserted else {
                continue
            }
            uniqueBundles.append(bundle)

            guard bundle.bundleURL.pathExtension != "bundle" else {
                continue
            }

            for bundleName in ["EfbyRequestLabs_EfbyRequestLabs.bundle", "EfbyRequestLabs.bundle"] {
                if let resourceURL = bundle.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
                   let nestedBundle = Bundle(url: resourceURL) {
                    let nestedPath = nestedBundle.bundleURL.standardizedFileURL.path
                    guard seenPaths.insert(nestedPath).inserted else {
                        continue
                    }
                    uniqueBundles.append(nestedBundle)
                }
            }
        }

        return uniqueBundles
    }

    private static func resolveEditorResources(in bundle: Bundle) -> (htmlURL: URL, directoryURL: URL)? {
        let candidates: [(htmlURL: URL, directoryURL: URL)] = [
            (
                bundle.bundleURL
                    .appendingPathComponent("Contents/Resources/BPMN", isDirectory: true)
                    .appendingPathComponent("bpmn-editor.html"),
                bundle.bundleURL.appendingPathComponent("Contents/Resources/BPMN", isDirectory: true)
            ),
            (
                bundle.bundleURL
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                    .appendingPathComponent("BPMN/bpmn-editor.html"),
                bundle.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            ),
            (
                bundle.bundleURL
                    .appendingPathComponent("bpmn-editor.html"),
                bundle.bundleURL
            ),
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.htmlURL.path) {
            return candidate
        }

        if let htmlURL = bundle.url(forResource: "bpmn-editor", withExtension: "html", subdirectory: "BPMN") {
            return (htmlURL, htmlURL.deletingLastPathComponent())
        }

        if let htmlURL = bundle.url(forResource: "bpmn-editor", withExtension: "html"),
           let resourceURL = bundle.resourceURL {
            return (htmlURL, resourceURL)
        }

        return nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "flowEditor"

        @Binding private var xml: String
        @Binding private var graph: WorkspaceFlowGraphSnapshot
        @Binding private var selection: BPMNEditorSelection
        @Binding private var diagramViewport: WorkspaceFlowDiagramViewport?
        @Binding private var pendingTaskRename: BPMNPendingTaskRename?
        @Binding private var pendingElementRemoval: BPMNPendingElementRemoval?

        private weak var webView: WKWebView?
        private var isReady = false
        private var pendingXML: String = ""
        private var pendingDiagramViewport: WorkspaceFlowDiagramViewport?
        private var pendingBindings: [WorkspaceFlowTaskBinding] = []
        private var pendingRequests: [WorkspaceFlowRequestReference] = []
        private var pendingExecutionHighlightElementIDs: [String] = []
        private var lastSentExecutionHighlightSignature: String?
        private var lastImportedXML: String = ""
        private var lastExportedXML: String = ""
        private var lastAppliedTaskRenameRequestID: UUID?
        private var lastAppliedElementRemovalRequestID: UUID?
        private let onError: (String) -> Void
        private var onTaskDoubleClicked: (BPMNEditorSelection) -> Void

        init(
            xml: Binding<String>,
            graph: Binding<WorkspaceFlowGraphSnapshot>,
            selection: Binding<BPMNEditorSelection>,
            diagramViewport: Binding<WorkspaceFlowDiagramViewport?>,
            pendingTaskRename: Binding<BPMNPendingTaskRename?>,
            pendingElementRemoval: Binding<BPMNPendingElementRemoval?>,
            onError: @escaping (String) -> Void,
            onTaskDoubleClicked: @escaping (BPMNEditorSelection) -> Void
        ) {
            self._xml = xml
            self._graph = graph
            self._selection = selection
            self._diagramViewport = diagramViewport
            self._pendingTaskRename = pendingTaskRename
            self._pendingElementRemoval = pendingElementRemoval
            self.onError = onError
            self.onTaskDoubleClicked = onTaskDoubleClicked
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func detach(from webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
            if self.webView === webView {
                self.webView = nil
            }
        }

        func update(
            xml: String,
            diagramViewport: WorkspaceFlowDiagramViewport?,
            taskBindings: [WorkspaceFlowTaskBinding],
            availableRequests: [WorkspaceFlowRequestReference],
            executionHighlightElementIDs: [String],
            pendingTaskRename: BPMNPendingTaskRename?,
            pendingElementRemoval: BPMNPendingElementRemoval?,
            onTaskDoubleClicked: @escaping (BPMNEditorSelection) -> Void
        ) {
            self.onTaskDoubleClicked = onTaskDoubleClicked
            pendingXML = xml.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingDiagramViewport = diagramViewport
            pendingBindings = taskBindings
            pendingRequests = availableRequests
            pendingExecutionHighlightElementIDs = executionHighlightElementIDs
            syncToJavaScriptIfReady()
            applyPendingTaskRenameIfNeeded(pendingTaskRename)
            applyPendingElementRemovalIfNeeded(pendingElementRemoval)
            applyExecutionHighlightsIfNeeded()
        }

        private func applyPendingElementRemovalIfNeeded(_ request: BPMNPendingElementRemoval?) {
            guard isReady, let webView, let request else { return }
            guard request.requestID != lastAppliedElementRemovalRequestID else { return }
            lastAppliedElementRemovalRequestID = request.requestID

            webView.callAsyncJavaScript(
                "window.FlowEditorBridge.removeElement(elementID)",
                arguments: ["elementID": request.elementID],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    switch result {
                    case .success:
                        self.pendingElementRemoval = nil
                    case .failure(let error):
                        self.lastAppliedElementRemovalRequestID = nil
                        self.pendingElementRemoval = nil
                        self.onError("No se pudo borrar el elemento: \(error.localizedDescription)")
                    }
                }
            }
        }

        private func applyPendingTaskRenameIfNeeded(_ request: BPMNPendingTaskRename?) {
            guard isReady, let webView, let request else { return }
            guard request.requestID != lastAppliedTaskRenameRequestID else { return }
            lastAppliedTaskRenameRequestID = request.requestID

            webView.callAsyncJavaScript(
                "window.FlowEditorBridge.setTaskName(elementID, name)",
                arguments: ["elementID": request.elementID, "name": request.name],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    switch result {
                    case .success:
                        self.pendingTaskRename = nil
                    case .failure(let error):
                        self.lastAppliedTaskRenameRequestID = nil
                        self.pendingTaskRename = nil
                        self.onError("Could not rename task: \(error.localizedDescription)")
                    }
                }
            }
        }

        private func applyExecutionHighlightsIfNeeded() {
            guard isReady, let webView else { return }
            let signature = pendingExecutionHighlightElementIDs.joined(separator: "\u{1c}")
            guard signature != lastSentExecutionHighlightSignature else { return }
            lastSentExecutionHighlightSignature = signature

            webView.callAsyncJavaScript(
                "window.FlowEditorBridge.setExecutionHighlights(ids)",
                arguments: ["ids": pendingExecutionHighlightElementIDs],
                in: nil,
                in: .page
            ) { _ in }
        }

        private func syncToJavaScriptIfReady() {
            guard isReady, let webView else { return }

            let bindings = Dictionary(uniqueKeysWithValues: pendingBindings.compactMap { binding in
                binding.requestID.map { (binding.elementID, $0.uuidString) }
            })
            let requestLabels = Dictionary(uniqueKeysWithValues: pendingRequests.map {
                ($0.requestID.uuidString, $0.requestName)
            })

            webView.callAsyncJavaScript(
                "window.FlowEditorBridge.setBindings(bindings, requestLabels)",
                arguments: [
                    "bindings": bindings,
                    "requestLabels": requestLabels
                ],
                in: nil,
                in: .page
            ) { _ in }

            if !pendingXML.isEmpty,
               pendingXML != lastImportedXML,
               pendingXML != lastExportedXML {
                var importArguments: [String: Any] = ["xml": pendingXML]
                if let viewport = pendingDiagramViewport {
                    importArguments["viewport"] = [
                        "zoomPercent": viewport.zoomPercent,
                        "viewboxX": viewport.viewboxX,
                        "viewboxY": viewport.viewboxY,
                        "viewboxWidth": viewport.viewboxWidth,
                        "viewboxHeight": viewport.viewboxHeight,
                    ]
                } else {
                    importArguments["viewport"] = NSNull()
                }

                webView.callAsyncJavaScript(
                    "await window.FlowEditorBridge.importXML(xml, viewport)",
                    arguments: importArguments,
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success:
                        self.lastImportedXML = self.pendingXML
                        self.lastSentExecutionHighlightSignature = nil
                        self.applyExecutionHighlightsIfNeeded()
                    case .failure(let error):
                        self.onError("Failed to import BPMN XML: \(error.localizedDescription)")
                    }
                }
            }

            applyExecutionHighlightsIfNeeded()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "ready":
                isReady = true
                syncToJavaScriptIfReady()

            case "diagramChanged":
                if let xml = body["xml"] as? String {
                    let normalizedXML = xml.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastExportedXML = normalizedXML
                    self.xml = xml
                }
                if let summaryDictionary = body["summary"] as? [String: Any],
                   let graph = decodeGraph(from: summaryDictionary) {
                    self.graph = graph
                }
                if let viewport = decodeDiagramViewport(from: body) {
                    self.diagramViewport = viewport
                }

            case "viewportChanged":
                if let viewport = decodeDiagramViewport(from: body) {
                    self.diagramViewport = viewport
                }

            case "taskDoubleClicked":
                let picked = BPMNEditorSelection(
                    elementID: body["elementID"] as? String,
                    name: body["name"] as? String ?? "",
                    bpmnType: body["bpmnType"] as? String ?? "",
                    nodeType: WorkspaceFlowNodeType(rawValue: body["nodeType"] as? String ?? "") ?? .unsupported
                )
                selection = picked
                onTaskDoubleClicked(picked)

            case "selectionChanged":
                selection = BPMNEditorSelection(
                    elementID: body["elementID"] as? String,
                    name: body["name"] as? String ?? "",
                    bpmnType: body["bpmnType"] as? String ?? "",
                    nodeType: WorkspaceFlowNodeType(rawValue: body["nodeType"] as? String ?? "") ?? .unsupported
                )

            case "error":
                onError(body["message"] as? String ?? "Unknown BPMN editor error.")

            default:
                break
            }
        }

        private func decodeGraph(from dictionary: [String: Any]) -> WorkspaceFlowGraphSnapshot? {
            guard JSONSerialization.isValidJSONObject(dictionary),
                  let data = try? JSONSerialization.data(withJSONObject: dictionary),
                  let graph = try? JSONDecoder().decode(WorkspaceFlowGraphSnapshot.self, from: data) else {
                return nil
            }
            return graph
        }

        private func decodeDiagramViewport(from body: [String: Any]) -> WorkspaceFlowDiagramViewport? {
            if let nested = body["diagramViewport"] as? [String: Any] {
                return Self.decodeDiagramViewportDictionary(nested)
            }
            return Self.decodeDiagramViewportDictionary(body)
        }

        private static func decodeDiagramViewportDictionary(_ dictionary: [String: Any]) -> WorkspaceFlowDiagramViewport? {
            guard let zoomPercent = doubleValue(dictionary["zoomPercent"]),
                  let viewboxX = doubleValue(dictionary["viewboxX"]),
                  let viewboxY = doubleValue(dictionary["viewboxY"]),
                  let viewboxWidth = doubleValue(dictionary["viewboxWidth"]),
                  let viewboxHeight = doubleValue(dictionary["viewboxHeight"]),
                  viewboxWidth > 0,
                  viewboxHeight > 0,
                  zoomPercent > 0
            else {
                return nil
            }
            return WorkspaceFlowDiagramViewport(
                zoomPercent: zoomPercent,
                viewboxX: viewboxX,
                viewboxY: viewboxY,
                viewboxWidth: viewboxWidth,
                viewboxHeight: viewboxHeight
            )
        }

        private static func doubleValue(_ value: Any?) -> Double? {
            switch value {
            case let number as Double:
                return number
            case let number as Float:
                return Double(number)
            case let number as Int:
                return Double(number)
            case let number as Int64:
                return Double(number)
            case let number as NSNumber:
                return number.doubleValue
            default:
                return nil
            }
        }
    }
}
