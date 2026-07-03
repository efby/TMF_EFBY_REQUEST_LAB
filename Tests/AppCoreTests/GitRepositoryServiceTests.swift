import EfbyPresentation
import XCTest

final class GitRepositoryServiceTests: XCTestCase {
    func testNormalizesBitbucketWebURLToGitRemote() throws {
        let service = GitRepositoryService()

        let configuration = try service.normalizeRemoteInput("https://bitbucket.org/teamefby/postmanefby/src/main/")

        XCTAssertEqual(configuration.remoteURL, "https://bitbucket.org/teamefby/postmanefby.git")
    }

    func testDoesNotDuplicateGitSuffixForBitbucketRemote() throws {
        let service = GitRepositoryService()

        let configuration = try service.normalizeRemoteInput("https://bitbucket.org/teamefby/postmanefby.git")

        XCTAssertEqual(configuration.remoteURL, "https://bitbucket.org/teamefby/postmanefby.git")
    }

    func testNormalizesCloneCommandToRemote() throws {
        let service = GitRepositoryService()

        let configuration = try service.normalizeRemoteInput("git clone git@bitbucket.org:teamefby/postmanefby.git")

        XCTAssertEqual(configuration.remoteURL, "git@bitbucket.org:teamefby/postmanefby.git")
    }

    func testDetectsProviderAndAuthenticationHelpForGitHubHTTPS() {
        let service = GitRepositoryService()

        let provider = service.provider(for: "https://github.com/example/project.git")
        let authKind = service.authenticationKind(for: "https://github.com/example/project.git")
        let helpURL = service.authenticationHelpURL(for: provider, kind: authKind)

        XCTAssertEqual(provider, .github)
        XCTAssertEqual(authKind, .https)
        XCTAssertEqual(helpURL?.absoluteString, "https://github.com/settings/tokens")
    }

    func testDetectsProviderAndAuthenticationHelpForBitbucketSSH() {
        let service = GitRepositoryService()

        let provider = service.provider(for: "git@bitbucket.org:teamefby/postmanefby.git")
        let authKind = service.authenticationKind(for: "git@bitbucket.org:teamefby/postmanefby.git")
        let helpURL = service.authenticationHelpURL(for: provider, kind: authKind)

        XCTAssertEqual(provider, .bitbucket)
        XCTAssertEqual(authKind, .ssh)
        XCTAssertEqual(helpURL?.absoluteString, "https://bitbucket.org/account/settings/ssh-keys/")
    }

    func testPrefersTokenForBitbucketHTTPS() {
        let service = GitRepositoryService()

        let mode = service.preferredCredentialMode(for: .bitbucket, kind: .https)
        let instructions = service.credentialInstructions(for: .bitbucket, kind: .https)

        XCTAssertEqual(mode, .token)
        XCTAssertTrue(instructions.contains("Bitbucket"))
        XCTAssertTrue(instructions.contains("API token"))
    }

    func testPrefersTokenForGitHubHTTPS() {
        let service = GitRepositoryService()

        let mode = service.preferredCredentialMode(for: .github, kind: .https)
        let instructions = service.credentialInstructions(for: .github, kind: .https)

        XCTAssertEqual(mode, .token)
        XCTAssertTrue(instructions.contains("Personal Access Token"))
    }

    func testParseGitPathListPreservesPathsWithSpacesWithoutQuotes() {
        let service = GitRepositoryService()

        let paths = service.parseGitPathList("""
        COPEC PAY/collections/ventas-qa-asistido-gw.postman_collection.json
        COPEC PAY/environments/pay.postman_environment.json
        """)

        XCTAssertEqual(
            paths,
            [
                "COPEC PAY/collections/ventas-qa-asistido-gw.postman_collection.json",
                "COPEC PAY/environments/pay.postman_environment.json",
            ]
        )
    }

    func testParsesRemoteDefaultBranchFromSymrefOutput() {
        let service = GitRepositoryService()

        let branch = service.parseRemoteDefaultBranch(from: """
        ref: refs/heads/main\tHEAD
        2f4c8f8b4f0d1234567890abcdef1234567890ab\tHEAD
        """)

        XCTAssertEqual(branch, "main")
    }

    func testParsesRemoteDefaultBranchFromRemoteShowOutput() {
        let service = GitRepositoryService()

        let branch = service.parseRemoteDefaultBranch(fromRemoteShow: """
        * remote origin
          Fetch URL: git@bitbucket.org:teamefby/postmanefby.git
          Push  URL: git@bitbucket.org:teamefby/postmanefby.git
          HEAD branch: main
        """)

        XCTAssertEqual(branch, "main")
    }

    func testParsesTrackingBranchReference() {
        let service = GitRepositoryService()

        let reference = service.parseTrackingBranchReference(from: "origin/main\n")

        XCTAssertEqual(reference, "origin/main")
    }

    func testDetectsPullFailuresThatShouldPreferRemoteVersion() {
        let service = GitRepositoryService()

        XCTAssertTrue(service.shouldResolvePullFailureWithRemoteVersion("CONFLICT (content): Merge conflict in request.json"))
        XCTAssertTrue(service.shouldResolvePullFailureWithRemoteVersion("Automatic merge failed; fix conflicts and then commit the result."))
        XCTAssertFalse(service.shouldResolvePullFailureWithRemoteVersion("fatal: refusing to merge unrelated histories"))
    }
}
