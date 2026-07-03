import Foundation

public struct PostmanCollectionCodec: Sendable {
    public init() {}

    public func importCollection(data: Data) throws -> CollectionModel {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidDocument("El archivo no contiene un objeto JSON valido de Postman.")
        }

        guard let info = root["info"] as? [String: Any] else {
            throw AppError.invalidDocument("Falta el bloque 'info' requerido por Postman Collection.")
        }

        guard let items = root["item"] as? [[String: Any]] else {
            throw AppError.invalidDocument("Falta el arreglo 'item' requerido por Postman Collection.")
        }

        let version = detectVersion(from: info["schema"] as? String)
        let collectionInfo = CollectionInfoModel(
            name: stringValue(in: info["name"]) ?? "Imported Collection",
            description: descriptionText(from: info["description"]),
            schemaVersion: version
        )

        return CollectionModel(
            info: collectionInfo,
            variables: parseVariables(root["variable"]),
            auth: parseAuth(root["auth"]),
            scripts: parseEvents(root["event"]),
            items: items.map(parseItem),
            sourceFormat: version == .v2 ? .postmanV2 : .postmanV21
        )
    }

    public func export(
        _ collection: CollectionModel,
        targetVersion: PostmanSchemaVersion? = nil
    ) throws -> Data {
        let version = targetVersion ?? collection.info.schemaVersion
        let root: [String: Any] = [
            "info": [
                "name": collection.info.name,
                "description": collection.info.description,
                "schema": version.schemaURL,
            ],
            "auth": authDictionary(collection.auth) as Any,
            "event": collection.scripts.map(eventDictionary),
            "variable": collection.variables.map(variableDictionary),
            "item": collection.items.map(itemDictionary),
        ].compactMapValues { value in
            switch value {
            case let array as [Any] where array.isEmpty:
                return nil
            case let dictionary as [String: Any] where dictionary.isEmpty:
                return nil
            default:
                return value
            }
        }

        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw AppError.export("No se pudo exportar la coleccion: \(error.localizedDescription)")
        }
    }

    public func detectVersion(from schema: String?) -> PostmanSchemaVersion {
        let value = schema ?? ""
        if value.contains("v2.1.0") {
            return .v21
        }
        if value.contains("v2.0.0") {
            return .v2
        }
        return .unknown
    }

    private func parseItem(_ payload: [String: Any]) -> CollectionNode {
        let name = stringValue(in: payload["name"]) ?? "Untitled"
        let scripts = parseEvents(payload["event"])
        let auth = parseAuth(payload["auth"])
        let description = descriptionText(from: payload["description"])

        if let nestedItems = payload["item"] as? [[String: Any]] {
            return CollectionNode(
                name: name,
                kind: .folder,
                scripts: scripts,
                auth: auth,
                nodeDescription: description,
                children: nestedItems.map(parseItem)
            )
        }

        var request = parseRequest(payload["request"], fallbackName: name)
        request.scripts = mergeScripts(scripts, request.scripts)
        let responses = parseResponses(payload["response"])
        return CollectionNode(
            name: name,
            kind: .request,
            request: request,
            responses: responses,
            scripts: scripts,
            auth: auth,
            nodeDescription: description
        )
    }

    private func parseRequest(_ payload: Any?, fallbackName: String) -> APIRequestModel {
        guard let payload = payload else {
            return APIRequestModel(name: fallbackName)
        }

        if let rawString = payload as? String {
            return APIRequestModel(name: fallbackName, url: rawString)
        }

        let dictionary = payload as? [String: Any] ?? [:]
        let method = HTTPMethod(rawValue: stringValue(in: dictionary["method"]) ?? "GET") ?? .get
        let auth = parseAuth(dictionary["auth"])
        let headers = parseKeyValues(dictionary["header"])
        let (url, query, variables) = parseURL(dictionary["url"])
        let body = parseBody(dictionary["body"])
        let metadata = dictionary["_efbyRequestLab"] as? [String: Any]
        let transportKind = parseTransportKind(metadata)
        let httpRequestTargetKind = parseHTTPRequestTargetKind(metadata)
        let retryOn206Count = parseRetryOn206Count(metadata)
        let retryOn206DelayMilliseconds = parseRetryOn206DelayMilliseconds(metadata)
        let tlsValidationMode = parseTLSValidationMode(metadata)
        let minimumTLSVersion = parseMinimumTLSVersion(metadata)
        let webSocketSubprotocols = parseWebSocketSubprotocols(metadata)
        let webSocketOpenTimeoutSeconds = parseDouble(metadata, key: "webSocketOpenTimeoutSeconds", default: 0)
        let webSocketReconnectAttempts = parseInt(metadata, key: "webSocketReconnectAttempts", default: 0)
        let webSocketReconnectIntervalMilliseconds = parseInt(metadata, key: "webSocketReconnectIntervalMilliseconds", default: 0)
        let webSocketMaximumMessageSizeMB = parseInt(metadata, key: "webSocketMaximumMessageSizeMB", default: 0)
        let webSocketPingIntervalSeconds = parseDouble(metadata, key: "webSocketPingIntervalSeconds", default: 0)
        let webSocketKeepAliveMessage = parseString(metadata, key: "webSocketKeepAliveMessage", default: "")
        let webSocketKeepAliveIntervalSeconds = parseDouble(metadata, key: "webSocketKeepAliveIntervalSeconds", default: 0)
        let awsAccessPortalURLTemplate = parseString(metadata, key: "awsAccessPortalURLTemplate", default: "")
        return APIRequestModel(
            name: fallbackName,
            transportKind: transportKind,
            httpRequestTargetKind: httpRequestTargetKind,
            method: method,
            url: url,
            queryItems: query,
            pathVariables: variables,
            headers: headers,
            auth: auth,
            body: body,
            retryOn206Count: retryOn206Count,
            retryOn206DelayMilliseconds: retryOn206DelayMilliseconds,
            tlsValidationMode: tlsValidationMode,
            minimumTLSVersion: minimumTLSVersion,
            webSocketSubprotocols: webSocketSubprotocols,
            webSocketOpenTimeoutSeconds: webSocketOpenTimeoutSeconds,
            webSocketReconnectAttempts: webSocketReconnectAttempts,
            webSocketReconnectIntervalMilliseconds: webSocketReconnectIntervalMilliseconds,
            webSocketMaximumMessageSizeMB: webSocketMaximumMessageSizeMB,
            webSocketPingIntervalSeconds: webSocketPingIntervalSeconds,
            webSocketKeepAliveMessage: webSocketKeepAliveMessage,
            webSocketKeepAliveIntervalSeconds: webSocketKeepAliveIntervalSeconds,
            awsAccessPortalURLTemplate: awsAccessPortalURLTemplate
        )
    }

    private func parseResponses(_ payload: Any?) -> [SavedResponseModel] {
        guard let responses = payload as? [[String: Any]] else {
            return []
        }

        return responses.map { response in
            SavedResponseModel(
                name: stringValue(in: response["name"]) ?? "Example",
                statusCode: response["code"] as? Int ?? 0,
                headers: parseKeyValues(response["header"]),
                body: stringValue(in: response["body"]) ?? ""
            )
        }
    }

    private func parseURL(_ payload: Any?) -> (String, [KeyValueEntry], [KeyValueEntry]) {
        if let raw = payload as? String {
            return (raw, [], [])
        }

        guard let dictionary = payload as? [String: Any] else {
            return ("", [], [])
        }

        if let raw = stringValue(in: dictionary["raw"]) {
            return (
                raw,
                parseKeyValues(dictionary["query"]),
                parseKeyValues(dictionary["variable"])
            )
        }

        let host = (dictionary["host"] as? [Any])?.compactMap(stringValue(in:)).joined(separator: ".") ?? ""
        let path = (dictionary["path"] as? [Any])?.compactMap(stringValue(in:)).joined(separator: "/") ?? ""
        let scheme = stringValue(in: dictionary["protocol"]) ?? "https"
        let raw = host.isEmpty ? path : "\(scheme)://\(host)/\(path)"
        return (
            raw,
            parseKeyValues(dictionary["query"]),
            parseKeyValues(dictionary["variable"])
        )
    }

    private func parseBody(_ payload: Any?) -> RequestBodyModel {
        guard let dictionary = payload as? [String: Any] else {
            return RequestBodyModel()
        }

        let mode = stringValue(in: dictionary["mode"]) ?? "none"
        switch mode {
        case "raw":
            let raw = stringValue(in: dictionary["raw"]) ?? ""
            let language = ((dictionary["options"] as? [String: Any])?["raw"] as? [String: Any])?["language"] as? String
            return RequestBodyModel(kind: language == "json" ? .json : .raw, raw: raw)
        case "urlencoded":
            return RequestBodyModel(kind: .urlEncoded, parameters: parseKeyValues(dictionary["urlencoded"]))
        case "formdata":
            return RequestBodyModel(kind: .formData, parameters: parseKeyValues(dictionary["formdata"]))
        default:
            return RequestBodyModel(kind: .none)
        }
    }

    private func parseVariables(_ payload: Any?) -> [VariableValue] {
        guard let items = payload as? [[String: Any]] else {
            return []
        }

        return items.map { item in
            VariableValue(
                key: stringValue(in: item["key"]) ?? "",
                value: stringValue(in: item["value"]) ?? "",
                isEnabled: !(item["disabled"] as? Bool ?? false)
            )
        }
    }

    private func parseKeyValues(_ payload: Any?) -> [KeyValueEntry] {
        guard let items = payload as? [[String: Any]] else {
            return []
        }

        return items.map { item in
            KeyValueEntry(
                key: stringValue(in: item["key"]) ?? "",
                value: stringValue(in: item["value"]) ?? "",
                isEnabled: !(item["disabled"] as? Bool ?? false)
            )
        }
    }

    private func parseEvents(_ payload: Any?) -> [ScriptDefinition] {
        guard let items = payload as? [[String: Any]] else {
            return []
        }

        return items.compactMap { event in
            guard let listen = stringValue(in: event["listen"]),
                  let eventType = ScriptEventType(rawValue: listen) else {
                return nil
            }

            let script = event["script"] as? [String: Any]
            let lines = (script?["exec"] as? [Any])?.compactMap(stringValue(in:)) ?? []
            let language = stringValue(in: script?["type"]) ?? "javascript"
            return ScriptDefinition(
                name: stringValue(in: event["name"]) ?? listen,
                listen: eventType,
                language: language,
                source: lines.joined(separator: "\n")
            )
        }
    }

    private func parseAuth(_ payload: Any?) -> AuthConfiguration {
        guard let auth = payload as? [String: Any] else {
            return AuthConfiguration()
        }

        let rawType = (stringValue(in: auth["type"]) ?? "").lowercased()
        let type: AuthType = switch rawType {
        case "basic":
            .basic
        case "bearer":
            .bearer
        case "apikey":
            .apiKey
        case "oauth2":
            .oauth2
        case "awstemporarycredentials":
            .awsTemporaryCredentials
        default:
            .noAuth
        }
        let key = rawType.isEmpty ? "noauth" : rawType
        let values = auth[key] as? [[String: Any]] ?? []
        let map = Dictionary(uniqueKeysWithValues: values.compactMap { item -> (String, String)? in
            guard let key = stringValue(in: item["key"]) else { return nil }
            return (key, stringValue(in: item["value"]) ?? "")
        })

        switch type {
        case .noAuth:
            return AuthConfiguration()
        case .basic:
            return AuthConfiguration(
                type: .basic,
                username: map["username"] ?? "",
                password: map["password"] ?? ""
            )
        case .bearer:
            return AuthConfiguration(type: .bearer, token: map["token"] ?? "")
        case .apiKey:
            return AuthConfiguration(
                type: .apiKey,
                key: map["key"] ?? "",
                value: map["value"] ?? "",
                addTo: APIKeyPlacement(rawValue: map["in"] ?? "header") ?? .header
            )
        case .oauth2:
            return AuthConfiguration(
                type: .oauth2,
                token: map["accessToken"] ?? "",
                accessTokenURL: map["accessTokenUrl"] ?? "",
                clientID: map["clientId"] ?? "",
                clientSecret: map["clientSecret"] ?? "",
                scopes: map["scope"] ?? ""
            )
        case .awsTemporaryCredentials:
            return AuthConfiguration(
                type: .awsTemporaryCredentials,
                token: map["token"] ?? ""
            )
        }
    }

    private func itemDictionary(_ item: CollectionNode) -> [String: Any] {
        var dictionary: [String: Any] = [
            "name": item.name,
        ]

        if !item.nodeDescription.isEmpty {
            dictionary["description"] = item.nodeDescription
        }
        if item.auth.type != .noAuth {
            dictionary["auth"] = authDictionary(item.auth)
        }
        if !item.scripts.isEmpty {
            dictionary["event"] = item.scripts.map(eventDictionary)
        }

        switch item.kind {
        case .folder:
            dictionary["item"] = item.children.map(itemDictionary)
        case .request:
            if let request = item.request {
                dictionary["request"] = requestDictionary(request)
            }
            if !item.responses.isEmpty {
                dictionary["response"] = item.responses.map(responseDictionary)
            }
        }

        return dictionary
    }

    private func requestDictionary(_ request: APIRequestModel) -> [String: Any] {
        var dictionary: [String: Any] = [
            "method": request.method.rawValue,
            "header": request.headers.filter(\.isEnabled).map(keyValueDictionary),
            "url": urlDictionary(for: request),
            "_efbyRequestLab": requestMetadataDictionary(request),
        ]

        if request.auth.type != .noAuth {
            dictionary["auth"] = authDictionary(request.auth)
        }
        if request.body.kind != .none {
            dictionary["body"] = bodyDictionary(request.body)
        }

        return dictionary
    }

    private func requestMetadataDictionary(_ request: APIRequestModel) -> [String: Any] {
        var meta: [String: Any] = [
            "transportKind": request.transportKind.rawValue,
            "retryOn206Count": request.retryOn206Count,
            "retryOn206DelayMilliseconds": request.retryOn206DelayMilliseconds,
            "tlsValidationMode": request.tlsValidationMode.rawValue,
            "minimumTLSVersion": request.minimumTLSVersion.rawValue,
            "webSocketSubprotocols": request.webSocketSubprotocols,
            "webSocketOpenTimeoutSeconds": request.webSocketOpenTimeoutSeconds,
            "webSocketReconnectAttempts": request.webSocketReconnectAttempts,
            "webSocketReconnectIntervalMilliseconds": request.webSocketReconnectIntervalMilliseconds,
            "webSocketMaximumMessageSizeMB": request.webSocketMaximumMessageSizeMB,
            "webSocketPingIntervalSeconds": request.webSocketPingIntervalSeconds,
            "webSocketKeepAliveMessage": request.webSocketKeepAliveMessage,
            "webSocketKeepAliveIntervalSeconds": request.webSocketKeepAliveIntervalSeconds,
            "awsAccessPortalURLTemplate": request.awsAccessPortalURLTemplate,
        ]
        if let target = request.httpRequestTargetKind {
            meta["httpRequestTargetKind"] = target.rawValue
        }
        return meta
    }

    private func parseRetryOn206Count(_ payload: Any?) -> Int {
        guard let dictionary = payload as? [String: Any] else {
            return 5
        }

        if let value = dictionary["retryOn206Count"] as? Int {
            return max(0, value)
        }

        if let value = dictionary["retryOn206Count"] as? String,
           let parsed = Int(value) {
            return max(0, parsed)
        }

        return 5
    }

    private func parseRetryOn206DelayMilliseconds(_ payload: Any?) -> Int {
        guard let dictionary = payload as? [String: Any] else {
            return 0
        }

        if let value = dictionary["retryOn206DelayMilliseconds"] as? Int {
            return max(0, value)
        }

        if let value = dictionary["retryOn206DelayMilliseconds"] as? String,
           let parsed = Int(value) {
            return max(0, parsed)
        }

        return 0
    }

    private func parseTransportKind(_ payload: Any?) -> RequestTransportKind {
        guard let dictionary = payload as? [String: Any],
              let rawValue = dictionary["transportKind"] as? String,
              let kind = RequestTransportKind(rawValue: rawValue) else {
            return .http
        }
        return kind
    }

    private func parseHTTPRequestTargetKind(_ payload: Any?) -> HTTPRequestTargetKind? {
        guard let dictionary = payload as? [String: Any],
              let rawValue = dictionary["httpRequestTargetKind"] as? String,
              let kind = HTTPRequestTargetKind(rawValue: rawValue) else {
            return nil
        }
        return kind
    }

    private func parseTLSValidationMode(_ payload: Any?) -> TLSValidationMode {
        guard let dictionary = payload as? [String: Any],
              let rawValue = dictionary["tlsValidationMode"] as? String,
              let mode = TLSValidationMode(rawValue: rawValue) else {
            return .strict
        }
        return mode
    }

    private func parseMinimumTLSVersion(_ payload: Any?) -> TLSMinimumVersionOption {
        guard let dictionary = payload as? [String: Any],
              let rawValue = dictionary["minimumTLSVersion"] as? String,
              let version = TLSMinimumVersionOption(rawValue: rawValue) else {
            return .systemDefault
        }
        return version
    }

    private func parseWebSocketSubprotocols(_ payload: Any?) -> String {
        guard let dictionary = payload as? [String: Any] else {
            return ""
        }

        if let value = dictionary["webSocketSubprotocols"] as? String {
            return value
        }

        if let values = dictionary["webSocketSubprotocols"] as? [String] {
            return values.joined(separator: ", ")
        }

        return ""
    }

    private func parseDouble(_ payload: Any?, key: String, default defaultValue: Double) -> Double {
        guard let dictionary = payload as? [String: Any] else {
            return defaultValue
        }

        if let value = dictionary[key] as? Double {
            return max(0, value)
        }

        if let value = dictionary[key] as? Int {
            return max(0, Double(value))
        }

        if let value = dictionary[key] as? String,
           let parsed = Double(value) {
            return max(0, parsed)
        }

        return defaultValue
    }

    private func parseInt(_ payload: Any?, key: String, default defaultValue: Int) -> Int {
        guard let dictionary = payload as? [String: Any] else {
            return defaultValue
        }

        if let value = dictionary[key] as? Int {
            return max(0, value)
        }

        if let value = dictionary[key] as? Double {
            return max(0, Int(value.rounded()))
        }

        if let value = dictionary[key] as? String,
           let parsed = Int(value) {
            return max(0, parsed)
        }

        return defaultValue
    }

    private func parseString(_ payload: Any?, key: String, default defaultValue: String) -> String {
        guard let dictionary = payload as? [String: Any] else {
            return defaultValue
        }

        if let value = dictionary[key] as? String {
            return value
        }

        return defaultValue
    }

    private func responseDictionary(_ response: SavedResponseModel) -> [String: Any] {
        [
            "name": response.name,
            "code": response.statusCode,
            "header": response.headers.filter(\.isEnabled).map(keyValueDictionary),
            "body": response.body,
        ]
    }

    private func eventDictionary(_ event: ScriptDefinition) -> [String: Any] {
        [
            "listen": event.listen.rawValue,
            "script": [
                "type": normalizedScriptLanguage(event.language),
                "exec": event.source.split(whereSeparator: \.isNewline).map(String.init),
            ],
        ]
    }

    private func mergeScripts(_ groups: [ScriptDefinition]...) -> [ScriptDefinition] {
        var merged: [ScriptDefinition] = []
        var seen = Set<String>()

        for group in groups {
            for script in group {
                let key = [script.listen.rawValue, script.name, script.language, script.source].joined(separator: "::")
                if seen.insert(key).inserted {
                    merged.append(script)
                }
            }
        }

        return merged
    }

    private func normalizedScriptLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "text/javascript"
        }

        let lowered = trimmed.lowercased()
        if lowered == "javascript" {
            return "text/javascript"
        }

        return trimmed
    }

    private func variableDictionary(_ variable: VariableValue) -> [String: Any] {
        [
            "key": variable.key,
            "value": variable.value,
            "disabled": !variable.isEnabled,
        ]
    }

    private func authDictionary(_ auth: AuthConfiguration) -> [String: Any] {
        switch auth.type {
        case .noAuth:
            return [:]
        case .basic:
            return [
                "type": "basic",
                "basic": [
                    ["key": "username", "value": auth.username],
                    ["key": "password", "value": auth.password],
                ],
            ]
        case .bearer:
            return [
                "type": "bearer",
                "bearer": [
                    ["key": "token", "value": auth.token],
                ],
            ]
        case .apiKey:
            return [
                "type": "apikey",
                "apikey": [
                    ["key": "key", "value": auth.key],
                    ["key": "value", "value": auth.value],
                    ["key": "in", "value": auth.addTo.rawValue],
                ],
            ]
        case .oauth2:
            return [
                "type": "oauth2",
                "oauth2": [
                    ["key": "accessToken", "value": auth.token],
                    ["key": "accessTokenUrl", "value": auth.accessTokenURL],
                    ["key": "clientId", "value": auth.clientID],
                    ["key": "clientSecret", "value": auth.clientSecret],
                    ["key": "scope", "value": auth.scopes],
                ],
            ]
        case .awsTemporaryCredentials:
            return [
                "type": "awstemporarycredentials",
                "awstemporarycredentials": [
                    ["key": "token", "value": auth.token],
                ],
            ]
        }
    }

    private func urlDictionary(for request: APIRequestModel) -> [String: Any] {
        [
            "raw": request.url,
            "query": request.queryItems.filter(\.isEnabled).map(keyValueDictionary),
            "variable": request.pathVariables.filter(\.isEnabled).map(keyValueDictionary),
        ]
    }

    private func bodyDictionary(_ body: RequestBodyModel) -> [String: Any] {
        switch body.kind {
        case .none:
            return [:]
        case .raw:
            return [
                "mode": "raw",
                "raw": body.raw,
            ]
        case .json:
            return [
                "mode": "raw",
                "raw": body.raw,
                "options": ["raw": ["language": "json"]],
            ]
        case .urlEncoded:
            return [
                "mode": "urlencoded",
                "urlencoded": body.parameters.filter(\.isEnabled).map(keyValueDictionary),
            ]
        case .formData:
            return [
                "mode": "formdata",
                "formdata": body.parameters.filter(\.isEnabled).map(keyValueDictionary),
            ]
        }
    }

    private func keyValueDictionary(_ entry: KeyValueEntry) -> [String: Any] {
        [
            "key": entry.key,
            "value": entry.value,
            "disabled": !entry.isEnabled,
        ]
    }

    private func stringValue(in payload: Any?) -> String? {
        switch payload {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private func descriptionText(from payload: Any?) -> String {
        if let string = payload as? String {
            return string
        }

        if let dictionary = payload as? [String: Any] {
            return stringValue(in: dictionary["content"]) ?? stringValue(in: dictionary["text"]) ?? ""
        }

        return ""
    }
}
