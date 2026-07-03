import EfbyPresentation
import XCTest

final class JavaScriptUtilitySymbolParserTests: XCTestCase {
    func testParsesMembersFromImmediatelyInvokedUtilityFactory() {
        let source = """
        const common = (function () {
            function privateHelper() {
                return "ok";
            }

            return {
                generaFechaEpoch_Horas: function generaFechaEpoch_Horas(hours) {
                    return hours;
                },
                signHmacSha256(keyBytes, messageBytes) {
                    return keyBytes.length + messageBytes.length + privateHelper().length;
                }
            };
        })();
        """

        let symbols = JavaScriptUtilitySymbolParser.topLevelSymbols(in: source)
        let common = symbols.first(where: { $0.identifier == "common" })

        XCTAssertNotNil(common)
        XCTAssertEqual(
            Set(common?.members ?? []),
            Set([
                "generaFechaEpoch_Horas(hours)",
                "signHmacSha256(keyBytes, messageBytes)",
            ])
        )
    }

    func testParsesTopLevelFunctionExpressionsAndArrowFunctions() {
        let source = """
        const buildTraceId = function(prefix, suffix) {
            return prefix + "-" + suffix;
        };

        const normalizeTenant = (tenant) => tenant.trim().toLowerCase();
        const stringifyValue = value => String(value);
        """

        let symbols = JavaScriptUtilitySymbolParser.topLevelSymbols(in: source)

        XCTAssertEqual(
            symbols.map(\.suggestion),
            [
                "buildTraceId(prefix, suffix)",
                "normalizeTenant(tenant)",
                "stringifyValue(value)",
            ]
        )
    }

    func testParsesObjectMembersDefinedWithArrowFunctions() {
        let source = """
        const helpers = {
            buildTrace: (prefix, id) => prefix + "-" + id,
            normalizeTenant: tenant => tenant.trim().toLowerCase(),
            async sign(body) {
                return body;
            }
        };
        """

        let symbols = JavaScriptUtilitySymbolParser.topLevelSymbols(in: source)
        let helpers = symbols.first(where: { $0.identifier == "helpers" })

        XCTAssertNotNil(helpers)
        XCTAssertEqual(
            Set(helpers?.members ?? []),
            Set([
                "buildTrace(prefix, id)",
                "normalizeTenant(tenant)",
                "sign(body)",
            ])
        )
    }
}
