import EfbyDomain
import EfbyPresentation
import XCTest

@MainActor
final class RequestTabsCoordinatorTests: XCTestCase {
    private let coordinator = RequestTabsCoordinator()

    func testResolveDraftMutationAppendsStandaloneDraft() {
        let tab = RequestTabState(request: APIRequestModel(name: "Draft"))
        let mutation = coordinator.resolveDraftMutation(
            tab: tab,
            activeWorkspaceName: "default",
            drafts: [],
            requestsEquivalent: { _, _ in false }
        )

        guard case .append(let draft) = mutation else {
            return XCTFail("Expected append mutation")
        }
        XCTAssertEqual(draft.workspaceName, "default")
        XCTAssertEqual(draft.tabID, tab.id)
        XCTAssertNil(draft.collectionID)
    }

    func testResolveDraftMutationRemovesWhenMatchesBaseline() {
        let collectionID = UUID()
        let nodeID = UUID()
        let request = APIRequestModel(name: "Saved")
        let tab = RequestTabState(
            request: request,
            persistedRequest: request,
            sourceCollectionID: collectionID,
            sourceNodeID: nodeID
        )

        let mutation = coordinator.resolveDraftMutation(
            tab: tab,
            activeWorkspaceName: "default",
            drafts: [
                RequestDraftState(
                    workspaceName: "default",
                    collectionID: collectionID,
                    nodeID: nodeID,
                    request: request
                ),
            ],
            requestsEquivalent: { $0 == $1 }
        )

        guard case .removeCollectionDraft(let removedNodeID, let removedCollectionID) = mutation else {
            return XCTFail("Expected remove mutation")
        }
        XCTAssertEqual(removedNodeID, nodeID)
        XCTAssertEqual(removedCollectionID, collectionID)
    }

    func testStandaloneDraftStatesFiltersWorkspace() {
        let drafts = [
            RequestDraftState(workspaceName: "default", tabID: UUID(), request: APIRequestModel(name: "A")),
            RequestDraftState(
                workspaceName: "default",
                collectionID: UUID(),
                nodeID: UUID(),
                request: APIRequestModel(name: "B")
            ),
            RequestDraftState(workspaceName: "other", tabID: UUID(), request: APIRequestModel(name: "C")),
        ]

        let standalone = coordinator.standaloneDraftStates(workspaceName: "default", drafts: drafts)
        XCTAssertEqual(standalone.count, 1)
        XCTAssertEqual(standalone[0].request.name, "A")
    }
}
