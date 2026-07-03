import Foundation

/// Static suggestions for the Ace-based JS editor (pre-request, post-response, WebSocket onMessage/onDone, utilities).
///
/// Keep aligned with `ScriptEngine.makeJavaScriptBootstrap()` and `executeJavaScript` bridge blocks so autocomplete
/// matches what actually exists at runtime. Human/agent-facing API reference: `SDD/tile/docs/reference/pm-api-javascript-completa.md`.
public enum JavaScriptRuntimeAutocomplete {
    public static let topLevelSuggestions: [String] = sortedUnique([
        "pm",
        "postman",
        "console",
        "utils",
        "CryptoJS",
        "JSON",
        "Math",
        "Number",
        "String",
        "Object",
        "Array",
        "Date",
        "request",
        "responseBody",
        "responseCode",
        "btoa(value)",
        "atob(value)",
        "encryptRsa(message, publicKeyPem)",
    ])

    public static let nestedSuggestions: [String: [String]] = sortedUnique([
        "pm": [
            "createEnvironment(name)",
            "createenvironment(name)",
            "setActiveEnvironment(nameOrId)",
            "setactiveenvironment(nameOrId)",
            "globals",
            "collectionVariables",
            "environment",
            "variables",
            "response",
            "request",
            "websocket",
            "crypto",
            "test(name, fn)",
            "expect(actual)",
            "generarQR(text)",
            "generarqr(text)",
        ],
        "pm.globals": ["get(key)", "set(key, value)", "unset(key)"],
        "pm.collectionVariables": ["get(key)", "set(key, value)", "unset(key)"],
        "pm.environment": [
            "get(key)",
            "set(key, value)",
            "unset(key)",
            "create(name)",
            "select(nameOrId)",
            "activate(nameOrId)",
            "getActive()",
            "list()",
        ],
        "pm.variables": ["get(key)", "set(key, value)", "unset(key)"],
        "pm.response": ["code", "text()", "json()", "to"],
        "pm.response.to": ["have"],
        "pm.response.to.have": ["status(expected)"],
        "pm.request": [
            "name",
            "method",
            "url",
            "urlTemplate",
            "headers",
            "queryItems",
            "param",
            "params",
            "pathVariables",
            "cookies",
            "body",
        ],
        "pm.request.headers": ["get(key)", "has(key)", "set(key, value)", "add(key, value)", "remove(key)", "all()"],
        "pm.request.queryItems": ["get(key)", "has(key)", "set(key, value)", "add(key, value)", "remove(key)", "all()"],
        "pm.request.param": ["get(key)", "has(key)", "set(key, value)", "add(key, value)", "remove(key)", "all()"],
        "pm.request.params": ["get(key)", "has(key)", "set(key, value)", "add(key, value)", "remove(key)", "all()"],
        "pm.request.body": ["kind", "raw", "rawTemplate", "parameters", "get()", "set(value)"],
        "pm.websocket": ["onMessage(handler)", "onDone(handler)", "disconnect()", "message", "done"],
        "pm.websocket.message": ["text()"],
        "pm.websocket.done": ["cause()"],
        "pm.crypto": ["rsa", "aes"],
        "pm.crypto.rsa": ["encryptOAEP_SHA256(message, publicKeyPem)"],
        "pm.crypto.aes": [
            "decryptCBCNoPaddingFromHex(keyBytes, ivValue, cipherHex)",
            "encryptCBCNoPaddingToHex(keyBytes, ivValue, plainBytes)",
            "encryptECBNoPadding(keyBytes, plainBytes)",
            "decryptECBNoPadding(keyBytes, cipherBytes)",
        ],
        "postman": [
            "setEnvironmentVariable(key, value)",
            "getEnvironmentVariable(key)",
            "clearEnvironmentVariable(key)",
            "createEnvironment(name)",
            "createenvironment(name)",
            "setActiveEnvironment(nameOrId)",
            "setactiveenvironment(nameOrId)",
            "setGlobalVariable(key, value)",
            "getGlobalVariable(key)",
            "clearGlobalVariable(key)",
        ],
        "console": ["log(...args)", "error(...args)", "warn(...args)"],
        "CryptoJS": ["enc", "HmacSHA256(message, key)"],
        "CryptoJS.enc": ["Utf8", "Base64", "Hex"],
        "CryptoJS.enc.Utf8": ["parse(value)"],
        "CryptoJS.enc.Base64": ["parse(value)"],
        "JSON": ["parse(text)", "stringify(value, replacer?, space?)"],
        "Object": ["keys(obj)", "assign(target, ...sources)", "entries(obj)", "values(obj)", "freeze(obj)"],
        "Array": ["isArray(value)", "from(iterable)"],
        "Number": ["isFinite(value)", "parseInt(string, radix?)", "parseFloat(string)"],
        "String": ["fromCharCode(...codes)"],
        "Math": [
            "floor(x)",
            "ceil(x)",
            "round(x)",
            "trunc(x)",
            "random()",
            "max(...values)",
            "min(...values)",
            "abs(x)",
            "pow(x, y)",
            "sqrt(x)",
        ],
        "Date": ["now()", "parse(isoString)"],
        "request": ["name", "method", "url", "urlTemplate", "headers", "queryItems", "pathVariables", "cookies", "body"],
        "request.body": ["kind", "raw", "rawTemplate", "parameters"],
    ])

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func sortedUnique(_ values: [String: [String]]) -> [String: [String]] {
        values.mapValues(sortedUnique)
    }
}
