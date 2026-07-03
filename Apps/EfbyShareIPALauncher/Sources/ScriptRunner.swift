import Foundation

enum ScriptRunner {
    /// Ejecuta `scripts/export-ios-shareable-ipa.sh` en `repoRoot` con argumentos extra (p. ej. `--development`, `--clean`).
    static func runShareableScript(repoRoot: URL, arguments: [String]) async throws -> String {
        let script = repoRoot.appendingPathComponent("scripts/export-ios-shareable-ipa.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(
                domain: "EfbyShareIPALauncher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No se encontró o no es ejecutable: \(script.path)"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = repoRoot

        let pipeOut = Pipe()
        let pipeErr = Pipe()
        process.standardOutput = pipeOut
        process.standardError = pipeErr

        try process.run()
        process.waitUntilExit()

        let outData = pipeOut.fileHandleForReading.readDataToEndOfFile()
        let errData = pipeErr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        var combined = ""
        if !out.isEmpty { combined += out }
        if !err.isEmpty {
            if !combined.isEmpty { combined += "\n--- stderr ---\n" }
            combined += err
        }
        if combined.isEmpty { combined = "(sin salida)" }

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "EfbyShareIPALauncher",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: combined]
            )
        }
        return combined
    }
}
