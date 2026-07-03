import Foundation
import OSLog
import ZIPFoundation

private let bitbucketImportLog = Logger(subsystem: "EFBY.AppCore", category: "BitbucketImport")

/// Descarga el ZIP de fuente de Bitbucket Cloud (API web) y lo descomprime. En iOS no hay `git` CLI;
/// este flujo sustituye la clonación inicial para poder usar el mismo directorio compartido que en Mac.
public enum BitbucketHTTPSArchiveImporter: Sendable {

    /// Evita seguir redirecciones en la descarga ZIP: si Bitbucket devuelve 302 al IdP, al seguir el cliente suele **quitar** `Authorization` y termina en HTML 200 (login) en lugar del ZIP.
    private final class ZIPDownloadNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let zipDownloadNoRedirectDelegate = ZIPDownloadNoRedirectDelegate()

    /// Límite alto para aceptar tokens razonables (JWT, PAT, etc.); por encima casi siempre es HTML o un pegado accidental (miles de caracteres → HTTP 400).
    private static let maxBitbucketPasswordOrTokenLength = 8192
    private static let maxBitbucketUsernameLength = 254

    /// Quita BOM y espacios de ancho cero que a veces se cuelan al pegar usuario o token desde correo / web.
    private static func sanitizedBitbucketCredential(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.filter { s in
            switch s.value {
            case 0xFEFF, 0x00A0, 0x200B, 0x200C, 0x200D, 0x2060, 0x2028, 0x2029: false
            default: true
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Usuario estático documentado por Atlassian para HTTPS con API token (mismo patrón que `git clone`).
    private static let bitbucketStaticAPITokenZIPUsername = "x-bitbucket-api-token-auth"

    private enum ZIPAuthAttempt: Sendable {
        case basic(user: String, pass: String)
        case bearer(token: String)
    }

    /// JWT compacto típico de API tokens Atlassian/Bitbucket (`eyJ` + tres segmentos): conviene probar **Bearer** antes en ZIP/REST.
    private static func looksLikeCompactJSONWebToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return token.hasPrefix("eyJ")
    }

    /// Basic (usuario + token / app password) y **Bearer** cuando aplica (tokens de repo/workspace o JWT de API).
    private static func zipAuthAttempts(user: String, pass: String) -> [ZIPAuthAttempt] {
        if user.isEmpty && pass.isEmpty { return [.basic(user: "", pass: "")] }
        if pass.isEmpty { return [.basic(user: user, pass: "")] }
        let jwtish = looksLikeCompactJSONWebToken(pass)
        if user.isEmpty {
            if jwtish {
                return [.bearer(token: pass), .basic(user: bitbucketStaticAPITokenZIPUsername, pass: pass)]
            }
            return [
                .basic(user: bitbucketStaticAPITokenZIPUsername, pass: pass),
                .bearer(token: pass),
            ]
        }
        if user.caseInsensitiveCompare(bitbucketStaticAPITokenZIPUsername) == .orderedSame {
            if jwtish {
                return [.bearer(token: pass), .basic(user: user, pass: pass)]
            }
            return [.basic(user: user, pass: pass), .bearer(token: pass)]
        }
        if jwtish {
            return [
                .bearer(token: pass),
                .basic(user: user, pass: pass),
                .basic(user: bitbucketStaticAPITokenZIPUsername, pass: pass),
            ]
        }
        return [
            .basic(user: user, pass: pass),
            .basic(user: bitbucketStaticAPITokenZIPUsername, pass: pass),
            .bearer(token: pass),
        ]
    }

    public enum Failure: LocalizedError, Sendable {
        case invalidRepositoryURL
        case httpStatus(Int)
        case emptyArchive
        case unreasonableCredentialLengths(appPasswordCount: Int, usernameCount: Int, maxPassword: Int, maxUsername: Int)
        /// La respuesta HTTP fue 2xx pero el cuerpo no empieza por cabecera ZIP (suele ser HTML de login o JSON de error).
        case downloadedBodyNotZip(contentType: String, snippet: String)
        case unzipFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRepositoryURL:
                return "La URL no es un repositorio HTTPS de bitbucket.org (ej.: https://bitbucket.org/espacio/repo)."
            case .httpStatus(let code):
                let extra404 =
                    code == 404
                    ? " Un 404 suele indicar repo/rama inexistentes, o un repositorio privado sin credenciales correctas (Bitbucket a veces responde 404 en lugar de 403)."
                    : ""
                let extra302 =
                    [302, 303, 307].contains(code)
                    ? " Un 302 en la URL `…/get/rama.zip` suele ser redirección al login: la app no la sigue para no perder credenciales; si fallan todos los intentos, se usa el espejo por API REST."
                    : ""
                return "Bitbucket respondió con código HTTP \(code). Comprueba la URL, la rama y las credenciales (repos privados: usuario + app password o API token).\(extra404)\(extra302)"
            case .emptyArchive:
                return "El archivo descargado está vacío o no es un ZIP válido."
            case .downloadedBodyNotZip(let contentType, let snippet):
                let hint =
                    "Con **API token** de usuario suele funcionar el **correo Atlassian** como usuario (no el username corto). Con **app password** usa el **username** de Bitbucket. Los **tokens de acceso al repositorio/workspace** solo admiten **Bearer** en la API (la app ya lo prueba). Si ves HTML de `id-frontend` / login, a veces es una redirección sin credencial: la descarga ZIP ya evita seguir redirecciones para no perder `Authorization`."
                return """
                    La descarga no es un archivo ZIP (Content-Type: \(contentType)). Suele indicar página de acceso o error de Bitbucket, no el código fuente.
                    \(hint)
                    Inicio de la respuesta: \(snippet)
                    """
            case .unzipFailed(let detail):
                return "No se pudo descomprimir el ZIP: \(detail)"
            case .unreasonableCredentialLengths(let passCount, let userCount, let maxPass, let maxUser):
                return """
                    Credencial demasiado larga para este campo (usuario: \(userCount), máx. \(maxUser); contraseña/token: \(passCount), máx. \(maxPass)).
                    Bitbucket Cloud suele usar **app password** (token corto) o credenciales de longitud moderada. Pega **solo** el token (una línea), sin HTML ni páginas enteras. Miles de caracteres suelen ser un pegado por error y provocan HTTP 400.
                    """
            }
        }
    }

