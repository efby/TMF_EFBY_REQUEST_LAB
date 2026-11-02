import EfbyPresentation
import XCTest

final class ScriptEngineTests: XCTestCase {
    func testEnvironmentSetPreservesDisabledVariablesAndExistingIdentifiers() throws {
        let active = VariableValue(key: "counter", value: "1")
        let disabled = VariableValue(key: "saved", value: "keep", isEnabled: false)
        let profile = EnvironmentProfile(name: "QA", variables: [active, disabled])
        let other = EnvironmentProfile(name: "Other", variables: [VariableValue(key: "other", value: "untouched")])
        let report = runEnvironmentScript(
            #"pm.environment.set("counter", "2"); pm.environment.set("new", "3");"#,
            profile: profile,
            otherProfiles: [other]
        )

        let updated = try XCTUnwrap(report.runtime.environments.first)
        XCTAssertEqual(updated.variables.map(\.key), ["counter", "saved", "new"])
        XCTAssertEqual(updated.variables[0].id, active.id)
        XCTAssertEqual(updated.variables[0].value, "2")
        XCTAssertEqual(updated.variables[1], disabled)
        XCTAssertEqual(report.runtime.environments[1], other)
        XCTAssertNil(report.runtime.environment["saved"])
        XCTAssertEqual(report.runtime.environment["new"], "3")
    }

