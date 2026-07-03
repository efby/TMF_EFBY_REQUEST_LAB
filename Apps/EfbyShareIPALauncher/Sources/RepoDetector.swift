import Foundation

enum RepoDetector {
    private static let scriptRelative = "scripts/export-ios-shareable-ipa.sh"
    private static let userDefaultsKey = "efbyPostmanRepoPath"

    static func markerExists(at repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(scriptRelative).path)
    }

    /// Sube directorios desde `start` buscando `scripts/export-ios-shareable-ipa.sh`.
    static func findRepo(ascendingFrom start: URL) -> URL? {
        var url = start.standardizedFileURL
        for _ in 0 ..< 20 {
            if markerExists(at: url) { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    static func savedRepoURL() -> URL? {
        guard let s = UserDefaults.standard.string(forKey: userDefaultsKey), !s.isEmpty else { return nil }
        let u = URL(fileURLWithPath: s, isDirectory: true)
        return markerExists(at: u) ? u : nil
    }

    static func saveRepoURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: userDefaultsKey)
    }

    /// Punto de partida típico: bundle de la app (útil si copias el .app dentro del repo).
    static func defaultRepoURL() -> URL? {
        if let saved = savedRepoURL() { return saved }
        let bundle = Bundle.main.bundleURL
        // .../Nombre.app/Contents/MacOS → subir hasta .app y seguir
        if let fromBundle = findRepo(ascendingFrom: bundle) { return fromBundle }
        // Desarrollo: a veces el ejecutable está en DerivedData; prueba el directorio del proyecto si está embebido
        if let resource = Bundle.main.resourceURL,
            let fromRes = findRepo(ascendingFrom: resource)
        {
            return fromRes
        }
        return nil
    }
}
