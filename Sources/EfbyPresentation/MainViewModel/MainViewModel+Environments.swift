import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
extension MainViewModel {

    public func hasPendingEnvironmentChanges(for tab: RequestTabState) -> Bool {
        !environmentCoordinator.variablesEquivalent(tab.pendingEnvironmentVariables, tab.persistedEnvironmentVariables)
    }

    public func suggestedEnvironmentCloneName(for profile: EnvironmentProfile) -> String {
        environmentCoordinator.suggestedCloneName(
            for: profile,
            existingNames: Set(workspace.environments.map { $0.name.lowercased() })
        )
    }

    /// Parses a JSON object and upserts each top-level key into the **active** environment profile (string values). Persists workspace.
    public func upsertActiveEnvironmentVariablesFromFlowBatchParametersJSON(
        _ json: String,
        targetEnvironmentID: UUID? = nil
    ) throws {
        let updates = try environmentCoordinator.parseFlowBatchParameterUpdates(from: json)
        let environmentID = targetEnvironmentID ?? workspace.activeEnvironmentID
        guard let environmentID,
              let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID && $0.isEnabled }) else {
            throw AppError.invalidDocument("Selecciona un entorno activo antes de aplicar parámetros del run.")
        }

        let previous = workspace.environments[environmentIndex].variables
        let merged = environmentCoordinator.merge(existing: previous, with: updates)
        workspace.environments[environmentIndex].variables = merged

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environmentID,
            previousVariables: previous,
            updatedVariables: merged,
            excluding: UUID()
        )

        persistWorkspace(
            syncSharedCollections: true,
            syncSharedEnvironments: true,
            syncSharedFlows: true,
            syncSharedUtilities: true
        )
    }

    /// Claves de primer nivel de un `parametersJSON` de batch (objeto raíz; trim, sin vacías). No objeto o JSON inválido → conjunto vacío.
    public func topLevelKeysFromFlowBatchParametersJSON(_ json: String) -> Set<String> {
        environmentCoordinator.topLevelKeysFromFlowBatchParametersJSON(json)
    }

    /// Recorre el JSON de cada caso (`parametersJSON` como objeto raíz) y devuelve la unión de claves de primer nivel **únicas** (trim, sin vacías). Se usa antes de cada run batch (individual o secuencial): se quitan todas esas claves del entorno activo y luego se aplica solo el JSON de la fila en ejecución.
    public func allTopLevelKeysFromFlowBatchRunCases(_ cases: [WorkspaceFlowBatchRunCase]) -> Set<String> {
        cases.reduce(into: Set<String>()) { partial, runCase in
            partial.formUnion(topLevelKeysFromFlowBatchParametersJSON(runCase.parametersJSON))
        }
    }

    /// Quita del perfil de entorno **activo** todas las variables cuyo `key` esté en `keys`. Persiste el workspace como en el upsert de batch.
    public func removeActiveEnvironmentVariables(withKeys keys: Set<String>, targetEnvironmentID: UUID? = nil) throws {
        guard !keys.isEmpty else { return }
        let environmentID = targetEnvironmentID ?? workspace.activeEnvironmentID
        guard let environmentID,
              let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID && $0.isEnabled }) else {
            throw AppError.invalidDocument("Selecciona un entorno activo antes de aplicar parámetros del run.")
        }

        let previous = workspace.environments[environmentIndex].variables
        let filtered = previous.filter { variable in
            let k = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
            return !keys.contains(k)
        }

        workspace.environments[environmentIndex].variables = filtered

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environmentID,
            previousVariables: previous,
            updatedVariables: filtered,
            excluding: UUID()
        )

        persistWorkspace(
            syncSharedCollections: true,
            syncSharedEnvironments: true,
            syncSharedFlows: true,
            syncSharedUtilities: true
        )
    }

    public func saveCurrentEnvironmentChanges() {
        snapshotOpenTabsIntoDrafts(enqueue: false)
        persistWorkspace(syncSharedCollections: false, syncSharedEnvironments: true,
                         syncSharedFlows: false, syncSharedUtilities: false, immediately: true)
    }

    public func activateEnvironment(_ environment: EnvironmentProfile?) {
        workspace.activeEnvironmentID = environment?.id
        persistWorkspace(syncSharedData: false)
    }

    @discardableResult
    public func addEnvironment() -> EnvironmentProfile {
        let environment = EnvironmentProfile(name: "New Environment")
        workspace.environments.append(environment)
        workspace.activeEnvironmentID = environment.id
        persistWorkspace(syncSharedData: false)
        return environment
    }

    public func deleteEnvironment(_ environment: EnvironmentProfile) {
        workspace.environments.removeAll { $0.id == environment.id }
        if workspace.activeEnvironmentID == environment.id {
            workspace.activeEnvironmentID = workspace.environments.first?.id
        }
        var drafts = workspace.requestDrafts
        environmentCoordinator.clearReferences(
            to: environment.id,
            tabs: tabs,
            drafts: &drafts
        )
        workspace.requestDrafts = drafts
        persistWorkspace(syncSharedData: false)
    }

    public func updateEnvironment(_ environment: EnvironmentProfile) {
        guard let index = workspace.environments.firstIndex(where: { $0.id == environment.id }) else { return }
        let previousVariables = workspace.environments[index].variables
        workspace.environments[index] = environment

        for tab in tabs where (tab.selectedEnvironmentID ?? workspace.activeEnvironmentID) == environment.id {
            tab.pendingEnvironmentVariables = environment.variables
            updateDraft(for: tab)
        }

        for draftIndex in workspace.requestDrafts.indices {
            let draftEnvironmentID = workspace.requestDrafts[draftIndex].selectedEnvironmentID
                ?? workspace.requestDrafts[draftIndex].persistedSelectedEnvironmentID
                ?? workspace.activeEnvironmentID
            guard draftEnvironmentID == environment.id else { continue }
            workspace.requestDrafts[draftIndex].pendingEnvironmentVariables = environment.variables
        }

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environment.id,
            previousVariables: previousVariables,
            updatedVariables: environment.variables,
            excluding: UUID()
        )

        persistWorkspace(syncSharedData: false)
    }

    public func selectEnvironment(_ environment: EnvironmentProfile?, for tab: RequestTabState) {
        tab.selectedEnvironmentID = environment?.id
        tab.pendingEnvironmentVariables = environmentCoordinator.variables(for: environment?.id, in: workspace.environments)
        tab.persistedEnvironmentVariables = environmentCoordinator.variables(for: environment?.id, in: workspace.environments)
        tab.persistedSelectedEnvironmentID = environment?.id
        if let environment {
            workspace.activeEnvironmentID = environment.id
        }
        persistDraft(for: tab, syncNow: true)
    }

    /// Nombre del entorno cuyas variables se usan al ejecutar esta pestaña (selección de la pestaña o, si es `nil`, el activo del workspace).
    public func executionEnvironmentDisplayName(for tab: RequestTabState) -> String {
        environmentCoordinator.executionDisplayName(
            for: tab,
            environments: workspace.environments,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
    }

    /// Misma semántica que el `Picker` de entorno en Mac: al cambiar, actualiza variables en memoria y el entorno activo del workspace.
    public func environmentPickerBinding(for tab: RequestTabState) -> Binding<UUID?> {
        Binding(
            get: {
                let selectedID = tab.selectedEnvironmentID ?? self.workspace.activeEnvironmentID
                guard let selectedID else { return nil }
                return self.workspace.environments.contains(where: { $0.id == selectedID }) ? selectedID : nil
            },
            set: { newValue in
                let environment = newValue.flatMap { id in self.workspace.environments.first(where: { $0.id == id }) }
                self.selectEnvironment(environment, for: tab)
            }
        )
    }

    public func revertPendingEnvironmentChanges(for tab: RequestTabState) {
        let environmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID
        let currentEnvironmentVariablesBeforeRevert = environmentCoordinator.variables(for: environmentID, in: workspace.environments)

        tab.pendingEnvironmentVariables = tab.persistedEnvironmentVariables

        if let environmentID,
           let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID }) {
            let revertedEnvironmentVariables = tab.persistedEnvironmentVariables ?? []
            workspace.environments[environmentIndex].variables = revertedEnvironmentVariables
            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environmentID,
                previousVariables: currentEnvironmentVariablesBeforeRevert,
                updatedVariables: revertedEnvironmentVariables,
                excluding: tab.id
            )
        }

        persistDraft(for: tab, syncNow: true)
    }

    /// Crea un entorno nuevo copiando variables (y `isEnabled`) del perfil dado. El nombre se recorta; vacío usa nombre sugerido único.
    @discardableResult
    public func duplicateEnvironment(_ profile: EnvironmentProfile, named rawName: String) -> EnvironmentProfile {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? suggestedEnvironmentCloneName(for: profile)
            : environmentCoordinator.makeUniqueName(
                baseName: trimmed,
                existingNames: Set(workspace.environments.map { $0.name.lowercased() })
            )
        let variables = profile.variables.map { VariableValue(key: $0.key, value: $0.value, isEnabled: $0.isEnabled) }
        let copy = EnvironmentProfile(name: name, variables: variables, isEnabled: profile.isEnabled)
        workspace.environments.append(copy)
        persistWorkspace(
            syncSharedCollections: false,
            syncSharedEnvironments: true,
            syncSharedFlows: false,
            syncSharedUtilities: false
        )
        infoMessage = "Entorno '\(name)' clonado."
        return copy
    }

    private func environment(for tab: RequestTabState) -> EnvironmentProfile? {
        environmentCoordinator.profile(
            for: tab,
            environments: workspace.environments,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
    }

    func refreshTabEnvironmentSnapshotFromWorkspace(for tab: RequestTabState) {
        let baseline = savedEnvironmentBaseline(for: tab)
        environmentCoordinator.refreshTabSnapshot(
            tab,
            environments: workspace.environments,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
        tab.persistedEnvironmentVariables = baseline
    }

    func savedEnvironmentBaseline(for tab: RequestTabState) -> [VariableValue]? {
        environmentCoordinator.variables(
            for: tab.persistedSelectedEnvironmentID ?? tab.selectedEnvironmentID ?? workspace.activeEnvironmentID,
            in: persistedSharedEnvironments
        ) ?? tab.persistedEnvironmentVariables
    }

    /// Resuelve `{{clave}}` con globales, variables de colección, entorno del tab y variables locales (sin scripts pre-request).
    public func resolveTemplatePlaceholders(_ template: String, for tab: RequestTabState) -> String {
        let collection = collection(for: tab)
        let context = VariableResolutionContext(
            globals: workspace.globalVariables,
            collection: collection?.variables ?? [],
            environment: environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments),
            local: tab.request.localVariables
        )
        return VariableResolver().resolve(template, context: context, expressionEvaluator: nil)
    }

    /// Plantilla `APIRequestModel.awsAccessPortalURLTemplate` ya sustituida y recortada.
    public func resolvedAWSAccessPortalURL(for tab: RequestTabState) -> String {
        // Igual que antes de enviar: alinear variables del tab con el workspace (evita `{{}}` sin resolver en iPad).
        refreshTabEnvironmentSnapshotFromWorkspace(for: tab)
        return resolveTemplatePlaceholders(tab.request.awsAccessPortalURLTemplate, for: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sincroniza globales, variables de colección y entornos desde disco (como antes de **Send**) y refresca el snapshot del tab.
    /// Úsalo antes de abrir el portal AWS para que `{{variable}}` refleje el último estado guardado en el repo.
    public func synchronizeVariableStoresBeforePortalAWS(for tab: RequestTabState) async {
        guard await refreshPersistedVariableStoresFromDisk() else { return }
        refreshTabEnvironmentSnapshotFromWorkspace(for: tab)
    }

    func ensureEnvironmentExistsIfRequired(for tab: RequestTabState, collection: CollectionModel?, request: APIRequestModel) {
        guard environment(for: tab) == nil else {
            return
        }

        guard requestUsesEnvironmentScripting(request) || requestUsesEnvironmentPlaceholders(request) else {
            return
        }

        let environmentName: String
        if let collection {
            environmentName = collection.info.name
        } else {
            environmentName = "Local"
        }

        let environment = EnvironmentProfile(name: environmentName)
        workspace.environments.append(environment)
        workspace.activeEnvironmentID = environment.id
        tab.selectedEnvironmentID = environment.id
        tab.pendingEnvironmentVariables = environment.variables
        tab.persistedEnvironmentVariables = environment.variables
        persistWorkspace(syncSharedData: false)
    }

    private func updateCollectionVariables(for tab: RequestTabState, variables: [VariableValue]) {
        guard let collectionID = tab.sourceCollectionID,
              let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }
        workspace.collections[index].variables = environmentCoordinator.merge(existing: workspace.collections[index].variables, with: variables)
    }

    private func updateCollectionVariables(forCollectionID collectionID: UUID, variables: [VariableValue]) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else {
            return
        }
        workspace.collections[index].variables = environmentCoordinator.merge(existing: workspace.collections[index].variables, with: variables)
    }

    private func updateEnvironmentVariables(_ variables: [VariableValue], for tab: RequestTabState) {
        guard let environmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID else {
            return
        }
        let base = environmentCoordinator.effectiveVariables(pending: tab.pendingEnvironmentVariables, selectedEnvironmentID: tab.selectedEnvironmentID, activeEnvironmentID: workspace.activeEnvironmentID, environments: workspace.environments)
        let mergedVariables = environmentCoordinator.merge(existing: base, with: variables)
        let previousVariables = environmentCoordinator.variables(for: environmentID, in: workspace.environments)

        tab.pendingEnvironmentVariables = mergedVariables

        if let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID }) {
            workspace.environments[environmentIndex].variables = mergedVariables
        }

        synchronizeOpenTabsForLocalEnvironmentChange(
            environmentID: environmentID,
            previousVariables: previousVariables,
            updatedVariables: mergedVariables,
            excluding: tab.id
        )

        persistDraft(for: tab, syncNow: true)
    }

    func applyExecutionVariableUpdates(
        to tab: RequestTabState,
        updatedGlobals: [VariableValue],
        updatedCollection: [VariableValue],
        updatedEnvironment: [VariableValue],
        updatedEnvironments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        updatedLocal: [KeyValueEntry]
    ) {
        tab.request.localVariables = updatedLocal
        workspace.globalVariables = environmentCoordinator.merge(existing: workspace.globalVariables, with: updatedGlobals)
        updateCollectionVariables(for: tab, variables: updatedCollection)
        if applyRuntimeEnvironmentChanges(
            updatedEnvironments: updatedEnvironments,
            activeEnvironmentID: activeEnvironmentID,
            sourceTab: tab,
            persistSideEffects: true
        ) {
            if updatedEnvironment.isEmpty,
               let resolvedEnvironmentID = tab.selectedEnvironmentID ?? workspace.activeEnvironmentID {
                tab.pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
            } else {
                updateEnvironmentVariables(updatedEnvironment, for: tab)
            }
        } else {
            updateEnvironmentVariables(updatedEnvironment, for: tab)
        }
    }

    /// Merges flow execution outcomes into the live `workspace` for UI and in-memory continuity.
    /// - Parameter persistToDisk: `false` while running a workspace flow: no `persistWorkspace` and no tab draft sync from this path (requests + explicit batch preflight own persistence).
    func applyFlowExecutionVariableUpdates(_ result: WorkspaceFlowExecutionResult, persistToDisk: Bool = true) {
        workspace.globalVariables = environmentCoordinator.merge(existing: workspace.globalVariables, with: result.updatedGlobals)

        for collectionUpdate in result.updatedCollections {
            updateCollectionVariables(forCollectionID: collectionUpdate.collectionID, variables: collectionUpdate.variables)
        }

        if applyRuntimeEnvironmentChanges(
            updatedEnvironments: result.updatedEnvironments,
            activeEnvironmentID: result.activeEnvironmentID,
            sourceTab: nil,
            persistSideEffects: persistToDisk
        ) {
            if result.updatedEnvironment.isEmpty {
                if persistToDisk {
                    persistWorkspace(syncSharedData: false)
                }
                return
            }
        }

        if let environmentID = workspace.activeEnvironmentID {
            let previousVariables = environmentCoordinator.variables(for: environmentID, in: workspace.environments)
            let mergedEnvironment = environmentCoordinator.merge(existing: previousVariables ?? [], with: result.updatedEnvironment)

            if let environmentIndex = workspace.environments.firstIndex(where: { $0.id == environmentID }) {
                workspace.environments[environmentIndex].variables = mergedEnvironment
            }

            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environmentID,
                previousVariables: previousVariables,
                updatedVariables: mergedEnvironment,
                excluding: UUID()
            )
        }

        if persistToDisk {
            persistWorkspace(syncSharedData: false)
        }
    }

    @discardableResult
    private func applyRuntimeEnvironmentChanges(
        updatedEnvironments: [EnvironmentProfile],
        activeEnvironmentID: UUID?,
        sourceTab: RequestTabState?,
        persistSideEffects: Bool = true
    ) -> Bool {
        guard !updatedEnvironments.isEmpty || activeEnvironmentID != nil else {
            return false
        }

        let previousActiveEnvironmentID = workspace.activeEnvironmentID
        let previousVariablesByEnvironmentID = Dictionary(uniqueKeysWithValues: workspace.environments.map { ($0.id, $0.variables) })

        if !updatedEnvironments.isEmpty {
            workspace.environments = updatedEnvironments
        }

        if let activeEnvironmentID,
           workspace.environments.contains(where: { $0.id == activeEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = activeEnvironmentID
        } else if let currentActiveEnvironmentID = workspace.activeEnvironmentID,
                  workspace.environments.contains(where: { $0.id == currentActiveEnvironmentID && $0.isEnabled }) {
            workspace.activeEnvironmentID = currentActiveEnvironmentID
        } else {
            workspace.activeEnvironmentID = workspace.environments.first(where: \.isEnabled)?.id
        }

        for environment in workspace.environments {
            let previousVariables = previousVariablesByEnvironmentID[environment.id]
            guard previousVariables != environment.variables else {
                continue
            }

            synchronizeOpenTabsForLocalEnvironmentChange(
                environmentID: environment.id,
                previousVariables: previousVariables,
                updatedVariables: environment.variables,
                excluding: sourceTab?.id ?? UUID()
            )
        }

        for index in tabs.indices {
            let currentSelection = tabs[index].selectedEnvironmentID ?? previousActiveEnvironmentID

            if let explicitSelection = tabs[index].selectedEnvironmentID,
               !workspace.environments.contains(where: { $0.id == explicitSelection }) {
                tabs[index].selectedEnvironmentID = nil
            }

            if tabs[index].id == sourceTab?.id,
               let activeEnvironmentID = workspace.activeEnvironmentID {
                tabs[index].selectedEnvironmentID = activeEnvironmentID
            }

            let resolvedEnvironmentID = tabs[index].selectedEnvironmentID
                ?? (currentSelection != previousActiveEnvironmentID ? currentSelection : workspace.activeEnvironmentID)
                ?? workspace.activeEnvironmentID
            tabs[index].pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
            if persistSideEffects {
                persistDraft(for: tabs[index], syncNow: true)
            }
        }

        for draftIndex in workspace.requestDrafts.indices {
            if let explicitSelection = workspace.requestDrafts[draftIndex].selectedEnvironmentID,
               !workspace.environments.contains(where: { $0.id == explicitSelection }) {
                workspace.requestDrafts[draftIndex].selectedEnvironmentID = nil
            }

            if workspace.requestDrafts[draftIndex].tabID == sourceTab?.id {
                workspace.requestDrafts[draftIndex].selectedEnvironmentID = workspace.activeEnvironmentID
            }

            let resolvedEnvironmentID = workspace.requestDrafts[draftIndex].selectedEnvironmentID
                ?? workspace.activeEnvironmentID
            workspace.requestDrafts[draftIndex].pendingEnvironmentVariables = environmentCoordinator.variables(for: resolvedEnvironmentID, in: workspace.environments)
        }

        return true
    }

    func synchronizeOpenTabsForLocalEnvironmentChange(
        environmentID: UUID,
        previousVariables: [VariableValue]?,
        updatedVariables: [VariableValue],
        excluding excludedTabID: UUID
    ) {
        let tabBaselines = tabs.map { ($0, $0.persistedEnvironmentVariables) }
        var drafts = workspace.requestDrafts
        let draftBaselines = drafts.map(\.persistedEnvironmentVariables)
        environmentCoordinator.synchronizeOpenTabs(
            environmentID: environmentID,
            previousVariables: previousVariables,
            updatedVariables: updatedVariables,
            excluding: excludedTabID,
            tabs: tabs,
            drafts: &drafts,
            activeEnvironmentID: workspace.activeEnvironmentID
        )
        for (tab, baseline) in tabBaselines { tab.persistedEnvironmentVariables = baseline }
        for index in drafts.indices where index < draftBaselines.count {
            drafts[index].persistedEnvironmentVariables = draftBaselines[index]
        }
        workspace.requestDrafts = drafts
    }

    func synchronizePersistedEnvironmentBaseline(environmentID: UUID, variables: [VariableValue]) {
        var drafts = workspace.requestDrafts
        environmentCoordinator.synchronizePersistedBaseline(
            environmentID: environmentID,
            variables: variables,
            tabs: tabs,
            drafts: &drafts,
            activeEnvironmentID: workspace.activeEnvironmentID,
            environments: workspace.environments
        )
        workspace.requestDrafts = drafts
    }

    private func requestUsesEnvironmentScripting(_ request: APIRequestModel) -> Bool {
        request.scripts.contains { script in
            let source = script.source.lowercased()
            return source.contains("pm.environment")
                || source.contains("postman.setenvironmentvariable")
                || source.contains("postman.getenvironmentvariable")
                || source.contains("postman.clearenvironmentvariable")
        }
    }

    private func requestUsesEnvironmentPlaceholders(_ request: APIRequestModel) -> Bool {
        let candidates = [
            request.url,
            request.body.raw,
            request.auth.username,
            request.auth.password,
            request.auth.token,
            request.auth.key,
            request.auth.value,
            request.auth.accessTokenURL,
            request.auth.clientID,
            request.auth.clientSecret,
            request.auth.scopes,
        ] + request.headers.map(\.value)
          + request.cookies.map(\.value)
          + request.queryItems.map(\.value)
          + request.pathVariables.map(\.value)
          + request.localVariables.map(\.value)
          + request.body.parameters.map(\.value)

        return candidates.contains { $0.contains("{{") && $0.contains("}}") }
    }

    func upsertEnvironment(_ importedEnvironment: EnvironmentProfile) {
        var environments = workspace.environments
        var activeEnvironmentID = workspace.activeEnvironmentID
        environmentCoordinator.upsertImported(
            importedEnvironment,
            into: &environments,
            activeEnvironmentID: &activeEnvironmentID
        )
        workspace.environments = environments
        workspace.activeEnvironmentID = activeEnvironmentID
        sanitizeEnvironmentSelections()
    }

    func sanitizeEnvironmentSelections() {
        var activeEnvironmentID = workspace.activeEnvironmentID
        var drafts = workspace.requestDrafts
        environmentCoordinator.sanitizeSelections(
            environments: workspace.environments,
            activeEnvironmentID: &activeEnvironmentID,
            tabs: tabs,
            drafts: &drafts
        )
        workspace.activeEnvironmentID = activeEnvironmentID
        workspace.requestDrafts = drafts
    }
}
