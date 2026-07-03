import AppKit
import SwiftUI

struct ContentView: View {
    @State private var repoPath: String = RepoDetector.defaultRepoURL()?.path ?? ""
    @State private var logText: String = "Elige la raíz del repo **EFBY_POSTMAN** (carpeta que contiene `scripts/`) y pulsa un botón.\n\nGenera `Distribution/EfbyPostmanPad.ipa` para compartir (ad-hoc o development según el botón)."
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exportar IPA compartible")
                .font(.title2.weight(.semibold))

            HStack(alignment: .center, spacing: 8) {
                TextField("Ruta al repo EFBY_POSTMAN", text: $repoPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(isRunning)

                Button("Examinar…") { pickRepoFolder() }
                    .disabled(isRunning)
            }

            HStack(spacing: 12) {
                Button {
                    run(arguments: [])
                } label: {
                    Label("IPA ad-hoc (UDIDs)", systemImage: "iphone.and.arrow.forward.outward")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || repoPath.isEmpty)

                Button {
                    run(arguments: ["--development"])
                } label: {
                    Label("IPA development", systemImage: "hammer")
                }
                .disabled(isRunning || repoPath.isEmpty)

                Button {
                    run(arguments: ["--clean"])
                } label: {
                    Label("Ad-hoc + clean", systemImage: "trash")
                }
                .disabled(isRunning || repoPath.isEmpty)

                if isRunning {
                    ProgressView()
                        .scaleEffect(0.9)
                }
            }

            Text("Salida del script")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Abrir Distribution") {
                    let dist = URL(fileURLWithPath: repoPath, isDirectory: true)
                        .appendingPathComponent("Distribution", isDirectory: true)
                    NSWorkspace.shared.open(dist)
                }
                .disabled(repoPath.isEmpty)

                Spacer()

                Button("Recordar esta ruta") {
                    let u = URL(fileURLWithPath: repoPath, isDirectory: true)
                    if RepoDetector.markerExists(at: u) {
                        RepoDetector.saveRepoURL(u)
                        appendLog("\n✓ Ruta guardada para la próxima vez.\n")
                    } else {
                        appendLog("\n✗ Esa carpeta no contiene scripts/export-ios-shareable-ipa.sh\n")
                    }
                }
                .disabled(repoPath.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
    }

    private func pickRepoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        panel.message = "Selecciona la carpeta raíz EFBY_POSTMAN (donde está la carpeta scripts)."
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }

    private func appendLog(_ s: String) {
        logText += s
    }

    private func run(arguments: [String]) {
        let root = URL(fileURLWithPath: repoPath, isDirectory: true)
        guard RepoDetector.markerExists(at: root) else {
            appendLog("\n✗ No existe scripts/export-ios-shareable-ipa.sh en:\n  \(repoPath)\n")
            return
        }

        isRunning = true
        appendLog("\n\n—— \(Date()) ——\n$ scripts/export-ios-shareable-ipa.sh \(arguments.joined(separator: " "))\n")

        Task {
            do {
                let out = try await ScriptRunner.runShareableScript(repoRoot: root, arguments: arguments)
                await MainActor.run {
                    appendLog(out)
                    if !out.hasSuffix("\n") { appendLog("\n") }
                    appendLog("—— fin (éxito) ——\n")
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    appendLog("\n\(error.localizedDescription)\n")
                    appendLog("—— fin (error) ——\n")
                    isRunning = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
