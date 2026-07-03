import EfbyPresentation
import XCTest

/*
 Prueba en vivo contra Bitbucket (ZIP generado por el servidor):

 No guardes app passwords en el repositorio. Para ejecutar la prueba con red
 una sola vez (p. ej. antes de revocar el token):

   export EFBY_BITBUCKET_TEST_USER='efby'
   export EFBY_BITBUCKET_TEST_APP_PASSWORD='<app_password>'
   swift test --filter BitbucketHTTPSArchiveImporterTests/testLiveDownload_postmanefbyPrivateRepo_whenEnvCredentialsSet

 Sin variables: la prueba en vivo se omite (`XCTSkip`). Las demás pruebas no usan red ni secretos.
 */
final class BitbucketHTTPSArchiveImporterTests: XCTestCase {

    /// Misma URL de navegador que el flujo real del iPad (workspace/repo inferidos, rama desde `/src/main/`).
    private let postmanEfbyBrowserURL = "https://bitbucket.org/teamefby/postmanefby/src/main/"

    func testResolveWorkspaceRepoBranch_fromSrcURL_emptyBranchField_usesMainFromPath() throws {
        let r = try BitbucketHTTPSArchiveImporter.resolveWorkspaceRepoBranch(
            cloneHTTPSURL: postmanEfbyBrowserURL,
            branchField: ""
        )
        XCTAssertEqual(r.workspace, "teamefby")
        XCTAssertEqual(r.repo, "postmanefby")
        XCTAssertEqual(r.effectiveBranch, "main")
    }

    func testResolveWorkspaceRepoBranch_cloneURL_overridesBranchField() throws {
        let r = try BitbucketHTTPSArchiveImporter.resolveWorkspaceRepoBranch(
            cloneHTTPSURL: "https://bitbucket.org/teamefby/postmanefby.git",
            branchField: "develop"
        )
        XCTAssertEqual(r.workspace, "teamefby")
        XCTAssertEqual(r.repo, "postmanefby")
        XCTAssertEqual(r.effectiveBranch, "develop")
    }

    func testDownload_rejectsAbsurdlyLongAppPassword_beforeNetwork() async throws {
        let longPass = String(repeating: "x", count: 9000)
        do {
            _ = try await BitbucketHTTPSArchiveImporter.downloadUnzipAndRevealRepoRoot(
                cloneHTTPSURL: postmanEfbyBrowserURL,
                branch: "",
                bitbucketUsername: "user",
                bitbucketAppPassword: longPass,
                importsParentDirectory: FileManager.default.temporaryDirectory
            )
            XCTFail("Se esperaba error por longitud de app password.")
        } catch let failure as BitbucketHTTPSArchiveImporter.Failure {
            if case .unreasonableCredentialLengths = failure {
                // ok
            } else {
                XCTFail("Tipo de error inesperado: \(failure)")
            }
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testResolvedSourceArchiveZIPURL_matchesBitbucketGetPath() throws {
        let zipURL = try BitbucketHTTPSArchiveImporter.resolvedSourceArchiveZIPURL(
            cloneHTTPSURL: postmanEfbyBrowserURL,
            branchField: ""
        )
        XCTAssertEqual(zipURL.host, "bitbucket.org")
        XCTAssertTrue(zipURL.path.hasSuffix("/get/main.zip"), "path was: \(zipURL.path)")
        XCTAssertTrue(zipURL.path.contains("/teamefby/postmanefby/"), "path was: \(zipURL.path)")
    }

    func testLiveDownload_postmanefbyPrivateRepo_whenEnvCredentialsSet() async throws {
        let user = ProcessInfo.processInfo.environment["EFBY_BITBUCKET_TEST_USER"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pass = ProcessInfo.processInfo.environment["EFBY_BITBUCKET_TEST_APP_PASSWORD"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("Define EFBY_BITBUCKET_TEST_USER y EFBY_BITBUCKET_TEST_APP_PASSWORD para esta prueba en vivo.")
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EFBYPostmanTests-Bitbucket-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoRoot = try await BitbucketHTTPSArchiveImporter.downloadUnzipAndRevealRepoRoot(
            cloneHTTPSURL: postmanEfbyBrowserURL,
            branch: "",
            bitbucketUsername: user,
            bitbucketAppPassword: pass,
            importsParentDirectory: tempRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.path), "Se esperaba carpeta raíz del repo descomprimido.")
        let children = try FileManager.default.contentsOfDirectory(atPath: repoRoot.path)
        XCTAssertFalse(children.isEmpty, "El repo descomprimido no debería estar vacío.")
    }
}
