import EfbyDomain
import Foundation

/// Validación, nombres y clonado de colecciones, flows y utility libraries.
@MainActor
public final class WorkspaceCatalogCoordinator {
    public init() {}

    public func suggestedCollectionName(collections: [CollectionModel], baseName: String = "New Collection") -> String {
        makeUniqueName(
            baseName: baseName,
            existingNames: Set(collections.map { $0.info.name.lowercased() })
        )
    }

    public func suggestedUtilityLibraryName(utilityLibraries: [WorkspaceScriptUtility]) -> String {
        var counter = 1
        let existing = Set(utilityLibraries.map { $0.name.lowercased() })
        while true {
            let candidate = "Utilities \(counter)"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }

    public func suggestedFlowName(flows: [WorkspaceFlowDefinition]) -> String {
        var counter = 1
        let existing = Set(flows.map { $0.name.lowercased() })
        while true {
            let candidate = "Flow \(counter)"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }

    public func suggestedFlowCloneName(for flow: WorkspaceFlowDefinition, flows: [WorkspaceFlowDefinition]) -> String {
        makeUniqueName(
            baseName: "\(flow.name) Copy",
            existingNames: Set(flows.map { $0.name.lowercased() })
        )
    }

    public func collectionNameValidationMessage(
        _ rawName: String,
        collections: [CollectionModel],
        excluding excludedCollectionID: UUID? = nil
    ) -> String? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Name is required."
        }

        guard !collections.contains(where: {
            $0.id != excludedCollectionID && $0.info.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            return "A collection with that name already exists."
        }

        return nil
    }

    public func utilityLibraryNameValidationMessage(
        _ rawName: String,
        utilityLibraries: [WorkspaceScriptUtility],
        excluding excludedUtilityID: UUID? = nil
    ) -> String? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Name is required."
        }

        guard !utilityLibraries.contains(where: {
            $0.id != excludedUtilityID && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            return "A utility library with that name already exists."
        }

        return nil
    }

    public func flowNameValidationMessage(
        _ rawName: String,
        flows: [WorkspaceFlowDefinition],
        excluding excludedFlowID: UUID? = nil
    ) -> String? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "Name is required."
        }

        guard !flows.contains(where: {
            $0.id != excludedFlowID && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            return "A flow with that name already exists."
        }

        return nil
    }

    public func utilityLibrarySourceValidationMessage(
        _ rawSource: String,
        utilityLibraries: [WorkspaceScriptUtility],
        excluding excludedUtilityID: UUID? = nil
    ) -> String? {
        let duplicatedSymbols = duplicateUtilitySymbols(
            for: rawSource,
            utilityLibraries: utilityLibraries,
            excluding: excludedUtilityID
        )
        guard !duplicatedSymbols.isEmpty else {
            return nil
        }

        if duplicatedSymbols.count == 1, let duplicatedSymbol = duplicatedSymbols.first {
            return "The global constant or function '\(duplicatedSymbol)' already exists in another utility library."
        }

        return "These global constants or functions already exist in other utility libraries: \(duplicatedSymbols.joined(separator: ", "))."
    }

    public func makeNewCollection(named name: String) -> CollectionModel {
        CollectionModel(
            info: CollectionInfoModel(
                name: name,
                description: "Collection created in EFBYPostman.",
                schemaVersion: .v21
            )
        )
    }

    public func makeDefaultUtilityLibrary(named name: String) -> WorkspaceScriptUtility {
        WorkspaceScriptUtility(
            name: name,
            language: "javascript",
            source: """
            const \(sanitizedUtilityIdentifier(from: name)) = {
                
            };
            """
        )
    }

    public func makeClonedFlow(from flow: WorkspaceFlowDefinition, named name: String) -> WorkspaceFlowDefinition {
        var copy = flow
        copy.id = UUID()
        copy.name = name
        let now = Date()
        copy.createdAt = now
        copy.updatedAt = now
        return copy
    }

    public func cloneCollection(_ collection: CollectionModel) -> CollectionModel {
        CollectionModel(
            info: CollectionInfoModel(
                name: collection.info.name,
                description: collection.info.description,
                schemaVersion: collection.info.schemaVersion
            ),
            variables: collection.variables,
            auth: collection.auth,
            scripts: collection.scripts,
            items: collection.items.map(cloneCollectionNode(_:)),
            sourceFormat: collection.sourceFormat
        )
    }

    public func flowRequestReferences(in collections: [CollectionModel]) -> [WorkspaceFlowRequestReference] {
        collections.flatMap { collection in
            flowRequestReferences(in: collection.items, collection: collection)
        }
        .sorted {
            if $0.collectionName == $1.collectionName {
                return $0.requestName.localizedCaseInsensitiveCompare($1.requestName) == .orderedAscending
            }
            return $0.collectionName.localizedCaseInsensitiveCompare($1.collectionName) == .orderedAscending
        }
    }

    public func sanitizedUtilityIdentifier(from name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return "_"
        }
        let raw = String(scalars)
        let collapsed = raw.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let candidate = trimmed.isEmpty ? "workspaceUtils" : trimmed
        if let first = candidate.first, first.isNumber {
            return "u_\(candidate)"
        }
        return candidate
    }

    private func makeUniqueName(baseName: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }

        var index = 2
        while existingNames.contains("\(baseName) \(index)".lowercased()) {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    private func duplicateUtilitySymbols(
        for source: String,
        utilityLibraries: [WorkspaceScriptUtility],
        excluding excludedUtilityID: UUID?
    ) -> [String] {
        let existingSymbols = utilityLibraries
            .filter { $0.id != excludedUtilityID }
            .flatMap { JavaScriptUtilitySymbolParser.topLevelSymbolNames(in: $0.source) }
        let sourceSymbols = JavaScriptUtilitySymbolParser.topLevelSymbolNames(in: source)

        return Array(Set(sourceSymbols).intersection(existingSymbols)).sorted()
    }

    private func flowRequestReferences(
        in nodes: [CollectionNode],
        collection: CollectionModel
    ) -> [WorkspaceFlowRequestReference] {
        nodes.flatMap { node -> [WorkspaceFlowRequestReference] in
            var results: [WorkspaceFlowRequestReference] = []
            if let request = node.request, node.kind == .request {
                results.append(
                    WorkspaceFlowRequestReference(
                        requestID: request.id,
                        collectionID: collection.id,
                        nodeID: node.id,
                        collectionName: collection.info.name,
                        requestName: node.name,
                        transportKind: request.transportKind
                    )
                )
            }
            results.append(contentsOf: flowRequestReferences(in: node.children, collection: collection))
            return results
        }
    }

    private func cloneCollectionNode(_ node: CollectionNode) -> CollectionNode {
        CollectionNode(
            name: node.name,
            kind: node.kind,
            request: cloneRequest(node.request),
            responses: node.responses,
            scripts: node.scripts,
            auth: node.auth,
            nodeDescription: node.nodeDescription,
            children: node.children.map(cloneCollectionNode(_:))
        )
    }

    public func cloneRequest(_ request: APIRequestModel?) -> APIRequestModel? {
        guard let request else { return nil }

        return APIRequestModel(
            name: request.name,
            transportKind: request.transportKind,
            httpRequestTargetKind: request.httpRequestTargetKind,
            method: request.method,
            url: request.url,
            queryItems: request.queryItems,
            pathVariables: request.pathVariables,
            headers: request.headers,
            cookies: request.cookies,
            auth: request.auth,
            body: request.body,
            scripts: request.scripts,
            localVariables: request.localVariables,
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
}
