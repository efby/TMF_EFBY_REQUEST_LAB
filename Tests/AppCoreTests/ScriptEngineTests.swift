import EfbyPresentation
import XCTest

final class ScriptEngineTests: XCTestCase {
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
