import EfbyDomain
import EfbyInfrastructure
import Foundation
import OSLog

private let bitbucketPadFlowLog = Logger(subsystem: "EFBY.AppCore", category: "BitbucketPadFlow")

/// Orquesta descarga/resync de repos Bitbucket para el flujo iPad (mirror de solo lectura).
@MainActor
public final class BitbucketPadCoordinator {
    public struct PlanningError: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }

        public init(_ message: String) {
            self.message = message
        }
    }

    public struct ImportPlan: Equatable {
        public var cloneHTTPSURL: String
        public var branch: String
        public var username: String
        public var appPassword: String
        public var isResync: Bool

        public init(
            cloneHTTPSURL: String,
            branch: String,
            username: String,
            appPassword: String,
            isResync: Bool
        ) {
            self.cloneHTTPSURL = cloneHTTPSURL
            self.branch = branch
            self.username = username
            self.appPassword = appPassword
            self.isResync = isResync
        }
    }

    public struct ImportResult: Equatable {
        public var repositoryRoot: URL
        public var cloneHTTPSURL: String
        public var branch: String?
        public var username: String?
        public var tokenToPersist: String

        public init(
            repositoryRoot: URL,
            cloneHTTPSURL: String,
            branch: String?,
            username: String?,
            tokenToPersist: String
        ) {
            self.repositoryRoot = repositoryRoot
            self.cloneHTTPSURL = cloneHTTPSURL
            self.branch = branch
            self.username = username
            self.tokenToPersist = tokenToPersist
        }
    }

    public init() {}

    public func planInitialDownload(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String
    ) -> Result<ImportPlan, PlanningError> {
        let trimmedURL = cloneHTTPSURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return .failure(PlanningError("Introduce la URL HTTPS del repositorio en Bitbucket."))
        }
        return .success(
            ImportPlan(
                cloneHTTPSURL: trimmedURL,
                branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
                username: bitbucketUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                appPassword: bitbucketAppPassword.trimmingCharacters(in: .whitespacesAndNewlines),
                isResync: false
            )
        )
    }

    public func planResync(
        cloneHTTPSURL: String,
        branch: String,
        bitbucketUsername: String,
        bitbucketAppPassword: String,
        hasSharedRepository: Bool,
        savedCloneHTTPSURL: String?,
        savedBranch: String?,
        savedUsername: String?
    ) -> Result<ImportPlan, PlanningError> {
        guard hasSharedRepository else {
            return .failure(PlanningError("Primero haz al menos una descarga Bitbucket para fijar el repositorio compartido."))
        }

        let trimmedURL = cloneHTTPSURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveURL = trimmedURL.isEmpty
            ? (savedCloneHTTPSURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedURL
        guard !effectiveURL.isEmpty else {
            return .failure(PlanningError("Indica la URL del repositorio o vuelve a descargar una vez para guardarla."))
        }

        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch = trimmedBranch.isEmpty
            ? (savedBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedBranch

        let userTrim = bitbucketUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUser = userTrim.isEmpty
            ? (savedUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : userTrim

        var pass = bitbucketAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if pass.isEmpty {
            pass = BitbucketPadCredentialStore.loadAPIToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !pass.isEmpty else {
            return .failure(
                PlanningError(
                    "Introduce el API token (o app password), o guárdalo con una descarga en la que el campo no esté vacío (se almacena en el llavero del dispositivo)."
                )
            )
        }

        return .success(
            ImportPlan(
                cloneHTTPSURL: effectiveURL,
                branch: effectiveBranch,
                username: effectiveUser,
                appPassword: pass,
                isResync: true
            )
        )
    }

    public func download(
        plan: ImportPlan,
        ensureWorkdirMarker: (URL) async throws -> Void
    ) async throws -> ImportResult {
        let urlForLog =
            plan.cloneHTTPSURL.count > 120
                ? String(plan.cloneHTTPSURL.prefix(120)) + "…"
                : plan.cloneHTTPSURL
        bitbucketPadFlowLog.info(
            "Bitbucket UI flow start: resync=\(plan.isResync, privacy: .public) url=\(urlForLog, privacy: .public) branchFieldChars=\(plan.branch.count, privacy: .public) hasUsername=\(!plan.username.isEmpty, privacy: .public) appPasswordChars=\(plan.appPassword.count, privacy: .public)"
        )

        let root = try await BitbucketHTTPSArchiveImporter.downloadUnzipAndRevealRepoRoot(
            cloneHTTPSURL: plan.cloneHTTPSURL,
            branch: plan.branch,
            bitbucketUsername: plan.username,
            bitbucketAppPassword: plan.appPassword
        )
        bitbucketPadFlowLog.info("Bitbucket import returned repoRoot=\(root.path, privacy: .public); ensuring workdir marker…")
        try await ensureWorkdirMarker(root)

        bitbucketPadFlowLog.info(
            "Bitbucket UI flow finished OK (configureSharedCollectionsDirectory). resync=\(plan.isResync, privacy: .public)"
        )

        return ImportResult(
            repositoryRoot: root,
            cloneHTTPSURL: plan.cloneHTTPSURL,
            branch: plan.branch.isEmpty ? nil : plan.branch,
            username: plan.username.isEmpty ? nil : plan.username,
            tokenToPersist: plan.appPassword
        )
    }

    public func applyMetadata(from result: ImportResult, to workspace: inout WorkspaceState) {
        workspace.bitbucketPadCloneHTTPSURL = result.cloneHTTPSURL
        workspace.bitbucketPadBranch = result.branch
        workspace.bitbucketPadUsername = result.username
        try? BitbucketPadCredentialStore.saveAPITokenIfPresent(result.tokenToPersist)
    }
}
