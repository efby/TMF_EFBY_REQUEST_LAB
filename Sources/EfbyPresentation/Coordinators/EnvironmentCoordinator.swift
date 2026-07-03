import EfbyDomain
import Foundation

/// Coordina lectura, fusión y sincronización de perfiles de entorno con tabs y drafts.
@MainActor
public final class EnvironmentCoordinator {
    public init() {}

    public func variables(for environmentID: UUID?, in environments: [EnvironmentProfile]) -> [VariableValue]? {
        guard let environmentID else { return nil }
        if let enabled = environments.first(where: { $0.id == environmentID && $0.isEnabled }) {
            return enabled.variables
        }
        return environments.first(where: { $0.id == environmentID })?.variables
    }

    public func effectiveVariables(
        pending: [VariableValue]?,
        selectedEnvironmentID: UUID?,
        activeEnvironmentID: UUID?,
        environments: [EnvironmentProfile]
    ) -> [VariableValue] {
        if let pending, !pending.isEmpty {
            return pending
        }
        return variables(for: selectedEnvironmentID ?? activeEnvironmentID, in: environments) ?? []
    }

    public func profile(for tab: RequestTabState, environments: [EnvironmentProfile], activeEnvironmentID: UUID?) -> EnvironmentProfile? {
        guard let environmentID = tab.selectedEnvironmentID ?? activeEnvironmentID else {
            return nil
        }
        return environments.first(where: { $0.id == environmentID && $0.isEnabled })
    }

    public func executionDisplayName(
        for tab: RequestTabState,
        environments: [EnvironmentProfile],
        activeEnvironmentID: UUID?
    ) -> String {
        let id = tab.selectedEnvironmentID ?? activeEnvironmentID
        guard let id,
              let env = environments.first(where: { $0.id == id }) else {
            return "—"
        }
        return env.name
    }

    public func variablesEquivalent(_ lhs: [VariableValue]?, _ rhs: [VariableValue]?) -> Bool {
        normalizedVariables(lhs) == normalizedVariables(rhs)
    }

