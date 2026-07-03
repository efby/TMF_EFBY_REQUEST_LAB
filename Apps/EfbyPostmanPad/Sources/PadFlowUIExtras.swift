import EfbyPresentation
import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Portapapeles (iPad)

enum PadPasteboard {
    /// Copia texto plano al portapapeles del sistema (iOS).
    static func copy(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
    }
}

// MARK: - Log en vivo (incluye QR / PNG inline como en Mac)

struct PadFlowRunLogLinesView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !lines.isEmpty {
                Button {
                    PadPasteboard.copy(lines.joined(separator: "\n"))
                } label: {
                    Label("Copiar log", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .accessibilityHint("Copia todas las líneas del log al portapapeles")
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    PadFlowRunLogLineView(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PadFlowRunLogLineView: View {
    let line: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let inline = WorkspaceFlowInlineImageLogLine.parse(line) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(inline.caption)
                            .font(.subheadline.weight(.semibold))
                        inlineImage(url: inline.fileURL)
                        Text(inline.fileURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

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

    @ViewBuilder
    private func inlineImage(url: URL) -> some View {
#if canImport(UIKit)
        if let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 280)
                .padding(6)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text("No se pudo cargar el PNG (ruta o archivo temporal).")
                .font(.caption)
                .foregroundStyle(.orange)
        }
#else
        EmptyView()
#endif
    }
}

// MARK: - BPMN real (mismo motor que Mac, solo lectura)

struct PadBPMNReadOnlyWebView: UIViewRepresentable {
    var bpmnXML: String
    var diagramViewport: WorkspaceFlowDiagramViewport?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        context.coordinator.webView = wv
        wv.navigationDelegate = context.coordinator

        guard let htmlURL = Bundle.main.url(forResource: "bpmn-editor", withExtension: "html", subdirectory: "BPMN") else {
            return wv
        }
        let dir = htmlURL.deletingLastPathComponent()
        wv.loadFileURL(htmlURL, allowingReadAccessTo: dir)
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.scheduleImport(xml: bpmnXML, viewport: diagramViewport)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var bridgeReady = false
        private var pendingXML: String = ""
        private var pendingViewport: WorkspaceFlowDiagramViewport?

        func scheduleImport(xml: String, viewport: WorkspaceFlowDiagramViewport?) {
            pendingXML = xml
            pendingViewport = viewport
            if bridgeReady {
                flushImport()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let hideChrome = """
            (function(){
              var s=document.createElement('style');
              s.textContent = '#flow-palette-anchor{display:none!important;height:0!important;min-height:0!important;} .djs-palette{display:none!important;}';
              document.head.appendChild(s);
            })();
            """
            webView.evaluateJavaScript(hideChrome, completionHandler: nil)
            bridgeReady = true
            flushImport()
        }

        private func flushImport() {
            guard let webView else { return }
            let xml = pendingXML
            let vp = pendingViewport
            guard !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            struct Payload: Encodable {
                var xml: String
                var viewport: WorkspaceFlowDiagramViewport?
            }
            do {
                let data = try JSONEncoder().encode(Payload(xml: xml, viewport: vp))
                let b64 = data.base64EncodedString()
                let js = """
                (function(){
                  function u8FromB64(b64) {
                    var bin = atob(b64);
                    var len = bin.length;
                    var u8 = new Uint8Array(len);
                    for (var i = 0; i < len; i++) { u8[i] = bin.charCodeAt(i) & 0xff; }
                    return u8;
                  }
                  try {
                    var json = new TextDecoder('utf-8').decode(u8FromB64('\(b64)'));
                    var p = JSON.parse(json);
                    if (window.FlowEditorBridge && window.FlowEditorBridge.importXML) {
                      return FlowEditorBridge.importXML(p.xml, p.viewport || null);
                    }
                  } catch (e) { console.error('Pad BPMN import', e); }
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            } catch {
                // ignore
            }
        }
    }
}

// MARK: - Teclado (barra «Ocultar»)

/// Botón compacto en la barra superior del teclado del sistema (toda la app iOS).
enum PadKeyboardDismiss {
    /// Texto corto en la barra del teclado.
    static let toolbarTitle = "Ocultar"
    static let accessibilityLabel = "Ocultar teclado"

    @MainActor
    static func resignFirstResponder() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Fuente pequeña para `UIBarButtonItem` del `inputAccessoryView` (credenciales AWS, etc.).
    static var accessoryBarButtonFont: UIFont {
        UIFont.preferredFont(forTextStyle: .caption2)
    }
}

extension View {
    /// Añade el botón «Ocultar» en la barra del teclado (coloca el modificador en un antecesor común de los campos de texto).
    func padKeyboardDismissToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button(PadKeyboardDismiss.toolbarTitle) {
                    PadKeyboardDismiss.resignFirstResponder()
                }
                .font(.caption2.weight(.semibold))
                .accessibilityLabel(PadKeyboardDismiss.accessibilityLabel)
            }
        }
    }
}
