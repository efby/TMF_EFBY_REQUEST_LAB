import Foundation
import OSLog

private let bitbucketRESTLog = Logger(subsystem: "EFBY.AppCore", category: "BitbucketREST")

/// Descarga el árbol de archivos de un repositorio Bitbucket Cloud usando la API 2.0 (`api.bitbucket.org`).
/// Autenticación: **Basic** (app password con username Bitbucket; API token de usuario con **correo Atlassian** + token; o usuario estático `x-bitbucket-api-token-auth` + token).
/// Tras los intentos Basic se prueba **Bearer** (tokens de acceso a **repositorio / proyecto / workspace** de Bitbucket Cloud, que no usan Basic).
enum BitbucketRESTRepositoryMirror: Sendable {

    private static let bitbucketStaticAPITokenBasicUsername = "x-bitbucket-api-token-auth"

    private enum RESTAuthMode: Sendable {
        case basic(username: String, password: String)
        case bearer(token: String)
    }

    /// JWT compacto típico de API tokens Atlassian/Bitbucket: en REST suele responder mejor **Bearer** primero que Basic con el mismo string.
    private static func looksLikeCompactJSONWebToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return token.hasPrefix("eyJ")
    }

    private static func tokenNotSupportedEndpointHint(from bodySnippet: String?) -> String {
        guard let s = bodySnippet?.lowercased() else { return "" }
        guard s.contains("not supported for this endpoint") || s.contains("token is invalid") else {
            return ""
        }
        return """

            Si en el detalle aparece «Token is invalid… not supported for this endpoint»: Bitbucket **no reconoce** este token para `api.bitbucket.org` (no es un fallo de URL ni de orden Basic/Bearer en la app). Suele ser: token creado **sin** permisos de Bitbucket, token **revocado/expirado**, pegado **incompleto**, o **app password** usada con **correo** como usuario. Solución típica: en bitbucket.org → Personal settings → **API tokens** → crear token con **`read:repository:bitbucket`** y usar **correo** + ese token; o **app password** + **username** de Bitbucket.
            """
    }

    enum Failure: LocalizedError, Sendable {
        case invalidAPIURL
        case httpStatus(Int, String?)
        case unexpectedJSON
        case emptyRepository
        case fileLimitExceeded(Int)

        var errorDescription: String? {
            switch self {
            case .invalidAPIURL:
                return "No se pudo construir la URL de la API de Bitbucket."
            case .httpStatus(let code, let bodySnippet):
                let tail = bodySnippet.map { " Detalle: \($0)" } ?? ""
                if code == 401 {
                    let notSupportedHint = tokenNotSupportedEndpointHint(from: bodySnippet)
                    return """
                        Bitbucket rechazó las credenciales (HTTP 401). Revisa lo siguiente:
                        • **API token** (Bitbucket Cloud): créalo en **bitbucket.org** → Personal settings → **API tokens** (no basta con un token «solo Atlassian» sin permisos de Bitbucket). En «Usuario» va el **correo** de Personal settings → **Email**. El token debe incluir al menos **`read:repository:bitbucket`** (lectura de repositorios y código).
                        • **App password** (si aún lo usas): usuario = **username** de Bitbucket (Account settings → Username) + app password con **Repositories: Read** y acceso al repo o a todos.
                        • **Token de acceso al repositorio / workspace** (Repository or workspace access token): va en «Contraseña / token»; el usuario puede quedar vacío. La app prueba `Authorization: Bearer` y Basic según el tipo de token.
                        • Si ya probamos varios modos y sigue 401, casi siempre es token incorrecto, revocado o sin alcance al workspace/repo.
                        • SSO sin app passwords / sin tokens: hace falta que un admin lo permita u otro método de acceso.\(notSupportedHint)
                        \(tail)
                        """
                }
                return "La API de Bitbucket respondió HTTP \(code). Comprueba usuario, app password (permiso lectura del repo) y nombre de rama.\(tail)"
            case .unexpectedJSON:
                return "Respuesta inesperada de la API de Bitbucket (JSON)."
            case .emptyRepository:
                return "La API no devolvió archivos en esa rama (¿rama vacía o sin permisos?)."
            case .fileLimitExceeded(let limit):
                return "Se superó el límite de \(limit) archivos descargados por seguridad."
            }
        }
    }

    private static let maxFiles = 25_000
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()

    /// Copia el contenido del repo remoto bajo `destinationRoot` (equivalente a descomprimir el ZIP en la raíz del repo).
    static func mirrorRepository(
        workspace: String,
        repo: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String,
        destinationRoot: URL,
        fileManager: FileManager
    ) async throws {
        let pass = bitbucketAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pass.isEmpty else {
            throw Failure.httpStatus(401, "Falta el token o app password para la API de Bitbucket.")
        }
        let attempts = restAuthModes(username: bitbucketUsername, password: pass)
        guard !attempts.isEmpty else {
            throw Failure.httpStatus(401, "Falta el usuario o el token para la API de Bitbucket.")
        }
        guard let rootListingURL = makeRootListingURL(workspace: workspace, repo: repo, branch: branch) else {
            throw Failure.invalidAPIURL
        }
        bitbucketRESTLog.info("REST mirror start: \(rootListingURL.absoluteString, privacy: .public)")

        var lastFailure: Failure?
        for (index, authMode) in attempts.enumerated() {
            try clearDestinationRoot(destinationRoot, fileManager: fileManager)
            var filesWritten = 0
            do {
                try await walkDirectoryListing(
                    listingURL: rootListingURL,
                    authMode: authMode,
                    destinationRoot: destinationRoot,
                    fileManager: fileManager,
                    filesWritten: &filesWritten
                )
                let top = try fileManager.contentsOfDirectory(atPath: destinationRoot.path)
                guard !top.isEmpty else {
                    throw Failure.emptyRepository
                }
                bitbucketRESTLog.info(
                    "REST mirror done: filesWritten=\(filesWritten, privacy: .public) topLevelEntries=\(top.count, privacy: .public) authAttemptIndex=\(index, privacy: .public)"
                )
                return
            } catch let failure as Failure {
                if case .httpStatus(let code, _) = failure, code == 401, index + 1 < attempts.count {
                    bitbucketRESTLog.notice("REST 401 en intento \(index + 1)/\(attempts.count); probando otro modo de autenticación…")
                    lastFailure = failure
                    continue
                }
                throw failure
            } catch {
                throw error
            }
        }
        throw lastFailure ?? Failure.httpStatus(401, nil)
    }

    private static func restAuthModes(username: String, password: String) -> [RESTAuthMode] {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = password
        let jwtish = looksLikeCompactJSONWebToken(p)
        var modes: [RESTAuthMode] = []

        if jwtish {
            modes.append(.bearer(token: p))
        }

        if u.isEmpty {
            modes.append(.basic(username: bitbucketStaticAPITokenBasicUsername, password: p))
        } else if u.caseInsensitiveCompare(bitbucketStaticAPITokenBasicUsername) == .orderedSame {
            modes.append(.basic(username: u, password: p))
        } else {
            modes.append(.basic(username: u, password: p))
            modes.append(.basic(username: bitbucketStaticAPITokenBasicUsername, password: p))
        }

        if !jwtish {
            modes.append(.bearer(token: p))
        }
        return modes
    }

    private static func clearDestinationRoot(_ destinationRoot: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: destinationRoot.path) else {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            return
        }
        for entry in try fileManager.contentsOfDirectory(at: destinationRoot, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: entry)
        }
    }

    // MARK: - Private

    private static func makeRootListingURL(workspace: String, repo: String, branch: String) -> URL? {
        let w = encodePathSegment(workspace)
        let r = encodePathSegment(repo)
        let b = encodeBranchForPath(branch)
        let s = "https://api.bitbucket.org/2.0/repositories/\(w)/\(r)/src/\(b)/"
        return URL(string: s)
    }

    private static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    private static func encodeBranchForPath(_ branch: String) -> String {
        branch
            .split(separator: "/")
            .map { encodePathSegment(String($0)) }
            .joined(separator: "%2F")
    }

    private static func authorizedRequest(url: URL, acceptJSON: Bool, authMode: RESTAuthMode) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(acceptJSON ? "application/json" : "*/*", forHTTPHeaderField: "Accept")
        request.setValue("EFBYRequestLab/1.0 (Bitbucket REST mirror)", forHTTPHeaderField: "User-Agent")
        switch authMode {
        case .basic(let username, let password):
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func walkDirectoryListing(
        listingURL: URL,
        authMode: RESTAuthMode,
        destinationRoot: URL,
        fileManager: FileManager,
        filesWritten: inout Int
    ) async throws {
        let entries = try await fetchAllListingValues(
            firstPageURL: listingURL,
            authMode: authMode
        )

        for entry in entries {
            guard let type = entry["type"] as? String else { continue }
            guard let path = entry["path"] as? String, !path.isEmpty else { continue }
            guard let selfURL = selfHref(from: entry) else { continue }

            switch type {
            case "commit_directory":
                try await walkDirectoryListing(
                    listingURL: selfURL,
                    authMode: authMode,
                    destinationRoot: destinationRoot,
                    fileManager: fileManager,
                    filesWritten: &filesWritten
                )
            case "commit_file":
                let attrs = attributeStrings(from: entry["attributes"])
                if attrs.contains("subrepository") { continue }
                if attrs.contains("link") { continue }

                filesWritten += 1
                guard filesWritten <= maxFiles else {
                    throw Failure.fileLimitExceeded(maxFiles)
                }
                let progressCount = filesWritten
                if progressCount == 1 || progressCount % 100 == 0 {
                    bitbucketRESTLog.info("REST mirror progress: filesWritten=\(progressCount, privacy: .public) lastPath=\(path, privacy: .public)")
                }

                let destURL = fileURL(repoRelativePath: path, under: destinationRoot)
                try fileManager.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let fileData = try await fetchData(
                    url: selfURL,
                    authMode: authMode,
                    acceptJSON: false
                )
                try fileData.write(to: destURL, options: .atomic)
            default:
                break
            }
        }
    }

    private static func attributeStrings(from value: Any?) -> [String] {
        if let a = value as? [String] {
            return a
        }
        if let a = value as? [Any] {
            return a.compactMap { $0 as? String }
        }
        return []
    }

    private static func fileURL(repoRelativePath: String, under root: URL) -> URL {
        repoRelativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private static func selfHref(from entry: [String: Any]) -> URL? {
        guard let links = entry["links"] as? [String: Any],
              let selfBlock = links["self"] as? [String: Any],
              let href = selfBlock["href"] as? String else {
            return nil
        }
        return URL(string: href)
    }

    private static func fetchAllListingValues(
        firstPageURL: URL,
        authMode: RESTAuthMode
    ) async throws -> [[String: Any]] {
        var combined: [[String: Any]] = []
        var pageURL: URL? = firstPageURL
        while let url = pageURL {
            let data = try await fetchData(
                url: url,
                authMode: authMode,
                acceptJSON: true
            )
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unexpectedJSON
            }
            if let values = obj["values"] as? [[String: Any]] {
                combined.append(contentsOf: values)
            } else {
                throw Failure.unexpectedJSON
            }
            if let next = obj["next"] as? String {
                pageURL = URL(string: next)
            } else {
                pageURL = nil
            }
        }
        return combined
    }

    private static func fetchData(
        url: URL,
        authMode: RESTAuthMode,
        acceptJSON: Bool
    ) async throws -> Data {
        let request = authorizedRequest(url: url, acceptJSON: acceptJSON, authMode: authMode)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.httpStatus(-1, nil)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            var bits: [String] = []
            if let www = http.value(forHTTPHeaderField: "WWW-Authenticate"), !www.isEmpty {
                bits.append("WWW-Authenticate: \(www)")
            }
            if let body = String(data: data.prefix(500), encoding: .utf8) {
                let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { bits.append(t) }
            }
            let detail = bits.isEmpty ? nil : bits.joined(separator: " | ")
            bitbucketRESTLog.error("REST HTTP \(http.statusCode, privacy: .public) url=\(url.absoluteString, privacy: .public)")
            throw Failure.httpStatus(http.statusCode, detail)
        }
        return data
    }
}
