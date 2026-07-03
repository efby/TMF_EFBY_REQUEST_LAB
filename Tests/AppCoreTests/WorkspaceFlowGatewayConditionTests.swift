import EfbyPresentation
import XCTest

final class WorkspaceFlowGatewayConditionTests: XCTestCase {
    func testResponseStatusEqualsAnyCode() {
        let ctx = WorkspaceFlowGatewayConditionContext(lastStatusCode: 429)
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode == 429", context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode == 200", context: ctx))
    }

    func testResponseStatusNotEqualsAnyCode() {
        let ctx = WorkspaceFlowGatewayConditionContext(lastStatusCode: 200)
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode != 500", context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode != 200", context: ctx))
    }

    func testResponseStatusInListWithQuotes() {
        let ctx = WorkspaceFlowGatewayConditionContext(lastStatusCode: 403)
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue(#"response.statusCode IN ["200", "403"]"#, context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode IN [200, 201]", context: ctx))
    }

    func testResponseStatusNotInList() {
        let ok = WorkspaceFlowGatewayConditionContext(lastStatusCode: 200)
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode NOT IN [200, 403]", context: ok))

        let other = WorkspaceFlowGatewayConditionContext(lastStatusCode: 500)
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode NOT IN [200, 403]", context: other))
    }

    func testResponseStatusConditionsFalseWhenNoResponseYet() {
        let ctx = WorkspaceFlowGatewayConditionContext(lastStatusCode: nil)
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode == 200", context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode IN [200]", context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("response.statusCode NOT IN [200]", context: ctx))
    }

    func testCaseInsensitiveResponseKeyword() {
        let ctx = WorkspaceFlowGatewayConditionContext(lastStatusCode: 201)
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("Response.StatusCode IN [200, 201]", context: ctx))
    }

    func testEnvironmentComparisonStillWorks() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["region": "eu-west"],
            globals: [:]
        )
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("environment.region == 'eu-west'", context: ctx))
    }

    func testEnvironmentVariableInList() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["tipoflujo": "visa"],
            globals: [:]
        )
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("environment.tipoflujo IN ['visa', 'mastercard']", context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("environment.tipoflujo IN ['amex', 'mc']", context: ctx))
    }

    func testEnvironmentVariableNotInList() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["tipoflujo": "sandbox"],
            globals: [:]
        )
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("environment.tipoflujo NOT IN ['prod', 'staging']", context: ctx))
        XCTAssertFalse(WorkspaceFlowGatewayCondition.evaluatesToTrue("environment.tipoflujo NOT IN ['sandbox', 'dev']", context: ctx))
    }

    func testGlobalsInList() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: [:],
            globals: ["mode": "dry-run"]
        )
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("globals.mode IN ['dry-run', 'full']", context: ctx))
    }

    func testEnvironmentContainsSubstring_spaceForm() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["transaccionTipo": "billeteraBancoestadoSinCaptura"],
            globals: [:]
        )
        XCTAssertTrue(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo contains('billetera')",
                context: ctx
            )
        )
        XCTAssertFalse(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo contains('amex')",
                context: ctx
            )
        )
    }

    func testEnvironmentContainsSubstring_dotForm() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["transaccionTipo": "bancoTarjetaCreditoConCaptura"],
            globals: [:]
        )
        XCTAssertTrue(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                #"environment.transaccionTipo.contains("Credito")"#,
                context: ctx
            )
        )
    }

    func testGlobalsContainsSubstring() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: [:],
            globals: ["path": "/api/v2/checkout"]
        )
        XCTAssertTrue(WorkspaceFlowGatewayCondition.evaluatesToTrue("globals.path contains('checkout')", context: ctx))
    }

    func testContainsMissingKeyIsFalse() {
        let ctx = WorkspaceFlowGatewayConditionContext(environment: [:], globals: [:])
        XCTAssertFalse(
            WorkspaceFlowGatewayCondition.evaluatesToTrue("environment.missing contains('x')", context: ctx)
        )
    }

    func testEnvironmentNotContains_spaceForm() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["transaccionTipo": "bancoTarjetaCreditoConCaptura"],
            globals: [:]
        )
        XCTAssertTrue(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo not contains('billetera')",
                context: ctx
            )
        )
        XCTAssertFalse(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo not contains('Credito')",
                context: ctx
            )
        )
    }

    func testEnvironmentNotContains_dotNotContainsForm() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["transaccionTipo": "billeteraBancoestadoSinCaptura"],
            globals: [:]
        )
        XCTAssertFalse(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo.notContains('billetera')",
                context: ctx
            )
        )
        XCTAssertTrue(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo.notContains('amex')",
                context: ctx
            )
        )
    }

    func testEnvironmentDoesNotContain_longForm() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["path": "/api/v1/ping"],
            globals: [:]
        )
        XCTAssertTrue(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.path does not contain('checkout')",
                context: ctx
            )
        )
        XCTAssertFalse(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.path does not contain('api')",
                context: ctx
            )
        )
    }

    func testNotContainsParsesKeyCorrectly_notMisreadAsPositiveContains() {
        let ctx = WorkspaceFlowGatewayConditionContext(
            environment: ["transaccionTipo": "visa"],
            globals: [:]
        )
        XCTAssertTrue(
            WorkspaceFlowGatewayCondition.evaluatesToTrue(
                "environment.transaccionTipo not contains('billetera')",
                context: ctx
            )
        )
    }
}
