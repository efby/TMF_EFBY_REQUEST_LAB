import EfbyPresentation
import XCTest

@MainActor
final class BitbucketPadCoordinatorTests: XCTestCase {
    private let coordinator = BitbucketPadCoordinator()

    func testPlanInitialDownloadRequiresURL() {
        let result = coordinator.planInitialDownload(
            cloneHTTPSURL: "  ",
            branch: "main",
            bitbucketUsername: "u",
            bitbucketAppPassword: "p"
        )
        guard case .failure = result else {
            return XCTFail("Expected failure for empty URL")
        }
    }

    func testPlanInitialDownloadTrimsFields() {
        let result = coordinator.planInitialDownload(
            cloneHTTPSURL: " https://bitbucket.org/w/r.git ",
            branch: " main ",
            bitbucketUsername: " user ",
            bitbucketAppPassword: " token "
        )
        guard case .success(let plan) = result else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(plan.cloneHTTPSURL, "https://bitbucket.org/w/r.git")
        XCTAssertEqual(plan.branch, "main")
        XCTAssertEqual(plan.username, "user")
        XCTAssertEqual(plan.appPassword, "token")
        XCTAssertFalse(plan.isResync)
    }

    func testPlanResyncRequiresSharedRepository() {
        let result = coordinator.planResync(
            cloneHTTPSURL: "https://bitbucket.org/w/r.git",
            branch: "main",
            bitbucketUsername: "u",
            bitbucketAppPassword: "p",
            hasSharedRepository: false,
            savedCloneHTTPSURL: nil,
            savedBranch: nil,
            savedUsername: nil
        )
        guard case .failure = result else {
            return XCTFail("Expected failure without shared repository")
        }
    }

    func testPlanResyncUsesSavedMetadataWhenFormEmpty() {
        let result = coordinator.planResync(
            cloneHTTPSURL: "",
            branch: "",
            bitbucketUsername: "",
            bitbucketAppPassword: "token",
            hasSharedRepository: true,
            savedCloneHTTPSURL: "https://bitbucket.org/w/r.git",
            savedBranch: "develop",
            savedUsername: "saved-user"
        )
        guard case .success(let plan) = result else {
            return XCTFail("Expected success")
        }
        XCTAssertEqual(plan.cloneHTTPSURL, "https://bitbucket.org/w/r.git")
        XCTAssertEqual(plan.branch, "develop")
        XCTAssertEqual(plan.username, "saved-user")
        XCTAssertTrue(plan.isResync)
    }

    func testApplyMetadataUpdatesWorkspace() {
        var workspace = WorkspaceState.starter
        let result = BitbucketPadCoordinator.ImportResult(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
            cloneHTTPSURL: "https://bitbucket.org/w/r.git",
            branch: "main",
            username: "u",
            tokenToPersist: "secret"
        )
        coordinator.applyMetadata(from: result, to: &workspace)
        XCTAssertEqual(workspace.bitbucketPadCloneHTTPSURL, "https://bitbucket.org/w/r.git")
        XCTAssertEqual(workspace.bitbucketPadBranch, "main")
        XCTAssertEqual(workspace.bitbucketPadUsername, "u")
    }
}
