import EfbyPresentation
import XCTest

final class JavaScriptRuntimeAutocompleteTests: XCTestCase {
    func testCoreTopLevelSuggestionsMatchRuntimeSurface() {
        let suggestions = Set(JavaScriptRuntimeAutocomplete.topLevelSuggestions)

        XCTAssertTrue(suggestions.contains("pm"))
        XCTAssertTrue(suggestions.contains("postman"))
        XCTAssertTrue(suggestions.contains("request"))
        XCTAssertTrue(suggestions.contains("responseBody"))
        XCTAssertTrue(suggestions.contains("responseCode"))
        XCTAssertTrue(suggestions.contains("btoa(value)"))
        XCTAssertTrue(suggestions.contains("atob(value)"))
        XCTAssertTrue(suggestions.contains("encryptRsa(message, publicKeyPem)"))
        XCTAssertTrue(suggestions.contains("Date"))
    }

    func testCoreNestedSuggestionsIncludeEnvironmentAndCryptoMembers() {
        let nested = JavaScriptRuntimeAutocomplete.nestedSuggestions

        XCTAssertEqual(
            Set(nested["pm.environment"] ?? []),
            Set([
                "get(key)",
                "set(key, value)",
                "unset(key)",
                "create(name)",
                "select(nameOrId)",
                "activate(nameOrId)",
                "getActive()",
                "list()",
            ])
        )

        XCTAssertEqual(
            Set(nested["pm.crypto.aes"] ?? []),
            Set([
                "decryptCBCNoPaddingFromHex(keyBytes, ivValue, cipherHex)",
                "encryptCBCNoPaddingToHex(keyBytes, ivValue, plainBytes)",
                "encryptECBNoPadding(keyBytes, plainBytes)",
                "decryptECBNoPadding(keyBytes, cipherBytes)",
            ])
        )
    }

    func testPostmanNestedIncludesLowercaseAliases() {
        let postman = Set(JavaScriptRuntimeAutocomplete.nestedSuggestions["postman"] ?? [])
        XCTAssertTrue(postman.contains("createenvironment(name)"))
        XCTAssertTrue(postman.contains("setactiveenvironment(nameOrId)"))
    }

    func testJsonAndMathNestedSuggestions() {
        let nested = JavaScriptRuntimeAutocomplete.nestedSuggestions
        XCTAssertTrue((nested["JSON"] ?? []).contains("parse(text)"))
        XCTAssertTrue((nested["Math"] ?? []).contains("floor(x)"))
        XCTAssertTrue((nested["Date"] ?? []).contains("now()"))
    }

    func testPmNestedListsRuntimeNamespaces() {
        let pm = Set(JavaScriptRuntimeAutocomplete.nestedSuggestions["pm"] ?? [])
        XCTAssertTrue(pm.contains("crypto"))
        XCTAssertTrue(pm.contains("websocket"))
        XCTAssertTrue(pm.contains("expect(actual)"))
    }
}