    func testEnvironmentSetEnablesExistingDisabledVariableAndPreservesIdentifier() throws {
        let disabled = VariableValue(key: "counter", value: "1", isEnabled: false)
        let profile = EnvironmentProfile(name: "QA", variables: [disabled])
        let report = runEnvironmentScript(#"pm.environment.set("counter", "2");"#, profile: profile)

        let variables = try XCTUnwrap(report.runtime.environments.first?.variables)
        XCTAssertEqual(variables.count, 1)
        XCTAssertEqual(variables.first?.id, disabled.id)
        XCTAssertEqual(variables.first?.value, "2")
        XCTAssertEqual(variables.first?.isEnabled, true)
        XCTAssertEqual(report.runtime.environment["counter"], "2")
    }

    func testEnvironmentUnsetDeletesOnlyRequestedKeyAndDoesNotRestoreItOnActivation() throws {
        let disabled = VariableValue(key: "saved", value: "keep", isEnabled: false)
        let profile = EnvironmentProfile(name: "QA", variables: [
            VariableValue(key: "remove", value: "old"), disabled,
        ])
        let report = runEnvironmentScript(
            #"pm.environment.unset("remove"); pm.environment.set("new", "1"); pm.environment.select("QA");"#,
            profile: profile
        )

        let variables = try XCTUnwrap(report.runtime.environments.first?.variables)
        XCTAssertEqual(variables.map(\.key), ["saved", "new"])
        XCTAssertEqual(variables.first, disabled)
        XCTAssertNil(report.runtime.environment["remove"])
    }

    func testEnvironmentClearRemovesAllVariablesAndDoesNotRestoreThemOnActivation() throws {
        let profile = EnvironmentProfile(name: "QA", variables: [
            VariableValue(key: "counter", value: "1"),
            VariableValue(key: "saved", value: "keep", isEnabled: false),
        ])
        let report = runEnvironmentScript(#"pm.environment.clear(); pm.environment.select("QA");"#, profile: profile)

        XCTAssertEqual(report.runtime.environments.first?.variables, [])
        XCTAssertTrue(report.runtime.environment.isEmpty)
        XCTAssertFalse(report.logs.contains { $0.contains("JavaScript error") })
    }

    func testTemplateExpressionUsesSameEnvironmentMutationRules() throws {
        let active = VariableValue(key: "counter", value: "1")
        let disabled = VariableValue(key: "saved", value: "keep", isEnabled: false)
        let profile = EnvironmentProfile(name: "QA", variables: [active, disabled])
        let engine = ScriptEngine()
        let updated = try XCTUnwrap(engine.evaluateTemplateExpressionReport(
            #"(pm.environment.set("counter", "2"), pm.environment.unset("missing"), "done")"#,
            runtime: environmentRuntime(profile)
        ))

        XCTAssertEqual(updated.value, "done")
        XCTAssertEqual(updated.runtime.environments.first?.variables.first?.id, active.id)
        XCTAssertEqual(updated.runtime.environments.first?.variables.last, disabled)
        let cleared = try XCTUnwrap(engine.evaluateTemplateExpressionReport(
            #"(pm.environment.clear(), "done")"#,
            runtime: updated.runtime
        ))
        XCTAssertEqual(cleared.value, "done")
        XCTAssertTrue(cleared.runtime.environment.isEmpty)
        XCTAssertEqual(cleared.runtime.environments.first?.variables, [])
    }

    private func runEnvironmentScript(
        _ source: String,
        profile: EnvironmentProfile,
        otherProfiles: [EnvironmentProfile] = []
    ) -> ScriptExecutionReport {
        ScriptEngine().execute(
            scripts: [ScriptDefinition(name: "Environment regression", listen: .preRequest, language: "text/javascript", source: source)],
            event: .preRequest,
            runtime: environmentRuntime(profile, otherProfiles: otherProfiles)
        )
    }

    private func environmentRuntime(
        _ profile: EnvironmentProfile,
        otherProfiles: [EnvironmentProfile] = []
    ) -> ScriptRuntimeContext {
        ScriptRuntimeContext(
            environment: profile.variables.filter(\.isEnabled).reduce(into: [:]) { $0[$1.key] = $1.value },
            environments: [profile] + otherProfiles,
            activeEnvironmentID: profile.id
        )
    }

    func testRsaEncryptProducesHexCiphertext() {
        let engine = ScriptEngine()
        let script = ScriptDefinition(
            name: "RSA encrypt",
            listen: .preRequest,
            language: "text/javascript",
            source: """
            var encrypted = pm.crypto.rsa.encryptOAEP_SHA256("secret-demo", pm.environment.get("rsaPublicKey"));
            pm.environment.set("encryptedSecret", encrypted);
            """
        )
        let runtime = ScriptRuntimeContext(
            environment: ["rsaPublicKey": testRSAPublicKeyPEM]
        )

        let report = engine.execute(
            scripts: [script],
            event: .preRequest,
            runtime: runtime
        )

        let encryptedHex = report.runtime.environment["encryptedSecret"] ?? ""
        XCTAssertEqual(encryptedHex.count, 512)
        XCTAssertTrue(encryptedHex.allSatisfy { $0.isHexDigit })
    }

    func testEncryptRsaAliasMatchesRSAOAEP() {
        let engine = ScriptEngine()
        let script = ScriptDefinition(
            name: "Alias encryptRsa",
            listen: .preRequest,
            language: "text/javascript",
            source: """
            var viaAlias = encryptRsa("alias-test", pm.environment.get("rsaPublicKey"));
            var viaCrypto = pm.crypto.rsa.encryptOAEP_SHA256("alias-test", pm.environment.get("rsaPublicKey"));
            pm.environment.set("aliasLen", String(viaAlias.length));
            pm.environment.set("cryptoLen", String(viaCrypto.length));
            """
        )

        let report = engine.execute(
            scripts: [script],
            event: .preRequest,
            runtime: ScriptRuntimeContext(environment: ["rsaPublicKey": testRSAPublicKeyPEM])
        )

        XCTAssertEqual(report.runtime.environment["aliasLen"], "512")
        XCTAssertEqual(report.runtime.environment["cryptoLen"], "512")
    }

    func testAesCBCEncryptDecryptRoundTrip() {
        let engine = ScriptEngine()
        let utility = WorkspaceScriptUtility(
            name: "Byte helpers",
            language: "javascript",
            source: """
            const Utf8 = {
                encode: function(text) {
                    text = String(text == null ? "" : text);
                    var utf8 = unescape(encodeURIComponent(text));
                    var bytes = [];
                    for (var i = 0; i < utf8.length; i += 1) {
                        bytes.push(utf8.charCodeAt(i));
                    }
                    return bytes;
                },
                decode: function(bytes) {
                    bytes = bytes || [];
                    var binary = "";
                    for (var i = 0; i < bytes.length; i += 1) {
                        binary += String.fromCharCode(bytes[i]);
                    }
                    return decodeURIComponent(escape(binary));
                }
            };
            """
        )
        let script = ScriptDefinition(
            name: "AES CBC",
            listen: .preRequest,
            language: "text/javascript",
            source: """
            var keyBytes = Utf8.encode("01234567890123456789012345678901");
            var plainText = "1234567890abcdef1234567890abcdef";
            var plainBytes = Utf8.encode(plainText);
            var encrypted = pm.crypto.aes.encryptCBCNoPaddingToHex(keyBytes, "abcdefghijklmnop", plainBytes);
            var decryptedBytes = pm.crypto.aes.decryptCBCNoPaddingFromHex(keyBytes, "abcdefghijklmnop", encrypted);
            pm.environment.set("aesRoundTrip", Utf8.decode(decryptedBytes));
            """
        )

        let report = engine.execute(
            scripts: [script],
            event: .preRequest,
            runtime: ScriptRuntimeContext(),
            utilities: [utility]
        )

        XCTAssertEqual(report.runtime.environment["aesRoundTrip"], "1234567890abcdef1234567890abcdef")
    }

    func testInvalidRSAInputReturnsEmptyString() {
        let engine = ScriptEngine()
        let script = ScriptDefinition(
            name: "Invalid RSA",
            listen: .preRequest,
            language: "text/javascript",
            source: """
            var result = pm.crypto.rsa.encryptOAEP_SHA256("data", "not-a-valid-pem");
            pm.environment.set("rsaError", result);
            """
        )

        let report = engine.execute(
            scripts: [script],
            event: .preRequest,
            runtime: ScriptRuntimeContext()
        )

        XCTAssertEqual(report.runtime.environment["rsaError"], "")
    }
}

private let testRSAPublicKeyPEM = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnDXuoNoUfDmsmuijImY3
AwAeLwe8KeubuFhbN1s2LSawJIvQQh2rALekF2KZSYiIu7lf3V19JOfc/41DdOHL
Cfonn/nhzPagCiEmDv2z5CpkLFlVZjnDHyV65Us5EFPUYodQqufvPHawsZQ+WXUQ
hBaRzxFqJ4k9rDGDLf97Nq7uwFptnX2h94QsB6d7FLKJwhcJUI3KUwoDiwUHfD48
OCp0d2Tlqb9QIbNDwjdBGxcLllXeuiSXu/Z09sYKX2k6jKS/CUtdqx8vMEYhN9qE
Emf7hLRX6TiUSIkG8z8NxxuTaVUt8nEZzRVF73SbeuqTWBNUyoOR3tzD4st+G+n4
DQIDAQAB
-----END PUBLIC KEY-----
"""
