import EfbyPresentation
import XCTest

final class PostmanCollectionCodecTests: XCTestCase {
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
