import EfbyInfrastructure
import Foundation

@main
struct FlowDebugRunner {
    static func main() async {
        do {
            let configuration = try Configuration(arguments: CommandLine.arguments)
            let workspace = try await WorkspaceRepository(storageURL: configuration.workspaceURL).load()
            guard let flow = workspace.flows.first(where: {
                $0.name.compare(configuration.flowName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                throw RunnerError("No se encontro el flow '\(configuration.flowName)'.")
            }

            let graph = try WorkspaceFlowBPMNParser().parse(xml: flow.bpmnXML)
            let availableRequests = flowRequestReferences(in: workspace.collections)
            let validation = WorkspaceFlowValidator().validate(
                flow: flow,
                graph: graph,
                availableRequests: availableRequests
            )

            print("Flow: \(flow.name)")
            print("Workspace: \(configuration.workspaceURL.path)")
            print("Nodos: \(graph.nodes.count) | Conexiones: \(graph.connections.count) | Bindings: \(flow.taskBindings.count)")

            if !validation.isValid {
                print("Validacion fallida:")
                for issue in validation.issues {
                    let element = issue.elementID.map { " [\($0)]" } ?? ""
                    print("- \(issue.severity.rawValue.uppercased())\(element): \(issue.message)")
                }
                Foundation.exit(2)
            }

            let resolvedRequests = try resolveRequests(for: flow, in: workspace.collections)
            let activeEnvironmentVariables = workspace.environments
                .first(where: { $0.id == workspace.activeEnvironmentID && $0.isEnabled })?
                .variables ?? []

            let service = WorkspaceFlowExecutionService(
                runner: RequestExecutionService(),
                webSocketRunner: WebSocketExecutionService()
            )

            let result = try await service.execute(
                flow: flow,
                graph: graph,
                globals: workspace.globalVariables,
                environment: activeEnvironmentVariables,
                workspaceEnvironments: workspace.environments,
                activeEnvironmentID: workspace.activeEnvironmentID,
                utilityLibraries: workspace.utilityLibraries,
                resolvedRequests: resolvedRequests,
                onLog: { entry in
                    print("[flow] \(entry)")
                }
            )

            print("")
            print("Resumen:")
            print("- Tasks ejecutadas: \(result.taskResults.count)")
            for task in result.taskResults {
                print("- \(task.requestName): status \(task.statusCode), \(Int(task.durationMilliseconds)) ms")
            }
            print("- Globals actualizadas: \(result.updatedGlobals.count)")
            print("- Environment actualizada: \(result.updatedEnvironment.count)")
            print("- Collections actualizadas: \(result.updatedCollections.count)")
        } catch {
            fputs("FlowDebugRunner error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct Configuration {
    let flowName: String
    let workspaceURL: URL

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw RunnerError("Uso: FlowDebugRunner \"NOMBRE FLOW\" [workspace.json]")
        }

        flowName = arguments[1]
        if arguments.count >= 3 {
            workspaceURL = URL(fileURLWithPath: arguments[2])
        } else {
            workspaceURL = try Self.defaultWorkspaceURL()
        }
    }

    private static func defaultWorkspaceURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("EFBYPostman", isDirectory: true)
        return baseURL.appendingPathComponent("workspace.json")
    }
}

private struct ResolvedRequestLocation {
    let request: APIRequestModel
    let nodeID: UUID
    let inheritedFolderScripts: [ScriptDefinition]
}

private struct RunnerError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func flowRequestReferences(in collections: [CollectionModel]) -> [WorkspaceFlowRequestReference] {
    collections.flatMap { collection in
        flowRequestReferences(in: collection.items, collection: collection)
    }
}

private func flowRequestReferences(in nodes: [CollectionNode], collection: CollectionModel) -> [WorkspaceFlowRequestReference] {
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

private func resolveRequests(
    for flow: WorkspaceFlowDefinition,
    in collections: [CollectionModel]
) throws -> [WorkspaceFlowResolvedRequest] {
    let requestIDs = Set(flow.taskBindings.compactMap(\.requestID))

    return try requestIDs.map { requestID in
        guard let resolved = resolveRequestReference(for: requestID, in: collections) else {
            throw RunnerError("El flow '\(flow.name)' apunta a un request inexistente: \(requestID.uuidString)")
        }
        return resolved
    }
}

private func resolveRequestReference(
    for requestID: UUID,
    in collections: [CollectionModel]
) -> WorkspaceFlowResolvedRequest? {
    for collection in collections {
        if let resolvedNode = resolveRequestNode(for: requestID, in: collection.items, inheritedScripts: []) {
            let effectiveRequest = enrichedRequest(
                from: resolvedNode.request,
                collection: collection,
                inheritedFolderScripts: resolvedNode.inheritedFolderScripts
            )
            return WorkspaceFlowResolvedRequest(
                requestID: effectiveRequest.id,
                collectionID: collection.id,
                request: effectiveRequest,
                collectionVariables: collection.variables
            )
        }
    }

    return nil
}

private func resolveRequestNode(
    for requestID: UUID,
    in nodes: [CollectionNode],
    inheritedScripts: [ScriptDefinition]
) -> ResolvedRequestLocation? {
    for node in nodes {
        let nextInheritedScripts = node.kind == .folder
            ? mergeScripts(inheritedScripts, node.scripts)
            : inheritedScripts

        if node.kind == .request,
           let request = node.request,
           request.id == requestID {
            return ResolvedRequestLocation(
                request: request,
                nodeID: node.id,
                inheritedFolderScripts: inheritedScripts
            )
        }

        if let nested = resolveRequestNode(
            for: requestID,
            in: node.children,
            inheritedScripts: nextInheritedScripts
        ) {
            return nested
        }
    }

    return nil
}

private func enrichedRequest(
    from request: APIRequestModel,
    collection: CollectionModel,
    inheritedFolderScripts: [ScriptDefinition]
) -> APIRequestModel {
    var enriched = request
    if enriched.auth.type == .noAuth, collection.auth.type != .noAuth {
        enriched.auth = collection.auth
    }
    enriched.scripts = mergeScripts(collection.scripts, inheritedFolderScripts, enriched.scripts)
    return enriched
}

private func mergeScripts(_ groups: [ScriptDefinition]...) -> [ScriptDefinition] {
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
