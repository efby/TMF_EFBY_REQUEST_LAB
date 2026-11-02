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
    // Request comparison belongs to draft management; identity alone is not an edit.


    func requestsEquivalentForPersistence(_ lhs: APIRequestModel, _ rhs: APIRequestModel) -> Bool {
        normalizedRequest(lhs) == normalizedRequest(rhs)
    }

    private func normalizedRequest(_ request: APIRequestModel) -> APIRequestModel {
        APIRequestModel(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
            name: request.name,
            transportKind: request.transportKind,
            httpRequestTargetKind: request.httpRequestTargetKind,
            method: request.method,
            url: request.url,
            queryItems: request.queryItems.map(normalizedKeyValueEntry),
            pathVariables: request.pathVariables.map(normalizedKeyValueEntry),
            headers: request.headers.map(normalizedKeyValueEntry),
            cookies: request.cookies.map(normalizedKeyValueEntry),
            auth: request.auth,
            body: RequestBodyModel(
                kind: request.body.kind,
                raw: request.body.raw,
                parameters: request.body.parameters.map(normalizedKeyValueEntry)
            ),
            scripts: request.scripts.map(normalizedScriptDefinition),
            localVariables: request.localVariables.map(normalizedKeyValueEntry),
            timeoutSeconds: request.timeoutSeconds,
            retryOn206Count: request.retryOn206Count,
            retryOn206DelayMilliseconds: request.retryOn206DelayMilliseconds,
            tlsValidationMode: request.tlsValidationMode,
            minimumTLSVersion: request.minimumTLSVersion,
            webSocketSubprotocols: request.webSocketSubprotocols,
            webSocketOpenTimeoutSeconds: request.webSocketOpenTimeoutSeconds,
            webSocketReconnectAttempts: request.webSocketReconnectAttempts,
            webSocketReconnectIntervalMilliseconds: request.webSocketReconnectIntervalMilliseconds,
            webSocketMaximumMessageSizeMB: request.webSocketMaximumMessageSizeMB,
            webSocketPingIntervalSeconds: request.webSocketPingIntervalSeconds,
            webSocketKeepAliveMessage: request.webSocketKeepAliveMessage,
            webSocketKeepAliveIntervalSeconds: request.webSocketKeepAliveIntervalSeconds,
            awsAccessPortalURLTemplate: request.awsAccessPortalURLTemplate
        )
    }

    private func normalizedKeyValueEntry(_ entry: KeyValueEntry) -> KeyValueEntry {
        KeyValueEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
            key: entry.key,
            value: entry.value,
            isEnabled: entry.isEnabled
        )
    }

    private func normalizedScriptDefinition(_ script: ScriptDefinition) -> ScriptDefinition {
        ScriptDefinition(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
            name: script.name,
            listen: script.listen,
            language: script.language,
            source: script.source
        )
    }
}
