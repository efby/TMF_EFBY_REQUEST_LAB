import Foundation
import OSLog
import SwiftUI
import WebKit

private let macCodeEditorLogger = Logger(subsystem: "com.efby.requestlabs", category: "MacCodeEditor")

enum CodeEditorLanguage {
    case plainText
    case json
    case xml
    case html
    case javascript
    /// Contenido Markdown (.md, notas); en Ace usa modo texto con tema estilo VS Code.
    case markdown
}

struct MacCodeEditor: NSViewRepresentable {
    @Binding var text: String
    private var verticalScrollOffset: Binding<Double>?
    var fontSize: CGFloat = 13
    var language: CodeEditorLanguage = .plainText
    var showsLineNumbers: Bool = false
    var isEditable: Bool = true
    var tabWidth: Int? = nil
    var autocompleteContext: CodeEditorAutocompleteContext = .empty
    /// Cada clic en el editor selecciona todo el documento (p. ej. credenciales AWS para borrar/pegar rápido).
    var selectEntireDocumentOnClick: Bool = false

    init(
        text: Binding<String>,
        verticalScrollOffset: Binding<Double>? = nil,
        fontSize: CGFloat = 13,
        language: CodeEditorLanguage = .plainText,
        showsLineNumbers: Bool = false,
        isEditable: Bool = true,
        tabWidth: Int? = nil,
        autocompleteContext: CodeEditorAutocompleteContext = .empty,
        selectEntireDocumentOnClick: Bool = false
    ) {
        self._text = text
        self.verticalScrollOffset = verticalScrollOffset
        self.fontSize = fontSize
        self.language = language
        self.showsLineNumbers = showsLineNumbers
        self.isEditable = isEditable
        self.tabWidth = tabWidth
        self.autocompleteContext = autocompleteContext
        self.selectEntireDocumentOnClick = selectEntireDocumentOnClick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, verticalScrollOffset: verticalScrollOffset)
    }

    func makeNSView(context: Context) -> WKWebView {
        macCodeEditorLogger.notice(
            "makeNSView language=\(language.debugName, privacy: .public) showsLineNumbers=\(showsLineNumbers, privacy: .public) textLength=\(text.count, privacy: .public)"
        )

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false

        context.coordinator.attach(webView)

        guard let resolvedResource = Self.resolveEditorResources() else {
            macCodeEditorLogger.error("Could not locate bundled code editor resources")
            return webView
        }

        webView.loadFileURL(resolvedResource.htmlURL, allowingReadAccessTo: resolvedResource.directoryURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(
            state: EditorState(
                text: text,
                fontSize: fontSize,
                language: language,
                showsLineNumbers: showsLineNumbers,
                isEditable: isEditable,
                tabWidth: max(1, tabWidth ?? 4),
                verticalScrollOffset: verticalScrollOffset?.wrappedValue,
                autocompleteContext: autocompleteContext,
                selectEntireDocumentOnClick: selectEntireDocumentOnClick
            )
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
            .appendingPathComponent("Resources/CodeEditor", isDirectory: true)
        let sourceHTMLURL = sourceDirectory.appendingPathComponent("code-editor.html")
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
                    .appendingPathComponent("Contents/Resources/CodeEditor", isDirectory: true)
                    .appendingPathComponent("code-editor.html"),
                bundle.bundleURL.appendingPathComponent("Contents/Resources/CodeEditor", isDirectory: true)
            ),
            (
                bundle.bundleURL
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                    .appendingPathComponent("CodeEditor/code-editor.html"),
                bundle.bundleURL.appendingPathComponent("Contents/Resources/CodeEditor", isDirectory: true)
            ),
            (
                bundle.bundleURL
                    .appendingPathComponent("code-editor.html"),
                bundle.bundleURL
            ),
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.htmlURL.path) {
            return candidate
        }

        if let htmlURL = bundle.url(forResource: "code-editor", withExtension: "html", subdirectory: "CodeEditor") {
            return (htmlURL, htmlURL.deletingLastPathComponent())
        }

        if let htmlURL = bundle.url(forResource: "code-editor", withExtension: "html"),
           let resourceURL = bundle.resourceURL {
            return (htmlURL, resourceURL)
        }

        return nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "codeEditor"

        @Binding private var text: String
        private var verticalScrollOffset: Binding<Double>?
        private var lastKnownScrollOffset: Double
        private weak var webView: WKWebView?
        private var isReady = false
        private var pendingState: EditorState?

        init(text: Binding<String>, verticalScrollOffset: Binding<Double>?) {
            self._text = text
            self.verticalScrollOffset = verticalScrollOffset
            self.lastKnownScrollOffset = verticalScrollOffset?.wrappedValue ?? 0
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func detach(from webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
            if self.webView === webView {
                self.webView = nil
            }
            isReady = false
            pendingState = nil
        }

        fileprivate func apply(state: EditorState) {
            pendingState = state
            guard isReady, let webView else { return }

            let resolvedScrollOffset = state.verticalScrollOffset ?? lastKnownScrollOffset
            lastKnownScrollOffset = resolvedScrollOffset
            var payload = state.javaScriptPayload
            payload["scrollTop"] = resolvedScrollOffset

            webView.callAsyncJavaScript(
                "window.CodeEditorBridge.setState(state)",
                arguments: ["state": payload],
                in: nil,
                in: .page
            ) { result in
                if case .failure(let error) = result {
                    macCodeEditorLogger.error("Failed to apply editor state: \(String(describing: error), privacy: .public)")
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.messageHandlerName else { return }
            guard let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                return
            }

            switch type {
            case "ready":
                isReady = true
                if let pendingState {
                    apply(state: pendingState)
                }
            case "change":
                if let newText = payload["text"] as? String, text != newText {
                    text = newText
                }
            case "scroll":
                if let scrollTop = payload["scrollTop"] as? Double {
                    lastKnownScrollOffset = scrollTop
                    verticalScrollOffset?.wrappedValue = scrollTop
                }
            case "log":
                if let value = payload["message"] as? String {
                    macCodeEditorLogger.debug("Editor web log: \(value, privacy: .public)")
                }
            default:
                break
            }
        }
    }

    fileprivate struct EditorState {
        let text: String
        let fontSize: CGFloat
        let language: CodeEditorLanguage
        let showsLineNumbers: Bool
        let isEditable: Bool
        let tabWidth: Int
        let verticalScrollOffset: Double?
        let autocompleteContext: CodeEditorAutocompleteContext
        let selectEntireDocumentOnClick: Bool

        var javaScriptPayload: [String: Any] {
            var payload: [String: Any] = [
                "text": text,
                "fontSize": Double(fontSize),
                "language": language.debugName,
                "showsLineNumbers": showsLineNumbers,
                "isEditable": isEditable,
                "tabWidth": tabWidth,
                "autocomplete": autocompleteContext.javaScriptPayload,
                "selectEntireDocumentOnClick": selectEntireDocumentOnClick,
            ]
            if let verticalScrollOffset {
                payload["scrollTop"] = verticalScrollOffset
            }
            return payload
        }
    }
}

private extension CodeEditorLanguage {
    var debugName: String {
        switch self {
        case .plainText:
            return "plainText"
        case .json:
            return "json"
        case .xml:
            return "xml"
        case .html:
            return "html"
        case .javascript:
            return "javascript"
        case .markdown:
            return "markdown"
        }
    }
}