    public func normalizedProfiles(_ environments: [EnvironmentProfile]) -> [EnvironmentProfile] {
        environments.map { environment in
            EnvironmentProfile(
                id: environment.id,
                name: environment.name,
                variables: normalizedVariables(environment.variables) ?? [],
                isEnabled: environment.isEnabled
            )
        }
        .sorted { lhs, rhs in
            if lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func merge(existing: [VariableValue], with updates: [VariableValue]) -> [VariableValue] {
        var merged: [String: VariableValue] = [:]

        for variable in existing {
            merged[variable.key] = variable
        }

        updates.forEach { update in
            if var current = merged[update.key] {
                current.value = update.value
                current.isEnabled = update.isEnabled
                merged[update.key] = current
            } else {
                merged[update.key] = update
            }
        }
        return merged.values.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    public func makeUniqueName(baseName: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }

        var index = 2
        while existingNames.contains("\(baseName) \(index)".lowercased()) {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    public func suggestedCloneName(for profile: EnvironmentProfile, existingNames: Set<String>) -> String {
        makeUniqueName(baseName: "\(profile.name) Copy", existingNames: existingNames)
    }

    public func upsertImported(
        _ importedEnvironment: EnvironmentProfile,
        into environments: inout [EnvironmentProfile],
        activeEnvironmentID: inout UUID?
    ) {
        if let existingIndex = environments.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(importedEnvironment.name) == .orderedSame
        }) {
            var replacement = importedEnvironment
            replacement.id = environments[existingIndex].id
            replacement.isEnabled = environments[existingIndex].isEnabled
            environments[existingIndex] = replacement
            activeEnvironmentID = replacement.id
        } else {
            environments.append(importedEnvironment)
            activeEnvironmentID = importedEnvironment.id
        }
    }

    public func sanitizeSelections(
        environments: [EnvironmentProfile],
        activeEnvironmentID: inout UUID?,
        tabs: [RequestTabState],
        drafts: inout [RequestDraftState]
    ) {
        let validIDs = Set(environments.map(\.id))

        if let currentActiveEnvironmentID = activeEnvironmentID,
           !validIDs.contains(currentActiveEnvironmentID) {
            activeEnvironmentID = environments.first(where: \.isEnabled)?.id
        }

        tabs.forEach { tab in
            if let selectedEnvironmentID = tab.selectedEnvironmentID,
               !validIDs.contains(selectedEnvironmentID) {
                tab.selectedEnvironmentID = nil
                tab.pendingEnvironmentVariables = nil
            }
            if let persistedSelectedEnvironmentID = tab.persistedSelectedEnvironmentID,
               !validIDs.contains(persistedSelectedEnvironmentID) {
                tab.persistedSelectedEnvironmentID = nil
                tab.persistedEnvironmentVariables = nil
            }
        }

        drafts = drafts.map { draft in
            var updated = draft
            if let selectedEnvironmentID = updated.selectedEnvironmentID,
               !validIDs.contains(selectedEnvironmentID) {
                updated.selectedEnvironmentID = nil
                updated.pendingEnvironmentVariables = nil
            }
            if let persistedSelectedEnvironmentID = updated.persistedSelectedEnvironmentID,
               !validIDs.contains(persistedSelectedEnvironmentID) {
                updated.persistedSelectedEnvironmentID = nil
                updated.persistedEnvironmentVariables = nil
            }
            return updated
        }
    }

    public func clearReferences(
        to environmentID: UUID,
        tabs: [RequestTabState],
        drafts: inout [RequestDraftState]
    ) {
        tabs.forEach { tab in
            if tab.selectedEnvironmentID == environmentID {
                tab.selectedEnvironmentID = nil
                tab.pendingEnvironmentVariables = nil
            }
            if tab.persistedSelectedEnvironmentID == environmentID {
                tab.persistedSelectedEnvironmentID = nil
                tab.persistedEnvironmentVariables = nil
            }
        }

        drafts = drafts.map { draft in
            var updated = draft
            if updated.selectedEnvironmentID == environmentID {
                updated.selectedEnvironmentID = nil
                updated.pendingEnvironmentVariables = nil
            }
            if updated.persistedSelectedEnvironmentID == environmentID {
                updated.persistedSelectedEnvironmentID = nil
                updated.persistedEnvironmentVariables = nil
            }
            return updated
        }
    }

    public func synchronizeOpenTabs(
        environmentID: UUID,
        previousVariables: [VariableValue]?,
        updatedVariables: [VariableValue],
        excluding excludedTabID: UUID,
        tabs: [RequestTabState],
        drafts: inout [RequestDraftState],
        activeEnvironmentID: UUID?
    ) {
        for siblingTab in tabs where siblingTab.id != excludedTabID {
            let siblingEnvironmentID = siblingTab.selectedEnvironmentID ?? activeEnvironmentID
            guard siblingEnvironmentID == environmentID else {
                continue
            }

            siblingTab.pendingEnvironmentVariables = synchronizedVariables(
                current: siblingTab.pendingEnvironmentVariables,
                previous: previousVariables,
                updated: updatedVariables
            )
            siblingTab.persistedEnvironmentVariables = synchronizedVariables(
                current: siblingTab.persistedEnvironmentVariables,
                previous: previousVariables,
                updated: updatedVariables
            )
        }

        for draftIndex in drafts.indices {
            let draftEnvironmentID = drafts[draftIndex].selectedEnvironmentID
                ?? drafts[draftIndex].persistedSelectedEnvironmentID
                ?? activeEnvironmentID
            guard draftEnvironmentID == environmentID else {
                continue
            }

            drafts[draftIndex].pendingEnvironmentVariables = synchronizedVariables(
                current: drafts[draftIndex].pendingEnvironmentVariables,
                previous: previousVariables,
                updated: updatedVariables
            )
            drafts[draftIndex].persistedEnvironmentVariables = synchronizedVariables(
                current: drafts[draftIndex].persistedEnvironmentVariables,
                previous: previousVariables,
                updated: updatedVariables
            )
        }
    }

    public func synchronizePersistedBaseline(
        environmentID: UUID,
        variables: [VariableValue],
        tabs: [RequestTabState],
        drafts: inout [RequestDraftState],
        activeEnvironmentID: UUID?,
        environments: [EnvironmentProfile]
    ) {
        for tab in tabs {
            let tabEnvironmentID = tab.selectedEnvironmentID ?? activeEnvironmentID
            guard tabEnvironmentID == environmentID else {
                continue
            }
            tab.persistedEnvironmentVariables = variables
            if variablesEquivalent(tab.pendingEnvironmentVariables, self.variables(for: environmentID, in: environments)) {
                tab.pendingEnvironmentVariables = variables
            }
        }

        drafts = drafts.map { draft in
            var updated = draft
            let draftEnvironmentID = draft.selectedEnvironmentID ?? activeEnvironmentID
            if draftEnvironmentID == environmentID {
                updated.persistedEnvironmentVariables = variables
            }
            return updated
        }
    }

    public func refreshTabSnapshot(
        _ tab: RequestTabState,
        environments: [EnvironmentProfile],
        activeEnvironmentID: UUID?
    ) {
        let selectedEnvironmentID = tab.selectedEnvironmentID ?? activeEnvironmentID
        let persistedSelectedEnvironmentID = tab.persistedSelectedEnvironmentID
            ?? selectedEnvironmentID
            ?? activeEnvironmentID

        tab.pendingEnvironmentVariables = variables(for: selectedEnvironmentID, in: environments)
        tab.persistedSelectedEnvironmentID = persistedSelectedEnvironmentID
        tab.persistedEnvironmentVariables = variables(for: persistedSelectedEnvironmentID, in: environments)
    }

    public func topLevelKeysFromFlowBatchParametersJSON(_ json: String) -> Set<String> {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? "{}" : trimmed
        guard let data = payload.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dictionary = jsonObject as? [String: Any] else {
            return []
        }
        var keys = Set<String>()
        for rawKey in dictionary.keys {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                keys.insert(key)
            }
        }
        return keys
    }

    public func parseFlowBatchParameterUpdates(from json: String) throws -> [VariableValue] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? "{}" : trimmed
        guard let data = payload.data(using: .utf8) else {
            throw AppError.invalidDocument("Los parámetros del run deben ser texto UTF-8.")
        }
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dictionary = jsonObject as? [String: Any] else {
            throw AppError.invalidDocument("El JSON del run debe ser un objeto en la raíz, por ejemplo {\"clave\":\"valor\"}.")
        }

        var updates: [VariableValue] = []
        updates.reserveCapacity(dictionary.count)
        for (key, value) in dictionary.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            updates.append(
                VariableValue(
                    key: trimmedKey,
                    value: stringValueForFlowBatchEnvironment(from: value),
                    isEnabled: true
                )
            )
        }
        return updates
    }

    public func stringValueForFlowBatchEnvironment(from value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let int64 as Int64:
            return String(int64)
        case let double as Double:
            return String(double)
        case let number as NSNumber:
            return number.stringValue
        case is NSNull:
            return ""
        default:
            if JSONSerialization.isValidJSONObject(value),
               let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let string = String(data: encoded, encoding: .utf8) {
                return string
            }
            return String(describing: value)
        }
    }

    private func synchronizedVariables(
        current: [VariableValue]?,
        previous: [VariableValue]?,
        updated: [VariableValue]
    ) -> [VariableValue] {
        if variablesEquivalent(current, previous) {
            return updated
        }
        if let current {
            return merge(existing: current, with: updated)
        }
        return updated
    }

    private func normalizedVariables(_ variables: [VariableValue]?) -> [VariableValue]? {
        variables?.map { variable in
            VariableValue(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
                key: variable.key,
                value: variable.value,
                isEnabled: variable.isEnabled
            )
        }
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
}
