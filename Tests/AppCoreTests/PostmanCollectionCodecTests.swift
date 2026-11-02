import EfbyPresentation
import XCTest

final class PostmanCollectionCodecTests: XCTestCase {
    func testEmptyCollectionRoundTripPreservesRequiredItemArray() throws {
        let codec = PostmanCollectionCodec()
        let collection = CollectionModel(info: CollectionInfoModel(name: "Empty"))
        let data = try codec.export(collection)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((root["item"] as? [Any])?.count, 0)
        let imported = try codec.importCollection(data: data)
        XCTAssertEqual(imported.info.name, "Empty")
        XCTAssertTrue(imported.items.isEmpty)
    }

    func testScriptRoundTripPreservesExactSourceAtEveryCollectionLevel() throws {
        let codec = PostmanCollectionCodec()
        let sources = ["", "\n", "\r\n", "\r\nconst template = `first\r\n\r\nlast`;\r\n\r\n", "first\rsecond\n\n"]
        for source in sources {
            let script = ScriptDefinition(name: "Preserved script", listen: .preRequest, language: "text/javascript", source: source)
            let collection = CollectionModel(
                info: CollectionInfoModel(name: "Scripts"),
                scripts: [script],
                items: [CollectionNode(name: "Folder", kind: .folder, scripts: [script], children: [
                    CollectionNode(name: "Request", kind: .request, request: APIRequestModel(
                        name: "Request", url: "https://example.test", scripts: [script]
                    ), scripts: [script]),
                ])]
            )
            for version in [PostmanSchemaVersion.v2, .v21] {
                let imported = try codec.importCollection(data: codec.export(collection, targetVersion: version))
                let folder = try XCTUnwrap(imported.items.first)
                let requestNode = try XCTUnwrap(folder.children.first)
                for scripts in [imported.scripts, folder.scripts, requestNode.scripts, requestNode.request?.scripts ?? []] {
                    XCTAssertEqual(scripts.count, 1)
                    let preserved = try XCTUnwrap(scripts.first)
                    XCTAssertEqual(preserved.name, script.name)
                    XCTAssertEqual(Array(preserved.source.utf8), Array(source.utf8))
                }
            }
        }
    }

    func testImportsScriptExecStringWithoutChangingSource() throws {
        let source = "\nconst template = `first\r\n\r\nlast`;\n\n"
        let data = try JSONSerialization.data(withJSONObject: [
            "info": ["name": "String exec", "schema": PostmanSchemaVersion.v21.schemaURL],
            "item": [],
            "event": [["listen": "prerequest", "script": ["type": "text/javascript", "exec": source]]],
        ])
        let imported = try PostmanCollectionCodec().importCollection(data: data)
        let script = try XCTUnwrap(imported.scripts.first)

        XCTAssertEqual(Array(script.source.utf8), Array(source.utf8))
    }

    func testRoundTripPreservesDisabledRequestParametersAndSavedResponseHeaders() throws {
        let codec = PostmanCollectionCodec()
        let entries = [
            KeyValueEntry(key: "enabled", value: "used"),
            KeyValueEntry(key: "disabled", value: "saved", isEnabled: false),
        ]
        for bodyKind in [RequestBodyKind.urlEncoded, .formData] {
            let request = APIRequestModel(
                name: "Parameters", url: "https://example.test/:enabled",
                queryItems: entries, pathVariables: entries, headers: entries,
                body: RequestBodyModel(kind: bodyKind, parameters: entries)
            )
            let collection = CollectionModel(info: CollectionInfoModel(name: "Parameters"), items: [
                CollectionNode(name: "Parameters", kind: .request, request: request, responses: [
                    SavedResponseModel(name: "Example", statusCode: 200, headers: entries, body: "OK"),
                ]),
            ])
            for version in [PostmanSchemaVersion.v2, .v21] {
                let imported = try codec.importCollection(data: codec.export(collection, targetVersion: version))
                let node = try XCTUnwrap(imported.items.first)
                let preserved = try XCTUnwrap(node.request)
                XCTAssertEqual(preserved.body.kind, bodyKind)
                for values in [preserved.headers, preserved.queryItems, preserved.pathVariables, preserved.body.parameters, node.responses.first?.headers ?? []] {
                    XCTAssertEqual(values.map(\.key), entries.map(\.key))
                    XCTAssertEqual(values.map(\.value), entries.map(\.value))
                    XCTAssertEqual(values.map(\.isEnabled), entries.map(\.isEnabled))
                }
            }
        }
    }

