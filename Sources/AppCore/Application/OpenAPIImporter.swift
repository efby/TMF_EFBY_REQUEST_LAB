import Foundation

public struct OpenAPIImporter: Sendable {
    public init() {}

    public func importDocument(data: Data, fileExtension: String) throws -> CollectionModel {
        guard fileExtension.lowercased() == "json" else {
            throw AppError.unsupportedFormat(
                "La importacion OpenAPI YAML quedo preparada como extension futura. En esta primera version se soporta OpenAPI 3.x en JSON."
            )
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidDocument("El archivo OpenAPI no contiene un objeto JSON valido.")
        }

        guard let version = root["openapi"] as? String, version.hasPrefix("3.") else {
            throw AppError.invalidDocument("Solo se soporta OpenAPI 3.0/3.1 en esta importacion base.")
        }

        let info = root["info"] as? [String: Any] ?? [:]
        let paths = root["paths"] as? [String: Any] ?? [:]
        let serverURL = ((root["servers"] as? [[String: Any]])?.first?["url"] as? String) ?? ""

        let nodes = paths.keys.sorted().flatMap { path -> [CollectionNode] in
            guard let operations = paths[path] as? [String: Any] else {
                return []
            }

            return HTTPMethod.allCases.compactMap { method in
                guard let operation = operations[method.rawValue.lowercased()] as? [String: Any] else {
                    return nil
                }

                let parameters = operation["parameters"] as? [[String: Any]] ?? []
                let query = parameters.compactMap { parameter -> KeyValueEntry? in
                    guard parameter["in"] as? String == "query" else { return nil }
                    return KeyValueEntry(
                        key: parameter["name"] as? String ?? "",
                        value: parameter["example"] as? String ?? ""
                    )
                }
                let pathVars = parameters.compactMap { parameter -> KeyValueEntry? in
                    guard parameter["in"] as? String == "path" else { return nil }
                    return KeyValueEntry(
                        key: parameter["name"] as? String ?? "",
                        value: parameter["example"] as? String ?? ""
                    )
                }
                let headers = parameters.compactMap { parameter -> KeyValueEntry? in
                    guard parameter["in"] as? String == "header" else { return nil }
                    return KeyValueEntry(
                        key: parameter["name"] as? String ?? "",
                        value: parameter["example"] as? String ?? ""
                    )
                }

                let body = requestBody(from: operation["requestBody"] as? [String: Any])
                let name = (operation["summary"] as? String)
                    ?? (operation["operationId"] as? String)
                    ?? "\(method.rawValue) \(path)"

                return CollectionNode(
                    name: name,
                    kind: .request,
                    request: APIRequestModel(
                        name: name,
                        method: method,
                        url: serverURL + path,
                        queryItems: query,
                        pathVariables: pathVars,
                        headers: headers,
                        body: body
                    ),
                    responses: responseExamples(from: operation["responses"] as? [String: Any]),
                    nodeDescription: operation["description"] as? String ?? ""
                )
            }
        }

        return CollectionModel(
            info: CollectionInfoModel(
                name: info["title"] as? String ?? "OpenAPI Import",
                description: info["description"] as? String ?? "",
                schemaVersion: .v21
            ),
            items: nodes,
            sourceFormat: version.hasPrefix("3.1") ? .openAPI31 : .openAPI30
        )
    }

    private func requestBody(from payload: [String: Any]?) -> RequestBodyModel {
        guard
            let payload,
            let content = payload["content"] as? [String: Any]
        else {
            return RequestBodyModel()
        }

        if let json = content["application/json"] as? [String: Any] {
            if let example = json["example"] {
                return RequestBodyModel(
                    kind: .json,
                    raw: serialize(example)
                )
            }
            if let schema = json["schema"] {
                return RequestBodyModel(
                    kind: .json,
                    raw: serialize(schema)
                )
            }
        }

        if let form = content["application/x-www-form-urlencoded"] as? [String: Any],
           let schema = form["schema"] as? [String: Any],
           let properties = schema["properties"] as? [String: Any] {
            let fields = properties.keys.sorted().map { KeyValueEntry(key: $0, value: "") }
            return RequestBodyModel(kind: .urlEncoded, parameters: fields)
        }

        return RequestBodyModel()
    }

    private func responseExamples(from payload: [String: Any]?) -> [SavedResponseModel] {
        guard let payload else {
            return []
        }

        return payload.keys.sorted().compactMap { code in
            guard let response = payload[code] as? [String: Any] else {
                return nil
            }

            return SavedResponseModel(
                name: response["description"] as? String ?? "Response \(code)",
                statusCode: Int(code) ?? 0,
                body: serialize(response["content"] ?? [:])
            )
        }
    }

    private func serialize(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }
}
