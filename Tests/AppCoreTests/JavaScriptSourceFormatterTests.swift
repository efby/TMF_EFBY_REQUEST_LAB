import EfbyPresentation
import XCTest

final class JavaScriptSourceFormatterTests: XCTestCase {
    func testFormatsUtilitySourceWithFourSpaceIndentation() {
        let source = """
        const TokenUtils = {
        generar: function(prefix) {
        if (prefix) {
        return {
        value: prefix + "-token"
        };
        }
        return {
        value: "fallback"
        };
        }
        };
        """

        let formatted = JavaScriptSourceFormatter.format(source)

        XCTAssertEqual(
            formatted,
            """
            const TokenUtils = {
                generar: function(prefix) {
                    if (prefix) {
                        return {
                            value: prefix + "-token"
                        };
                    }
                    return {
                        value: "fallback"
                    };
                }
            };
            """
        )
    }

    func testPreservesTemplateLiteralIndentationAndContents() {
        let source = """
        const GenerarBodyAsignacion = {
        generarBody: function() {
        const KEY_RSA = `
                -----BEGIN PUBLIC KEY-----
                LINEA_BASE64
                -----END PUBLIC KEY-----
                `.trim();
        return KEY_RSA;
        }
        };
        """

        let formatted = JavaScriptSourceFormatter.format(source)

        XCTAssertTrue(formatted.contains("const GenerarBodyAsignacion = {"))
        XCTAssertTrue(formatted.contains("    generarBody: function() {"))
        XCTAssertTrue(formatted.contains("        const KEY_RSA = `"))
        XCTAssertTrue(formatted.contains("        -----BEGIN PUBLIC KEY-----"))
        XCTAssertTrue(formatted.contains("        LINEA_BASE64"))
        XCTAssertTrue(formatted.contains("        -----END PUBLIC KEY-----"))
        XCTAssertTrue(formatted.contains("        `.trim();"))
        XCTAssertTrue(formatted.contains("        return KEY_RSA;"))
        XCTAssertTrue(formatted.contains("    }"))
        XCTAssertTrue(formatted.contains("};"))
    }
}