    func testImportsPostmanV21CollectionAndPreservesHierarchy() throws {
        let codec = PostmanCollectionCodec()
        let data = Data(sampleV21.utf8)

        let collection = try codec.importCollection(data: data)

        XCTAssertEqual(collection.info.schemaVersion, .v21)
        XCTAssertEqual(collection.info.name, "Sample API")
        XCTAssertEqual(collection.items.count, 1)
        XCTAssertEqual(collection.items.first?.kind, .folder)
        XCTAssertEqual(collection.items.first?.children.first?.request?.method, .get)
        XCTAssertEqual(collection.items.first?.children.first?.request?.body.kind, .json)
    }

    func testImportsPostmanV2Collection() throws {
        let codec = PostmanCollectionCodec()
        let data = Data(sampleV2.utf8)

        let collection = try codec.importCollection(data: data)

        XCTAssertEqual(collection.info.schemaVersion, .v2)
        XCTAssertEqual(collection.items.first?.request?.url, "https://api.example.com/health")
    }

    func testExportsToCompatiblePostmanJSON() throws {
        let codec = PostmanCollectionCodec()
        let collection = try codec.importCollection(data: Data(sampleV21.utf8))

        let exported = try codec.export(collection)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let info = try XCTUnwrap(root["info"] as? [String: Any])

        XCTAssertEqual(info["schema"] as? String, "https://schema.getpostman.com/json/collection/v2.1.0/collection.json")
        XCTAssertNotNil(root["item"])
    }

    func testImportsRealPostmanCollectionShape() throws {
        let codec = PostmanCollectionCodec()
        let collection = try codec.importCollection(data: Data(realPostmanShape.utf8))

        XCTAssertEqual(collection.info.name, "Simular ventas DE ASISTIDO")
        XCTAssertEqual(collection.info.schemaVersion, .v21)
        XCTAssertEqual(collection.items.count, 3)
        XCTAssertEqual(collection.items[0].request?.body.kind, .json)
        XCTAssertEqual(collection.items[1].request?.method, .post)
        XCTAssertEqual(collection.items[1].request?.url, "https://api3{{ambiente}}.copecpay.com/puntoventa_{{ambiente}}_1/confirmatransaccion")
        XCTAssertEqual(collection.items[1].scripts.first?.listen, .test)
        XCTAssertEqual(collection.items[1].request?.scripts.first?.listen, .test)
        XCTAssertTrue(collection.items[1].request?.scripts.first?.source.contains("pm.environment.get") == true)
    }

    func testExportsAndImportsRetryOn206Setting() throws {
        let codec = PostmanCollectionCodec()
        var collection = try codec.importCollection(data: Data(sampleV21.utf8))
        collection.items[0].children[0].request?.retryOn206Count = 7
        collection.items[0].children[0].request?.retryOn206DelayMilliseconds = 250

        let exported = try codec.export(collection)
        let roundTrip = try codec.importCollection(data: exported)

        XCTAssertEqual(roundTrip.items[0].children[0].request?.retryOn206Count, 7)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.retryOn206DelayMilliseconds, 250)
    }

    func testExportsAndImportsTLSRequestSettings() throws {
        let codec = PostmanCollectionCodec()
        var collection = try codec.importCollection(data: Data(sampleV21.utf8))
        collection.items[0].children[0].request?.tlsValidationMode = .insecure
        collection.items[0].children[0].request?.minimumTLSVersion = .tls10

        let exported = try codec.export(collection)
        let roundTrip = try codec.importCollection(data: exported)

        XCTAssertEqual(roundTrip.items[0].children[0].request?.tlsValidationMode, .insecure)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.minimumTLSVersion, .tls10)
    }

    func testExportsAndImportsWebSocketRequestMetadata() throws {
        let codec = PostmanCollectionCodec()
        var collection = try codec.importCollection(data: Data(sampleV21.utf8))
        collection.items[0].children[0].request?.transportKind = .webSocket
        collection.items[0].children[0].request?.webSocketSubprotocols = "json, chat.v2"
        collection.items[0].children[0].request?.webSocketOpenTimeoutSeconds = 20
        collection.items[0].children[0].request?.webSocketReconnectAttempts = 3
        collection.items[0].children[0].request?.webSocketReconnectIntervalMilliseconds = 5_000
        collection.items[0].children[0].request?.webSocketMaximumMessageSizeMB = 10
        collection.items[0].children[0].request?.webSocketPingIntervalSeconds = 30
        collection.items[0].children[0].request?.webSocketKeepAliveMessage = #"{"kind":"ping"}"#
        collection.items[0].children[0].request?.webSocketKeepAliveIntervalSeconds = 45

        let exported = try codec.export(collection)
        let roundTrip = try codec.importCollection(data: exported)

        XCTAssertEqual(roundTrip.items[0].children[0].request?.transportKind, .webSocket)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketSubprotocols, "json, chat.v2")
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketOpenTimeoutSeconds, 20)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketReconnectAttempts, 3)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketReconnectIntervalMilliseconds, 5_000)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketMaximumMessageSizeMB, 10)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketPingIntervalSeconds, 30)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketKeepAliveMessage, #"{"kind":"ping"}"#)
        XCTAssertEqual(roundTrip.items[0].children[0].request?.webSocketKeepAliveIntervalSeconds, 45)
    }
}

