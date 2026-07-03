import EfbyPresentation
import XCTest

final class VariableResolverTests: XCTestCase {
    func testVariableResolutionRespectsPrecedence() {
        let resolver = VariableResolver()
        let context = VariableResolutionContext(
            globals: [VariableValue(key: "host", value: "global.example.com")],
            collection: [VariableValue(key: "host", value: "collection.example.com")],
            environment: [VariableValue(key: "host", value: "env.example.com")],
            local: [KeyValueEntry(key: "host", value: "local.example.com")]
        )

        let resolved = resolver.resolve("https://{{host}}/ping", context: context)

        XCTAssertEqual(resolved, "https://local.example.com/ping")
    }

    func testMissingVariableIsLeftUntouched() {
        let resolver = VariableResolver()
        let resolved = resolver.resolve("https://{{missing}}/ping", context: .init())
        XCTAssertEqual(resolved, "https://{{missing}}/ping")
    }

    func testTemplateExpressionCanBeResolvedWhenEvaluatorProvidesValue() {
        let resolver = VariableResolver()
        let context = VariableResolutionContext(
            environment: [VariableValue(key: "pinpadId", value: "123")]
        )

        let resolved = resolver.resolve(
            #"{"json_ejemplo": {{GenerarBodyAsignacion.generarBody(pm.environment.get("pinpadId"))}}}"#,
            context: context
        ) { expression, currentContext in
            guard expression == #"GenerarBodyAsignacion.generarBody(pm.environment.get("pinpadId"))"# else {
                return nil
            }
            let pinpadId = currentContext.environment.last?.value ?? ""
            return #"{"pinpadId":"\#(pinpadId)","ok":true}"#
        }

        XCTAssertEqual(resolved, #"{"json_ejemplo": {"pinpadId":"123","ok":true}}"#)
    }
}
