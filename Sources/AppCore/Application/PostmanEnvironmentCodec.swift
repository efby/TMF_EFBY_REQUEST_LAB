import Foundation

public struct PostmanEnvironmentCodec: Sendable {
    public init() {}

    public func importEnvironment(data: Data) throws -> EnvironmentProfile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.invalidDocument("El archivo no contiene un objeto JSON valido de environment Postman.")
        }

        guard isPostmanEnvironment(root) else {
            throw AppError.invalidDocument("El archivo no corresponde a un environment Postman compatible.")
        }

        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = (root["id"] as? String).flatMap(UUID.init(uuidString:))
        let values = root["values"] as? [[String: Any]] ?? []

        return EnvironmentProfile(
            id: identifier ?? UUID(),
            name: name?.isEmpty == false ? name! : "Imported Environment",
            variables: values.map(parseVariable)
        )
    }

    public func exportEnvironment(_ environment: EnvironmentProfile) throws -> Data {
        let root: [String: Any] = [
            "id": environment.id.uuidString,
            "name": environment.name,
            "values": environment.variables.map(variableDictionary),
            "_postman_variable_scope": "environment",
            "_postman_exported_using": "EFBY Request Lab",
        ]

        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw AppError.export("No se pudo exportar el environment: \(error.localizedDescription)")
        }
    }

    public func isPostmanEnvironment(_ root: [String: Any]) -> Bool {
        let scope = (root["_postman_variable_scope"] as? String)?.lowercased()
        return scope == "environment" || (root["name"] is String && root["values"] is [[String: Any]])
    }

    private func parseVariable(_ payload: [String: Any]) -> VariableValue {
        VariableValue(
            key: payload["key"] as? String ?? "",
            value: payload["value"] as? String ?? "",
            isEnabled: payload["enabled"] as? Bool ?? !(payload["disabled"] as? Bool ?? false)
        )
    }

    private func variableDictionary(_ variable: VariableValue) -> [String: Any] {
        [
            "key": variable.key,
            "value": variable.value,
            "enabled": variable.isEnabled,
        ]
    }
}
