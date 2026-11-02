import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    public func suggestedCollectionName() -> String {
        catalogCoordinator.suggestedCollectionName(collections: workspace.collections)
    }

    public func suggestedCollectionCloneName(for collection: CollectionModel) -> String {
        catalogCoordinator.suggestedCollectionName(
            collections: workspace.collections,
            baseName: "\(collection.info.name) Copy"
        )
    }

    public func suggestedUtilityLibraryName() -> String {
        catalogCoordinator.suggestedUtilityLibraryName(utilityLibraries: workspace.utilityLibraries)
    }

    public func collectionNameValidationMessage(_ rawName: String, excluding excludedCollectionID: UUID? = nil) -> String? {
        catalogCoordinator.collectionNameValidationMessage(
            rawName,
            collections: workspace.collections,
            excluding: excludedCollectionID
        )
    }

    public func utilityLibraryNameValidationMessage(_ rawName: String, excluding excludedUtilityID: UUID? = nil) -> String? {
        catalogCoordinator.utilityLibraryNameValidationMessage(
            rawName,
            utilityLibraries: workspace.utilityLibraries,
            excluding: excludedUtilityID
        )
    }

    public func utilityLibrarySourceValidationMessage(_ rawSource: String, excluding excludedUtilityID: UUID? = nil) -> String? {
        catalogCoordinator.utilityLibrarySourceValidationMessage(
            rawSource,
            utilityLibraries: workspace.utilityLibraries,
            excluding: excludedUtilityID
        )
    }

    @discardableResult
    public func addUtilityLibrary(named rawName: String) -> WorkspaceScriptUtility? {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? suggestedUtilityLibraryName() : trimmedName

        if let validationMessage = utilityLibraryNameValidationMessage(name) {
            errorMessage = validationMessage
            return nil
        }

        let utility = catalogCoordinator.makeDefaultUtilityLibrary(named: name)
        if let validationMessage = utilityLibrarySourceValidationMessage(utility.source) {
            errorMessage = validationMessage
            return nil
        }
        workspace.utilityLibraries.append(utility)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: true
        )
        return utility
    }

    @discardableResult
    public func updateUtilityLibrary(_ utility: WorkspaceScriptUtility) -> Bool {
        if let validationMessage = utilityLibraryNameValidationMessage(utility.name, excluding: utility.id)
            ?? utilityLibrarySourceValidationMessage(utility.source, excluding: utility.id) {
            errorMessage = validationMessage
            return false
        }

        guard let index = workspace.utilityLibraries.firstIndex(where: { $0.id == utility.id }) else {
            return false
        }
        workspace.utilityLibraries[index] = utility
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: true
        )
        return true
    }

    public func renameUtilityLibrary(_ utility: WorkspaceScriptUtility, to rawName: String) {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let validationMessage = utilityLibraryNameValidationMessage(trimmedName, excluding: utility.id) else {
            guard let index = workspace.utilityLibraries.firstIndex(where: { $0.id == utility.id }) else { return }
            workspace.utilityLibraries[index].name = trimmedName
            persistWorkspace(
                syncSharedCollections: false,
                syncSharedEnvironments: false,
                syncSharedFlows: false,
                syncSharedUtilities: true
            )
            return
        }

        errorMessage = validationMessage
    }

    public func deleteUtilityLibrary(_ utility: WorkspaceScriptUtility) {
        workspace.utilityLibraries.removeAll { $0.id == utility.id }
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: false,
            syncSharedFlows: false,
            syncSharedUtilities: true
        )
    }

    public func addCollection() {
        addCollection(named: suggestedCollectionName())
    }

    public func addCollection(named rawName: String) {
        Task {
            do {
                try await ensureActiveWorkspaceExistsIfNeeded()
                let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmedName.isEmpty ? suggestedCollectionName() : trimmedName
                let collection = catalogCoordinator.makeNewCollection(named: name)

                workspace.collections.append(collection)
                persistWorkspace()
                infoMessage = "Collection '\(name)' created."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func duplicateCollection(_ collection: CollectionModel, named rawName: String) {
        Task {
            do {
                try await ensureActiveWorkspaceExistsIfNeeded()
                let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

                if let validationMessage = collectionNameValidationMessage(trimmedName) {
                    errorMessage = validationMessage
                    return
                }

                var duplicatedCollection = catalogCoordinator.cloneCollection(collection)
                duplicatedCollection.info.name = trimmedName
                workspace.collections.append(duplicatedCollection)
                persistWorkspace(syncSharedCollections: true, syncSharedEnvironments: false)
                infoMessage = "Collection '\(trimmedName)' cloned."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func exportCurrentCollection() -> (name: String, data: Data)? {
        guard let collection = currentCollection else { return nil }

        do {
            return try documentImportCoordinator.exportCollection(collection)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func deleteCollection(_ collection: CollectionModel) {
        workspace.collections.removeAll { $0.id == collection.id }
        if let activeWorkspaceName = workspace.activeWorkspaceName {
            workspace.requestDrafts.removeAll {
                $0.workspaceName == activeWorkspaceName && $0.collectionID == collection.id
            }
        }
        tabs.removeAll { $0.sourceCollectionID == collection.id }

        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.last?.id
        }

        if tabs.isEmpty {
            openFirstRequestIfNeeded()
        }

        persistWorkspace(syncSharedData: false)
    }

    public func renameCollection(_ collection: CollectionModel, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        workspace.collections[index].info.name = trimmed
        persistWorkspace()
    }

    /// Duplica un request en la colección (mismo árbol; nuevo id de nodo y de request) e inserta la copia justo debajo del original.
    public func duplicateRequestNode(_ node: CollectionNode, in collection: CollectionModel) {
        guard node.kind == .request, node.request != nil else { return }
        guard let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }
        guard let newNode = makeDuplicatedRequestCollectionNode(from: node) else { return }

        var items = workspace.collections[collectionIndex].items
        if !insertCollectionNode(newNode, afterSiblingID: node.id, in: &items) {
            items.append(newNode)
        }
        workspace.collections[collectionIndex].items = items

        guard let request = newNode.request else { return }
        let tab = RequestTabState(
            request: request,
            selectedEnvironmentID: workspace.activeEnvironmentID,
            pendingEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            persistedRequest: request,
            persistedSelectedEnvironmentID: workspace.activeEnvironmentID,
            persistedEnvironmentVariables: environmentCoordinator.variables(for: workspace.activeEnvironmentID, in: workspace.environments),
            sourceCollectionID: collection.id,
            sourceNodeID: newNode.id
        )
        tabs.append(tab)
        selectedTabID = tab.id
        persistWorkspace()
    }

    public func deleteRequestNode(_ node: CollectionNode, from collection: CollectionModel) {
        guard let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        workspace.collections[collectionIndex].items = remove(nodeID: node.id, from: workspace.collections[collectionIndex].items)
        removeDraft(nodeID: node.id, collectionID: collection.id)
        tabs.removeAll { $0.sourceNodeID == node.id }

        if let selectedTabID, !tabs.contains(where: { $0.id == selectedTabID }) {
            self.selectedTabID = tabs.last?.id
        }

        if tabs.isEmpty {
            openFirstRequestIfNeeded()
        }

        persistWorkspace()
    }

    public func renameRequestNode(_ node: CollectionNode, in collection: CollectionModel, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let collectionIndex = workspace.collections.firstIndex(where: { $0.id == collection.id }) else {
            return
        }

        workspace.collections[collectionIndex].items = workspace.collections[collectionIndex].items.map {
            rename(nodeID: node.id, in: $0, to: trimmed)
        }

        for tab in tabs where tab.sourceNodeID == node.id {
            tab.request.name = trimmed
        }

        persistWorkspace()
    }

    public func filteredCollections() -> [CollectionModel] {
        guard !searchText.isEmpty else {
            return workspace.collections
        }

        return workspace.collections.compactMap { collection in
            let filteredItems = filter(nodes: collection.items, with: searchText)
            if collection.info.name.localizedCaseInsensitiveContains(searchText) || !filteredItems.isEmpty {
                var copy = collection
                copy.items = filteredItems.isEmpty ? collection.items : filteredItems
                return copy
            }
            return nil
        }
    }

    private func filter(nodes: [CollectionNode], with query: String) -> [CollectionNode] {
        nodes.compactMap { node in
            if node.kind == .request && node.name.localizedCaseInsensitiveContains(query) {
                return node
            }

            let children = filter(nodes: node.children, with: query)
            if node.name.localizedCaseInsensitiveContains(query) || !children.isEmpty {
                var copy = node
                copy.children = children
                return copy
            }

            return nil
        }
    }

    func contains(nodeID: UUID, in node: CollectionNode) -> Bool {
        if node.id == nodeID {
            return true
        }
        return node.children.contains { contains(nodeID: nodeID, in: $0) }
    }

    func update(nodeID: UUID, in node: CollectionNode, with replacement: CollectionNode) -> CollectionNode {
        if node.id == nodeID {
            return replacement
        }

        var copy = node
        copy.children = node.children.map { update(nodeID: nodeID, in: $0, with: replacement) }
        return copy
    }

    private func rename(nodeID: UUID, in node: CollectionNode, to newName: String) -> CollectionNode {
        if node.id == nodeID {
            var copy = node
            copy.name = newName
            if copy.kind == .request {
                copy.request?.name = newName
            }
            return copy
        }

        var copy = node
        copy.children = node.children.map { rename(nodeID: nodeID, in: $0, to: newName) }
        return copy
    }

    /// Inserta `newNode` inmediatamente después del nodo con id `afterSiblingID` (búsqueda recursiva en carpetas).
    private func insertCollectionNode(_ newNode: CollectionNode, afterSiblingID: UUID, in nodes: inout [CollectionNode]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == afterSiblingID {
                nodes.insert(newNode, at: index + 1)
                return true
            }
            if nodes[index].kind == .folder && !nodes[index].children.isEmpty {
                var children = nodes[index].children
                if insertCollectionNode(newNode, afterSiblingID: afterSiblingID, in: &children) {
                    nodes[index].children = children
                    return true
                }
            }
        }
        return false
    }

    private func makeDuplicatedRequestCollectionNode(from node: CollectionNode) -> CollectionNode? {
        guard node.kind == .request, let sourceRequest = node.request else { return nil }
        guard var duplicatedRequest = catalogCoordinator.cloneRequest(sourceRequest) else { return nil }
        let baseName = node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (sourceRequest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Request" : sourceRequest.name)
            : node.name
        let copyTitle = "\(baseName) Copy"
        duplicatedRequest.name = copyTitle
        let duplicatedResponses = node.responses.map {
            SavedResponseModel(name: $0.name, statusCode: $0.statusCode, headers: $0.headers, body: $0.body)
        }
        return CollectionNode(
            name: copyTitle,
            kind: .request,
            request: duplicatedRequest,
            responses: duplicatedResponses,
            scripts: node.scripts,
            auth: node.auth,
            nodeDescription: node.nodeDescription,
            children: []
        )
    }

    private func remove(nodeID: UUID, from nodes: [CollectionNode]) -> [CollectionNode] {
        nodes.compactMap { node in
            if node.id == nodeID {
                return nil
            }

            var copy = node
            copy.children = remove(nodeID: nodeID, from: node.children)
            return copy
        }
    }

    func find(nodeID: UUID, in nodes: [CollectionNode]) -> CollectionNode? {
        for node in nodes {
            if node.id == nodeID {
                return node
            }
            if let nested = find(nodeID: nodeID, in: node.children) {
                return nested
            }
        }
        return nil
    }
}
