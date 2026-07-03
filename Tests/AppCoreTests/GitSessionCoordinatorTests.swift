import EfbyApplication
import EfbyDomain
import EfbyPresentation
import XCTest

@MainActor
final class GitSessionCoordinatorTests: XCTestCase {
    func testNormalizeAndAppendOutput() {
        let coordinator = makeSessionCoordinator()
        var output: String?

        coordinator.append(chunk: "line1\r\n", to: &output)
        coordinator.append(chunk: "line2\r", to: &output)

        XCTAssertEqual(output, "line1\nline2\n")
    }

    func testEvaluatePushGateBlocksReadOnlyMirror() async {
        let coordinator = makeSessionCoordinator()
        let gate = await coordinator.evaluatePushGate(
            at: URL(fileURLWithPath: "/tmp/repo"),
            isReadOnlyMirror: true
        )

        XCTAssertFalse(gate.canPush)
        XCTAssertNotNil(gate.reason)
        XCTAssertFalse(gate.mergeInProgress)
    }

    func testStashFlagsResetAndMark() {
        let coordinator = makeSessionCoordinator()
        coordinator.markPendingStashPopAfterPull(true)
        XCTAssertTrue(coordinator.pendingStashPopAfterSharedPull)

        coordinator.resetStashFlags()
        XCTAssertFalse(coordinator.pendingStashPopAfterSharedPull)
        XCTAssertFalse(coordinator.pendingStashDropAfterPopConflict)
    }

    private func makeSessionCoordinator() -> GitSessionCoordinator {
        let gitService = GitRepositoryService()
        let gitCoordinator = GitWorkspaceCoordinator(
            syncGitWorkspace: SyncGitWorkspaceUseCase(gitService: gitService),
            gitPull: GitPullUseCase(gitService: gitService),
            gitCommitAndPush: GitCommitAndPushUseCase(gitService: gitService),
            gitService: gitService
        )
        return GitSessionCoordinator(gitCoordinator: gitCoordinator, gitService: gitService)
    }
}