private let sampleV21 = """
{
  "info": {
    "name": "Sample API",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "item": [
    {
      "name": "Users",
      "item": [
        {
          "name": "Create User",
          "request": {
            "method": "GET",
            "header": [
              { "key": "Accept", "value": "application/json" }
            ],
            "url": {
              "raw": "https://api.example.com/users",
              "query": [
                { "key": "page", "value": "1" }
              ]
            },
            "body": {
              "mode": "raw",
              "raw": "{\\"ok\\": true}",
              "options": {
                "raw": {
                  "language": "json"
                }
              }
            }
          }
        }
      ]
    }
  ]
}
"""

private let sampleV2 = """
{
  "info": {
    "name": "Legacy API",
    "schema": "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"
  },
  "item": [
    {
      "name": "Health",
      "request": {
        "method": "GET",
        "url": "https://api.example.com/health"
      }
    }
  ]
}
"""

private let realPostmanShape = """
{
  "info": {
    "_postman_id": "e75d134a-8e87-4f84-ab1d-604f670d78a4",
    "name": "Simular ventas DE ASISTIDO",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
    "_exporter_id": "2939032",
    "_collection_link": "https://go.postman.co/collection/2939032-e75d134a-8e87-4f84-ab1d-604f670d78a4?source=collection_link"
  },
  "item": [
    {
      "name": "Inicio transaccion",
      "request": {
        "method": "POST",
        "header": [
          {
            "key": "requestid",
            "value": "ertyuiopsdfghjkzxcvbn1234567891234567890",
            "type": "text"
          }
        ],
        "body": {
          "mode": "raw",
          "raw": "{\\r\\n    \\"transaccionId\\": \\"{{transactionId}}\\"\\r\\n}",
          "options": {
            "raw": {
              "language": "json"
            }
          }
        },
        "url": {
          "raw": "https://api3{{ambiente}}.copecpay.com/puntoventa_{{ambiente}}_1/transaccion",
          "protocol": "https",
          "host": ["api3{{ambiente}}", "copecpay", "com"],
          "path": ["puntoventa_{{ambiente}}_1", "transaccion"]
        }
      },
      "response": []
    },
    {
      "name": "Confirmar transaccion",
      "event": [
        {
          "listen": "test",
          "script": {
            "exec": [
              "var trxId = pm.environment.get(\\"transactionId\\");",
              "pm.response.to.have.status(200);"
            ],
            "type": "text/javascript"
          }
        }
      ],
      "request": {
        "method": "POST",
        "header": [
          {
            "key": "requestid",
            "value": "ertyuiopsdfghjkzxcvbn1234567891234567890",
            "type": "text"
          }
        ],
        "body": {
          "mode": "raw",
          "raw": "{\\r\\n    \\"transaccionId\\": \\"{{transactionId}}\\",\\r\\n    \\"transaccionCodigo\\": \\"{{transactionCode}}\\"\\r\\n}",
          "options": {
            "raw": {
              "language": "json"
            }
          }
        },
        "url": {
          "raw": "https://api3{{ambiente}}.copecpay.com/puntoventa_{{ambiente}}_1/confirmatransaccion",
          "protocol": "https",
          "host": ["api3{{ambiente}}", "copecpay", "com"],
          "path": ["puntoventa_{{ambiente}}_1", "confirmatransaccion"]
        }
      },
      "response": []
    },
    {
      "name": "New Request",
      "request": {
        "method": "GET",
        "header": []
      },
      "response": []
    }
  ]
}
"""
