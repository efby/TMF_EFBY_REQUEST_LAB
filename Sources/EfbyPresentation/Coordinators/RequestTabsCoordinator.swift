import EfbyDomain
import Foundation

/// Coordina drafts de pestañas y su persistencia en el workspace local.
@MainActor
public final class RequestTabsCoordinator {
    public enum DraftMutation {
        case removeCollectionDraft(nodeID: UUID, collectionID: UUID)
        case update(index: Int, draft: RequestDraftState)
        case append(RequestDraftState)
    }

    private let environmentCoordinator: EnvironmentCoordinator

    public init(environmentCoordinator: EnvironmentCoordinator = EnvironmentCoordinator()) {
        self.environmentCoordinator = environmentCoordinator
    }

    public func makeDraft(from tab: RequestTabState, workspaceName: String) -> RequestDraftState {
        RequestDraftState(
            id: tab.id,
            workspaceName: workspaceName,
            tabID: tab.id,
            collectionID: tab.sourceCollectionID,
            nodeID: tab.sourceNodeID,
            request: tab.request,
            selectedEnvironmentID: tab.selectedEnvironmentID,
            pendingEnvironmentVariables: tab.pendingEnvironmentVariables,
            persistedRequest: tab.persistedRequest,
            persistedSelectedEnvironmentID: tab.persistedSelectedEnvironmentID,
            persistedEnvironmentVariables: tab.persistedEnvironmentVariables
        )
    }

    public func resolveDraftMutation(
        tab: RequestTabState,
        activeWorkspaceName: String,
        drafts: [RequestDraftState],
        requestsEquivalent: (APIRequestModel, APIRequestModel) -> Bool
    ) -> DraftMutation {
        let draft = makeDraft(from: tab, workspaceName: activeWorkspaceName)
        let matchesPersistedBaseline =
            requestsEquivalent(tab.persistedRequest, tab.request)
            && tab.selectedEnvironmentID == tab.persistedSelectedEnvironmentID
            && environmentCoordinator.variablesEquivalent(
                tab.pendingEnvironmentVariables,
                tab.persistedEnvironmentVariables
            )

        if matchesPersistedBaseline,
           let collectionID = tab.sourceCollectionID,
           let nodeID = tab.sourceNodeID {
            return .removeCollectionDraft(nodeID: nodeID, collectionID: collectionID)
        }

        if let index = drafts.firstIndex(where: { existing in
            if let collectionID = tab.sourceCollectionID,
               let nodeID = tab.sourceNodeID {
                return existing.workspaceName == activeWorkspaceName &&
                    existing.collectionID == collectionID &&
                    existing.nodeID == nodeID
            }
            return existing.workspaceName == activeWorkspaceName && existing.tabID == tab.id
        }) {
            return .update(index: index, draft: draft)
        }

        return .append(draft)
    }

    public func standaloneDraftStates(
        workspaceName: String?,
        drafts: [RequestDraftState]
    ) -> [RequestDraftState] {
        guard let workspaceName else { return [] }
        return drafts.filter {
            $0.workspaceName == workspaceName &&
            $0.collectionID == nil &&
            $0.nodeID == nil
        }
    }

    public func draftState(
        nodeID: UUID,
        collectionID: UUID,
        workspaceName: String?,
        drafts: [RequestDraftState]
    ) -> RequestDraftState? {
        guard let workspaceName else { return nil }
        return drafts.first {
            $0.workspaceName == workspaceName &&
            $0.collectionID == collectionID &&
            $0.nodeID == nodeID
        }
    }
}
