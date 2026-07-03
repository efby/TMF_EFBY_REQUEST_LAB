import EfbyDomain
import EfbyPresentation
import XCTest

@MainActor
final class EnvironmentCoordinatorTests: XCTestCase {
    private let coordinator = EnvironmentCoordinator()

    func testVariablesPrefersEnabledProfile() {
        let enabledID = UUID()
        let disabledID = UUID()
        let environments = [
            EnvironmentProfile(id: enabledID, name: "Prod", variables: [VariableValue(key: "a", value: "1")], isEnabled: true),
            EnvironmentProfile(id: disabledID, name: "Off", variables: [VariableValue(key: "b", value: "2")], isEnabled: false),
        ]

        XCTAssertEqual(coordinator.variables(for: enabledID, in: environments)?.map(\.key), ["a"])
        XCTAssertEqual(coordinator.variables(for: disabledID, in: environments)?.map(\.key), ["b"])
        XCTAssertNil(coordinator.variables(for: nil, in: environments))
    }

    func testEffectiveVariablesUsesPendingWhenNonEmpty() {
        let environmentID = UUID()
        let environments = [
            EnvironmentProfile(id: environmentID, name: "Env", variables: [VariableValue(key: "disk", value: "1")]),
        ]
        let pending = [VariableValue(key: "pending", value: "2")]

        let effective = coordinator.effectiveVariables(
            pending: pending,
            selectedEnvironmentID: environmentID,
            activeEnvironmentID: environmentID,
            environments: environments
        )
        XCTAssertEqual(effective.map(\.key), ["pending"])
    }

    func testEffectiveVariablesFallsBackWhenPendingEmpty() {
        let environmentID = UUID()
        let environments = [
            EnvironmentProfile(id: environmentID, name: "Env", variables: [VariableValue(key: "disk", value: "1")]),
        ]

        let effective = coordinator.effectiveVariables(
            pending: [],
            selectedEnvironmentID: environmentID,
            activeEnvironmentID: nil,
            environments: environments
        )
        XCTAssertEqual(effective.map(\.key), ["disk"])
    }

    func testMergeUpdatesExistingAndAddsMissingKeys() {
        let existing = [
            VariableValue(key: "a", value: "1", isEnabled: true),
            VariableValue(key: "b", value: "2", isEnabled: true),
        ]
        let updates = [
            VariableValue(key: "b", value: "9", isEnabled: false),
            VariableValue(key: "c", value: "3", isEnabled: true),
        ]

        let merged = coordinator.merge(existing: existing, with: updates)
        XCTAssertEqual(merged.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(merged.first(where: { $0.key == "b" })?.value, "9")
        XCTAssertEqual(merged.first(where: { $0.key == "b" })?.isEnabled, false)
    }

    func testUpsertImportedReusesIdByName() {
        let existingID = UUID()
        var environments = [EnvironmentProfile(id: existingID, name: "Local", variables: [], isEnabled: true)]
        var activeID: UUID? = existingID
        let imported = EnvironmentProfile(name: "local", variables: [VariableValue(key: "x", value: "1")])

        coordinator.upsertImported(imported, into: &environments, activeEnvironmentID: &activeID)

        XCTAssertEqual(environments.count, 1)
        XCTAssertEqual(environments[0].id, existingID)
        XCTAssertEqual(environments[0].variables.map(\.key), ["x"])
        XCTAssertEqual(activeID, existingID)
    }

    func testSanitizeSelectionsClearsInvalidReferences() {
        let validID = UUID()
        let invalidID = UUID()
        let environments = [EnvironmentProfile(id: validID, name: "Ok")]
        var activeID: UUID? = invalidID
        let tab = RequestTabState(
            request: APIRequestModel(name: "R", method: .get, url: "https://example.com"),
            selectedEnvironmentID: invalidID,
            pendingEnvironmentVariables: [VariableValue(key: "a", value: "1")],
            persistedSelectedEnvironmentID: invalidID,
            persistedEnvironmentVariables: [VariableValue(key: "a", value: "1")]
        )
        var drafts = [
            RequestDraftState(
                workspaceName: "default",
                tabID: tab.id,
                request: tab.request,
                selectedEnvironmentID: invalidID,
                pendingEnvironmentVariables: [VariableValue(key: "a", value: "1")],
                persistedSelectedEnvironmentID: invalidID,
                persistedEnvironmentVariables: [VariableValue(key: "a", value: "1")]
            ),
        ]

        coordinator.sanitizeSelections(
            environments: environments,
            activeEnvironmentID: &activeID,
            tabs: [tab],
            drafts: &drafts
        )

        XCTAssertEqual(activeID, validID)
        XCTAssertNil(tab.selectedEnvironmentID)
        XCTAssertNil(tab.pendingEnvironmentVariables)
        XCTAssertNil(drafts[0].selectedEnvironmentID)
    }

    func testTopLevelKeysFromFlowBatchParametersJSON() {
        let keys = coordinator.topLevelKeysFromFlowBatchParametersJSON(#"{ "alpha": 1, " beta ": "x", "": "skip" }"#)
        XCTAssertEqual(keys, ["alpha", "beta"])
    }

    func testParseFlowBatchParameterUpdates() throws {
        let updates = try coordinator.parseFlowBatchParameterUpdates(from: #"{"flag":true,"n":2}"#)
        XCTAssertEqual(updates.map(\.key), ["flag", "n"])
        XCTAssertEqual(updates.first(where: { $0.key == "flag" })?.value, "true")
        XCTAssertEqual(updates.first(where: { $0.key == "n" })?.value, "2")
    }

    func testMakeUniqueNameAvoidsCollisions() {
        let names: Set<String> = ["env", "env 2"]
        XCTAssertEqual(coordinator.makeUniqueName(baseName: "Env", existingNames: names), "Env 3")
    }
}
