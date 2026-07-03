import EfbyDomain
import Foundation

/// Fusión de scripts de colección/carpeta/request y enriquecimiento de auth heredada.
public enum CollectionScriptSupport {
    public static func mergeScripts(_ groups: [ScriptDefinition]...) -> [ScriptDefinition] {
        var merged: [ScriptDefinition] = []
        var seen = Set<String>()

        for group in groups {
            for script in group {
                let key = [script.listen.rawValue, script.name, script.language, script.source].joined(separator: "::")
                if seen.insert(key).inserted {
                    merged.append(script)
                }
            }
        }

        return merged
    }

    public static func enrichedRequest(
        from request: APIRequestModel,
        collection: CollectionModel?,
        sourceNodeID: UUID?
    ) -> APIRequestModel {
        guard let collection else { return request }
        var enriched = request
        if enriched.auth.type == .noAuth, collection.auth.type != .noAuth {
            enriched.auth = collection.auth
        }
        enriched.scripts = mergeScripts(
            collection.scripts,
            inheritedFolderScripts(for: sourceNodeID, in: collection.items) ?? [],
            enriched.scripts
        )
        return enriched
    }

    public static func mergeScriptsIntoSavedRequest(node: CollectionNode) -> APIRequestModel {
        guard var request = node.request else {
            return APIRequestModel(
                name: "Untitled Request",
                method: .get,
                url: "https://postman-echo.com/get"
            )
        }
        request.scripts = mergeScripts(node.scripts, request.scripts)
        return request
    }

    public static func inheritedFolderScripts(for nodeID: UUID?, in nodes: [CollectionNode]) -> [ScriptDefinition]? {
        guard let nodeID else {
            return nil
        }
        return folderScripts(to: nodeID, in: nodes, inherited: [])
    }

    private static func folderScripts(
        to nodeID: UUID,
        in nodes: [CollectionNode],
        inherited: [ScriptDefinition]
    ) -> [ScriptDefinition]? {
        for node in nodes {
            let nextInherited = node.kind == .folder
                ? mergeScripts(inherited, node.scripts)
                : inherited

            if node.id == nodeID {
                return inherited
            }

            if let match = folderScripts(to: nodeID, in: node.children, inherited: nextInherited) {
                return match
            }
        }

        return nil
    }
}
