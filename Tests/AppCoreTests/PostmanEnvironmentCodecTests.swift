import EfbyPresentation
import XCTest

final class PostmanEnvironmentCodecTests: XCTestCase {
    func testImportsPostmanEnvironmentJSON() throws {
        let codec = PostmanEnvironmentCodec()

        let environment = try codec.importEnvironment(data: Data(sampleEnvironment.utf8))

        XCTAssertEqual(environment.id.uuidString.lowercased(), "d061229f-c684-47b9-b44b-73e369891fc3")
        XCTAssertEqual(environment.name, "ApiSeguridad2")
        XCTAssertEqual(environment.variables.count, 3)
        XCTAssertEqual(environment.variables.first(where: { $0.key == "authorizationtoken" })?.value, "token-123")
        XCTAssertEqual(environment.variables.first(where: { $0.key == "body" })?.value, #"{"equipoId":"12345"}"#)
        XCTAssertEqual(environment.variables.first(where: { $0.key == "disabledVar" })?.isEnabled, false)
    }

    func testExportsAndReimportsEnvironmentJSON() throws {
        let codec = PostmanEnvironmentCodec()
        let original = EnvironmentProfile(
            name: "PAY",
            variables: [
                VariableValue(key: "token", value: "abc"),
                VariableValue(key: "merchantId", value: "123", isEnabled: false),
            ]
        )

        let data = try codec.exportEnvironment(original)
        let exportedString = String(decoding: data, as: UTF8.self)
        let imported = try codec.importEnvironment(data: data)

        XCTAssertFalse(exportedString.contains("_postman_exported_at"))
        XCTAssertTrue(exportedString.contains("_postman_exported_using"))
        XCTAssertEqual(imported.id, original.id)
        XCTAssertEqual(imported.name, "PAY")
        XCTAssertEqual(imported.variables.first(where: { $0.key == "token" })?.value, "abc")
        XCTAssertEqual(imported.variables.first(where: { $0.key == "merchantId" })?.isEnabled, false)
    }
}

private let sampleEnvironment = """
{
  "id": "d061229f-c684-47b9-b44b-73e369891fc3",
  "name": "ApiSeguridad2",
  "values": [
    {
      "key": "authorizationtoken",
      "value": "token-123",
      "enabled": true
    },
    {
      "key": "body",
      "value": "{\\"equipoId\\":\\"12345\\"}",
      "enabled": true
    },
    {
      "key": "disabledVar",
      "value": "legacy",
      "enabled": false
    }
  ],
  "_postman_variable_scope": "environment",
  "_postman_exported_at": "2026-04-06T01:59:51.016Z",
  "_postman_exported_using": "Postman/12.4.4"
}
"""