    /// - Parameters:
    ///   - cloneHTTPSURL: URL del repo: `https://bitbucket.org/ws/repo`, con `.git`, o URL del navegador `…/ws/repo/src/main/`.
    ///   - branch: Rama o tag. Si está **vacío**, se usa la rama de `…/src/rama/…` en la URL si existe; si no, `main`.
    ///   - bitbucketUsername: Vacío para repos públicos. Repos privados: **username** de Bitbucket (app password) o **correo Atlassian** (API token REST), o vacío si solo usas token con usuario estático interno.
    ///   - bitbucketAppPassword: App password o **API token** (no la contraseña de la cuenta).
    ///   - importsParentDirectory: Si no es `nil`, ahí se crean las carpetas de importación (p. ej. tests en `/tmp`); si es `nil`, se usa Application Support.
    public static func downloadUnzipAndRevealRepoRoot(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String,
        fileManager: FileManager = .default,
        importsParentDirectory: URL? = nil
    ) async throws -> URL {
        let user = sanitizedBitbucketCredential(bitbucketUsername)
        let pass = sanitizedBitbucketCredential(bitbucketAppPassword)
        if user.count > maxBitbucketUsernameLength || pass.count > maxBitbucketPasswordOrTokenLength {
            throw Failure.unreasonableCredentialLengths(
                appPasswordCount: pass.count,
                usernameCount: user.count,
                maxPassword: maxBitbucketPasswordOrTokenLength,
                maxUsername: maxBitbucketUsernameLength
            )
        }
        let (workspace, repo, effectiveBranch) = try parseWorkspaceRepoAndResolveBranch(
            cloneHTTPSURL: cloneHTTPSURL,
            branchField: branch
        )
        bitbucketImportLog.info("Bitbucket import: workspace=\(workspace, privacy: .public) repo=\(repo, privacy: .public) branch=\(effectiveBranch, privacy: .public)")

        let support: URL
        if let override = importsParentDirectory {
            try fileManager.createDirectory(at: override, withIntermediateDirectories: true)
            support = override
        } else {
            support = try applicationSupportImportsRoot(fileManager: fileManager)
        }
        let importDir = support.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 120
        sessionConfig.timeoutIntervalForResource = 900
        let session = URLSession(
            configuration: sessionConfig,
            delegate: zipDownloadNoRedirectDelegate,
            delegateQueue: nil
        )

        let zipURL = try makeArchiveDownloadURL(workspace: workspace, repo: repo, branch: effectiveBranch)
        bitbucketImportLog.info("ZIP URL (web): \(zipURL.absoluteString, privacy: .public)")

        do {
            let authAttempts = zipAuthAttempts(user: user, pass: pass)
            var lastZipError: Error?
            for (attemptIndex, attempt) in authAttempts.enumerated() {
                do {
                    var request = URLRequest(url: zipURL)
                    request.httpMethod = "GET"
                    request.setValue(
                        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                        forHTTPHeaderField: "User-Agent"
                    )
                    request.setValue("application/zip, application/octet-stream, */*", forHTTPHeaderField: "Accept")
                    switch attempt {
                    case .basic(let authUser, let authPass):
                        let sendsBasicAuth = !authUser.isEmpty && !authPass.isEmpty
                        bitbucketImportLog.info(
                            "ZIP GET attempt=\(attemptIndex + 1, privacy: .public)/\(authAttempts.count, privacy: .public) auth=basic sendsBasicAuth=\(sendsBasicAuth, privacy: .public) staticTokenUser=\(authUser.caseInsensitiveCompare(bitbucketStaticAPITokenZIPUsername) == .orderedSame, privacy: .public)"
                        )
                        if sendsBasicAuth {
                            let basic = Data("\(authUser):\(authPass)".utf8).base64EncodedString()
                            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
                        }
                    case .bearer(let token):
                        bitbucketImportLog.info(
                            "ZIP GET attempt=\(attemptIndex + 1, privacy: .public)/\(authAttempts.count, privacy: .public) auth=bearer tokenChars=\(token.count, privacy: .public)"
                        )
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }

                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw Failure.httpStatus(-1)
                    }
                    let mimeHead = http.value(forHTTPHeaderField: "Content-Type") ?? "(desconocido)"
                    bitbucketImportLog.info("ZIP response: status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) content-type=\(mimeHead, privacy: .public)")
                    guard (200 ... 299).contains(http.statusCode) else {
                        throw Failure.httpStatus(http.statusCode)
                    }
                    guard !data.isEmpty else {
                        throw Failure.emptyArchive
                    }
                    let mime = mimeHead
                    try validateLooksLikeZipPayload(data, contentType: mime)

                    let localZip = importDir.appendingPathComponent("source.zip", isDirectory: false)
                    let extractDir = importDir.appendingPathComponent("extract", isDirectory: true)
                    try data.write(to: localZip, options: .atomic)
                    try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
                    try fileManager.unzipItem(
                        at: localZip,
                        to: extractDir,
                        skipCRC32: true,
                        allowUncontainedSymlinks: true
                    )
                    try? fileManager.removeItem(at: localZip)
                    bitbucketImportLog.info("ZIP import OK, extract dir=\(extractDir.path, privacy: .public)")
                    return try normalizedRepoRoot(extractDirectory: extractDir, fileManager: fileManager)
                } catch {
                    lastZipError = error
                    if attemptIndex + 1 < authAttempts.count, shouldRetryZipWithNextBasicUser(error) {
                        bitbucketImportLog.notice("ZIP GET: siguiente intento con otro usuario Basic…")
                        try? fileManager.removeItem(at: importDir.appendingPathComponent("source.zip"))
                        try? fileManager.removeItem(at: importDir.appendingPathComponent("extract"))
                        continue
                    }
                    throw error
                }
            }
            throw lastZipError ?? Failure.httpStatus(-1)
        } catch {
            bitbucketImportLog.error("ZIP import failed: \(String(describing: error), privacy: .public)")
            try? fileManager.removeItem(at: importDir.appendingPathComponent("source.zip"))
            try? fileManager.removeItem(at: importDir.appendingPathComponent("extract"))

            let hasCredsForREST = !pass.isEmpty
            guard hasCredsForREST, shouldAttemptRESTAfterZipFailure(error) else {
                try? fileManager.removeItem(at: importDir)
                throw error
            }

            bitbucketImportLog.notice("Falling back to Bitbucket REST API mirror (credentials present).")
            let restRoot = importDir.appendingPathComponent("rest-mirror", isDirectory: true)
            try fileManager.createDirectory(at: restRoot, withIntermediateDirectories: true)
            do {
                try await BitbucketRESTRepositoryMirror.mirrorRepository(
                    workspace: workspace,
                    repo: repo,
                    branch: effectiveBranch,
                    bitbucketUsername: user,
                    bitbucketAppPassword: pass,
                    destinationRoot: restRoot,
                    fileManager: fileManager
                )
                bitbucketImportLog.info("REST mirror OK, root=\(restRoot.path, privacy: .public)")
                return try normalizedRepoRoot(extractDirectory: restRoot, fileManager: fileManager)
            } catch {
                bitbucketImportLog.error("REST mirror failed: \(String(describing: error), privacy: .public)")
                try? fileManager.removeItem(at: importDir)
                throw error
            }
        }
    }

    private static func shouldRetryZipWithNextBasicUser(_ error: Error) -> Bool {
        guard let failure = error as? Failure else { return false }
        switch failure {
        case .downloadedBodyNotZip: return true
        case .httpStatus(let code) where [302, 303, 307, 401, 403, 404].contains(code): return true
        case .httpStatus, .emptyArchive, .invalidRepositoryURL, .unreasonableCredentialLengths, .unzipFailed:
            return false
        }
    }

    /// Si el ZIP web falla pero hay credenciales, intentamos la API `api.bitbucket.org` (mejor con app passwords).
    private static func shouldAttemptRESTAfterZipFailure(_ error: Error) -> Bool {
        if let failure = error as? Failure {
            switch failure {
            case .downloadedBodyNotZip, .unzipFailed, .emptyArchive:
                return true
            case .httpStatus(let code) where [302, 303, 307, 401, 403, 404].contains(code):
                return true
            case .httpStatus, .invalidRepositoryURL, .unreasonableCredentialLengths:
                return false
            }
        }
        return false
    }

    // MARK: - Private

    private static func applicationSupportImportsRoot(fileManager: FileManager) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppError.persistence("No se pudo obtener Application Support.")
        }
        let root = base.appendingPathComponent("EFBYPostman/BitbucketImports", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Resuelve `workspace`, `repo` y la rama efectiva para `…/get/{rama}.zip`.
    /// Acepta URLs de clonación o rutas de código fuente del tipo `…/{ws}/{repo}/src/{ref}/…`.
    private static func parseWorkspaceRepoAndResolveBranch(
        cloneHTTPSURL: String,
        branchField: String
    ) throws -> (workspace: String, repo: String, effectiveBranch: String) {
        var trimmed = cloneHTTPSURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://"), !lower.hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "bitbucket.org" else {
            throw Failure.invalidRepositoryURL
        }

        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") {
            path = String(path.dropLast(4))
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw Failure.invalidRepositoryURL
        }
        let workspace = parts[0]
        let repo = parts[1]

        let inferredFromSrcURL: String? = {
            guard parts.count >= 4 else { return nil }
            guard parts[2].lowercased() == "src" else { return nil }
            let ref = parts[3]
            return ref.isEmpty ? nil : ref
        }()

        let trimmedField = branchField.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String
        if !trimmedField.isEmpty {
            effectiveBranch = trimmedField
        } else if let inferredFromSrcURL, !inferredFromSrcURL.isEmpty {
            effectiveBranch = inferredFromSrcURL
        } else {
            effectiveBranch = "main"
        }
        return (workspace, repo, effectiveBranch)
    }

    private static func makeArchiveDownloadURL(workspace: String, repo: String, branch: String) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        func encodeSegment(_ segment: String) -> String {
            segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
        }
        let encodedWorkspace = encodeSegment(workspace)
        let encodedRepo = encodeSegment(repo)
        let encodedBranch =
            branch
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "%2F")
        let path = "/\(encodedWorkspace)/\(encodedRepo)/get/\(encodedBranch).zip"
        guard let url = URL(string: "https://bitbucket.org\(path)") else {
            throw Failure.invalidRepositoryURL
        }
        return url
    }

    /// Comprueba cabecera ZIP local u otros formatos ZIP reconocidos (evita pasar HTML/JSON a ZIPFoundation).
    private static func validateLooksLikeZipPayload(_ data: Data, contentType: String) throws {
        guard data.count >= 4 else {
            throw Failure.emptyArchive
        }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]
        let isZip =
            b0 == 0x50 && b1 == 0x4B &&
            ((b2 == 0x03 && b3 == 0x04) || (b2 == 0x05 && b3 == 0x06) || (b2 == 0x07 && b3 == 0x08))
        if isZip {
            return
        }
        let snippetData = data.prefix(400)
        let snippet =
            String(data: snippetData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            ?? "(contenido no UTF-8, \(snippetData.count) bytes)"
        bitbucketImportLog.warning(
            "ZIP body no es PK: contentType=\(contentType, privacy: .public) totalBytes=\(data.count, privacy: .public) snippetChars=\(snippet.count, privacy: .public) head=\(String(snippet.prefix(120)), privacy: .public)"
        )
        throw Failure.downloadedBodyNotZip(contentType: contentType, snippet: String(snippet.prefix(280)))
    }

    private static func normalizedRepoRoot(extractDirectory: URL, fileManager: FileManager) throws -> URL {
        let items = try fileManager.contentsOfDirectory(
            at: extractDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var directories: [URL] = []
        var files: [URL] = []
        for item in items {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                directories.append(item)
            } else {
                files.append(item)
            }
        }
        if directories.count == 1, files.isEmpty {
            return directories[0]
        }
        if items.isEmpty {
            throw Failure.emptyArchive
        }
        return extractDirectory
    }

    // MARK: - Introspección (pruebas / depuración, sin red)

    /// Resuelve workspace, slug del repo y rama efectiva a partir de la URL de clon o de navegador (`…/src/rama/`).
    public static func resolveWorkspaceRepoBranch(
        cloneHTTPSURL: String,
        branchField: String
    ) throws -> (workspace: String, repo: String, effectiveBranch: String) {
        try parseWorkspaceRepoAndResolveBranch(cloneHTTPSURL: cloneHTTPSURL, branchField: branchField)
    }

    /// URL HTTPS del ZIP de fuentes que Bitbucket genera para la rama indicada (no realiza descarga).
    public static func resolvedSourceArchiveZIPURL(
        cloneHTTPSURL: String,
        branchField: String
    ) throws -> URL {
        let (workspace, repo, effectiveBranch) = try parseWorkspaceRepoAndResolveBranch(
            cloneHTTPSURL: cloneHTTPSURL,
            branchField: branchField
        )
        return try makeArchiveDownloadURL(workspace: workspace, repo: repo, branch: effectiveBranch)
    }
}
