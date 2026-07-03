import Foundation

/// Opción 1: imagen en archivo temporal + una línea de log reconocible por la UI del flujo / consola.
public enum WorkspaceFlowInlineImageLogLine: Sendable {
    public static let markerPrefix = "__EFBY_INLINE_IMAGE__"

    public struct Payload: Equatable, Sendable {
        public var fileURL: URL
        public var caption: String

        public init(fileURL: URL, caption: String) {
            self.fileURL = fileURL
            self.caption = caption
        }
    }

    /// Línea única: marcador, URL absoluta (`file://`), leyenda (sin tabuladores ni saltos).
    public static func encode(fileURL: URL, caption: String) -> String {
        let safeCaption = caption
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(markerPrefix)\t\(fileURL.absoluteString)\t\(safeCaption)"
    }

    public static func parse(_ rawLine: String) -> Payload? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(markerPrefix) else { return nil }
        let withoutMarker = trimmed.dropFirst(markerPrefix.count)
        guard withoutMarker.first == "\t" else { return nil }
        let rest = String(withoutMarker.dropFirst())
        let parts = rest.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let urlString = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = parts.dropFirst().joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), url.isFileURL else { return nil }
        return Payload(fileURL: url, caption: caption.isEmpty ? "Imagen" : caption)
    }
}
