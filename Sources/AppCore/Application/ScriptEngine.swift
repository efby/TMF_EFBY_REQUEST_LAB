import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

public struct ScriptRuntimeContext: Sendable {
    public var globals: [String: String]
    public var collection: [String: String]
    public var environment: [String: String]
    public var environments: [EnvironmentProfile]
    public var activeEnvironmentID: UUID?
    public var local: [String: String]
    public var requestHeaders: [KeyValueEntry]?
    public var requestQueryItems: [KeyValueEntry]?
    public var requestBody: RequestBodyModel?
    public var response: HTTPResponseModel?
    public var webSocketMessage: String?
    public var webSocketDoneCause: String?
    public var webSocketShouldDisconnect: Bool

    public init(
        globals: [String: String] = [:],
        collection: [String: String] = [:],
        environment: [String: String] = [:],
        environments: [EnvironmentProfile] = [],
        activeEnvironmentID: UUID? = nil,
        local: [String: String] = [:],
        requestHeaders: [KeyValueEntry]? = nil,
        requestQueryItems: [KeyValueEntry]? = nil,
        requestBody: RequestBodyModel? = nil,
        response: HTTPResponseModel? = nil,
        webSocketMessage: String? = nil,
        webSocketDoneCause: String? = nil,
        webSocketShouldDisconnect: Bool = false
    ) {
        self.globals = globals
        self.collection = collection
        self.environment = environment
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
        self.local = local
        self.requestHeaders = requestHeaders
        self.requestQueryItems = requestQueryItems
        self.requestBody = requestBody
        self.response = response
        self.webSocketMessage = webSocketMessage
        self.webSocketDoneCause = webSocketDoneCause
        self.webSocketShouldDisconnect = webSocketShouldDisconnect
    }
}

public struct ScriptExecutionReport: Sendable {
    public var runtime: ScriptRuntimeContext
    public var logs: [String]

    public init(runtime: ScriptRuntimeContext, logs: [String]) {
        self.runtime = runtime
        self.logs = logs
    }
}

public struct TemplateExpressionEvaluationReport: Sendable {
    public var value: String?
    public var runtime: ScriptRuntimeContext
    public var logs: [String]

    public init(value: String?, runtime: ScriptRuntimeContext, logs: [String]) {
        self.value = value
        self.runtime = runtime
        self.logs = logs
    }
}

public struct ScriptEngine: Sendable {
    public init() {}

    public func execute(
        scripts: [ScriptDefinition],
        event: ScriptEventType,
        runtime: ScriptRuntimeContext,
        request: APIRequestModel? = nil,
        utilities: [WorkspaceScriptUtility] = []
    ) -> ScriptExecutionReport {
        var workingRuntime = runtime
        var logs: [String] = []

        for script in scripts where script.listen == event {
            if isJavaScriptLanguage(script.language),
               executeJavaScript(script: script, request: request, utilities: utilities, runtime: &workingRuntime, logs: &logs) {
                continue
            }

            let lines = script.source.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            for line in lines where !line.isEmpty {
                if handleMiniCommand(line, runtime: &workingRuntime, logs: &logs) {
                    continue
                }

                if handlePostmanCompatibility(line, runtime: &workingRuntime, logs: &logs) {
                    continue
                }

                logs.append("Unsupported script line: \(line)")
            }
        }

        return ScriptExecutionReport(runtime: workingRuntime, logs: logs)
    }

    private func isJavaScriptLanguage(_ language: String) -> Bool {
        let lowered = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty {
            return true
        }

        return lowered.contains("javascript") || lowered.contains("ecmascript")
    }

    private func handleMiniCommand(
        _ line: String,
        runtime: inout ScriptRuntimeContext,
        logs: inout [String]
    ) -> Bool {
        if line.hasPrefix("set ") {
            let payload = String(line.dropFirst(4))
            let segments = payload.split(separator: "=", maxSplits: 1).map(String.init)
            guard segments.count == 2 else {
                logs.append("Invalid set syntax: \(line)")
                return true
            }

            let target = segments[0].trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(segments[1].trimmingCharacters(in: .whitespaces))
            let parts = target.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                logs.append("Invalid variable target: \(line)")
                return true
            }

            assign(scope: parts[0], key: parts[1], value: value, runtime: &runtime)
            logs.append("Set \(target)")
            return true
        }

        if line.hasPrefix("assert.status") {
            let statusValue = line
                .replacingOccurrences(of: "assert.status", with: "")
                .replacingOccurrences(of: "==", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let expected = Int(statusValue) else {
                logs.append("Invalid assert.status syntax: \(line)")
                return true
            }

            let actual = runtime.response?.statusCode ?? -1
            logs.append(actual == expected ? "PASS status == \(expected)" : "FAIL status == \(expected), got \(actual)")
            return true
        }

        if line.hasPrefix("assert.json ") {
            guard let response = runtime.response else {
                logs.append("FAIL json assertion without response")
                return true
            }

            let payload = String(line.dropFirst("assert.json ".count))
            if payload.hasSuffix(" exists") {
                let path = payload.replacingOccurrences(of: " exists", with: "")
                let exists = jsonValue(for: path, body: response.body) != nil
                logs.append(exists ? "PASS json \(path) exists" : "FAIL json \(path) missing")
                return true
            }

            let parts = payload.components(separatedBy: "==")
            guard parts.count == 2 else {
                logs.append("Invalid assert.json syntax: \(line)")
                return true
            }

            let path = parts[0].trimmingCharacters(in: .whitespaces)
            let expected = stripQuotes(parts[1].trimmingCharacters(in: .whitespaces))
            let actual = jsonValue(for: path, body: response.body).map(normalizeJSONValue) ?? "nil"
            logs.append(actual == expected ? "PASS json \(path) == \(expected)" : "FAIL json \(path) == \(expected), got \(actual)")
            return true
        }

        return false
    }

    private func handlePostmanCompatibility(
        _ line: String,
        runtime: inout ScriptRuntimeContext,
        logs: inout [String]
    ) -> Bool {
        if let value = capture(#"pm\.response\.to\.have\.status\((\d+)\)"#, in: line).first,
           let expected = Int(value) {
            let actual = runtime.response?.statusCode ?? -1
            logs.append(actual == expected ? "PASS pm.response status \(expected)" : "FAIL pm.response status \(expected), got \(actual)")
            return true
        }

        let patterns: [(String, String)] = [
            (#"pm\.globals\.set\("([^"]+)",\s*"([^"]*)"\)"#, "globals"),
            (#"pm\.collectionVariables\.set\("([^"]+)",\s*"([^"]*)"\)"#, "collection"),
            (#"pm\.environment\.set\("([^"]+)",\s*"([^"]*)"\)"#, "environment"),
            (#"pm\.variables\.set\("([^"]+)",\s*"([^"]*)"\)"#, "local"),
        ]

        for (pattern, scope) in patterns {
            let values = capture(pattern, in: line)
            if values.count == 2 {
                assign(scope: scope, key: values[0], value: values[1], runtime: &runtime)
                logs.append("Set \(scope).\(values[0]) via compat mode")
                return true
            }
        }

        return false
    }

    private func assign(scope: String, key: String, value: String, runtime: inout ScriptRuntimeContext) {
        switch scope {
        case "globals", "global":
            runtime.globals[key] = value
        case "collection":
            runtime.collection[key] = value
        case "environment":
            runtime.environment[key] = value
        default:
            runtime.local[key] = value
        }
    }

    private func unset(scope: String, key: String, runtime: inout ScriptRuntimeContext) {
        switch scope {
        case "globals", "global":
            runtime.globals.removeValue(forKey: key)
        case "collection":
            runtime.collection.removeValue(forKey: key)
        case "environment":
            runtime.environment.removeValue(forKey: key)
        default:
            runtime.local.removeValue(forKey: key)
        }
    }

    private func stripQuotes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func capture(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return []
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func jsonValue(for path: String, body: String) -> Any? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let cleanPath = path.replacingOccurrences(of: "$.", with: "")
        let parts = cleanPath.split(separator: ".").map(String.init)
        return parts.reduce(object as Any?) { partial, segment in
            switch partial {
            case let dictionary as [String: Any]:
                return dictionary[segment]
            case let array as [Any]:
                return Int(segment).flatMap { array.indices.contains($0) ? array[$0] : nil }
            default:
                return nil
            }
        }
    }

    private func normalizeJSONValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }

        if let boolean = value as? Bool {
            return boolean ? "true" : "false"
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }

        if value is NSNull {
            return "null"
        }

        return String(describing: value)
    }

    private func stringValue(from value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let boolean as Bool:
            return boolean ? "true" : "false"
        case Optional<Any>.none:
            return ""
        default:
            return String(describing: value)
        }
    }

    private func makeJavaScriptBootstrap() -> String {
        """
        function __cryptoNormalize(value) {
          if (value && typeof value === "object" && value.__cryptoValue !== undefined) {
            return String(value.__cryptoValue);
          }
          return String(value);
        }

        function __cryptoEncoding(value) {
          if (value && typeof value === "object" && value.__cryptoEncoding !== undefined) {
            return String(value.__cryptoEncoding);
          }
          return "utf8";
        }

        function __pmScope(name) {
          return {
            get: function(key) { return __pmGet(name, key); },
            set: function(key, value) { __pmSet(name, key, value); },
            unset: function(key) { __pmUnset(name, key); }
          };
        }

        function __pmWrapRequest(request) {
          var headerList = Array.isArray(request.headers) ? request.headers.slice() : [];
          var queryItemList = Array.isArray(request.queryItems) ? request.queryItems.slice() : [];

          function syncHeaders() {
            var latest = __pmRequestHeadersList();
            headerList.length = 0;
            latest.forEach(function(entry) {
              headerList.push(entry);
            });
          }

          function syncQueryItems() {
            var latest = __pmRequestQueryItemsList();
            queryItemList.length = 0;
            latest.forEach(function(entry) {
              queryItemList.push(entry);
            });
          }

          headerList.get = function(key) {
            return __pmRequestHeaderGet(String(key));
          };
          headerList.has = function(key) {
            return __pmRequestHeaderHas(String(key));
          };
          headerList.set = function(key, value) {
            __pmRequestHeaderSet(String(key), value == null ? "" : String(value));
            syncHeaders();
            return headerList;
          };
          headerList.add = function(key, value) {
            __pmRequestHeaderAdd(String(key), value == null ? "" : String(value));
            syncHeaders();
            return headerList;
          };
          headerList.remove = function(key) {
            __pmRequestHeaderRemove(String(key));
            syncHeaders();
            return headerList;
          };
          headerList.all = function() {
            syncHeaders();
            return headerList.slice();
          };

          queryItemList.get = function(key) {
            return __pmRequestQueryItemGet(String(key));
          };
          queryItemList.has = function(key) {
            return __pmRequestQueryItemHas(String(key));
          };
          queryItemList.set = function(key, value) {
            __pmRequestQueryItemSet(String(key), value == null ? "" : String(value));
            syncQueryItems();
            return queryItemList;
          };
          queryItemList.add = function(key, value) {
            __pmRequestQueryItemAdd(String(key), value == null ? "" : String(value));
            syncQueryItems();
            return queryItemList;
          };
          queryItemList.remove = function(key) {
            __pmRequestQueryItemRemove(String(key));
            syncQueryItems();
            return queryItemList;
          };
          queryItemList.all = function() {
            syncQueryItems();
            return queryItemList.slice();
          };

          function makeBodyProxy() {
            var body = __pmRequestBodyGet();
            body = body && typeof body === "object" ? body : {};
            body.get = function() {
              return __pmRequestBodyGet();
            };
            body.set = function(value) {
              __pmRequestBodySet(value);
              request.body = makeBodyProxy();
              return request.body;
            };
            return body;
          }

          request.headers = headerList;
          request.queryItems = queryItemList;
          request.param = queryItemList;
          request.params = queryItemList;
          request.body = makeBodyProxy();
          return request;
        }

        function __pmMakeExpectation(actual) {
          function equals(expected, strict) {
            var matches = strict ? actual === expected : actual == expected;
            if (!matches) {
              throw new Error("Expected " + String(actual) + " to equal " + String(expected));
            }
          }

          return {
            to: {
              equal: function(expected) { equals(expected, true); },
              eql: function(expected) { equals(expected, false); },
              be: {
                true: function() {
                  if (actual !== true) { throw new Error("Expected true but got " + String(actual)); }
                },
                false: function() {
                  if (actual !== false) { throw new Error("Expected false but got " + String(actual)); }
                }
              }
            }
          };
        }

        var pm = {
          createEnvironment: function(name) { return __pmEnvironmentCreateAndActivate(String(name)); },
          createenvironment: function(name) { return __pmEnvironmentCreateAndActivate(String(name)); },
          setActiveEnvironment: function(nameOrId) { return __pmEnvironmentActivate(String(nameOrId)); },
          setactiveenvironment: function(nameOrId) { return __pmEnvironmentActivate(String(nameOrId)); },
          globals: __pmScope("globals"),
          collectionVariables: __pmScope("collection"),
          environment: Object.assign(__pmScope("environment"), {
            create: function(name) { return __pmEnvironmentCreate(String(name)); },
            select: function(nameOrId) { return __pmEnvironmentActivate(String(nameOrId)); },
            activate: function(nameOrId) { return __pmEnvironmentActivate(String(nameOrId)); },
            getActive: function() { return __pmEnvironmentGetActive(); },
            list: function() { return __pmEnvironmentList(); }
          }),
          variables: __pmScope("local"),
          websocket: {
            onMessage: function(handler) {
              __pmRegisterWebSocketHandler(handler);
            },
            onDone: function(handler) {
              __pmRegisterWebSocketDoneHandler(handler);
            },
            disconnect: function() {
              __pmDisconnectWebSocket();
            },
            message: {
              text: function() { return __pmIncomingMessage(); }
            },
            done: {
              cause: function() { return __pmDoneCause(); }
            }
          },
          response: {
            get code() { return __pmResponseCode(); },
            text: function() { return __pmResponseText(); },
            json: function() {
              var body = __pmResponseText();
              return body ? JSON.parse(body) : null;
            },
            to: {
              have: {
                status: function(expected) {
                  var actual = __pmResponseCode();
                  if (actual !== expected) {
                    throw new Error("Expected status " + expected + ", got " + actual);
                  }
                  __pmLog("PASS pm.response status " + expected);
                  return true;
                }
              }
            }
          },
          test: function(name, fn) {
            try {
              fn();
              __pmLog("PASS " + name);
            } catch (error) {
              __pmLog("FAIL " + name + ": " + String(error));
            }
          },
          expect: function(actual) {
            return __pmMakeExpectation(actual);
          },
          generarQR: function(value) { return __pmGenerarQR(String(value)); },
          generarqr: function(value) { return __pmGenerarQR(String(value)); }
        };

        pm.request = __pmWrapRequest(request);
        var responseBody = __pmResponseText();
        var responseCode = __pmResponseCode();

        var console = {
          log: function() {
            var text = Array.prototype.slice.call(arguments).map(function(value) {
              if (typeof value === "string") {
                return value;
              }
              try {
                return JSON.stringify(value);
              } catch (_error) {
                return String(value);
              }
            }).join(" ");
            __pmLog(text);
          }
        };

        var postman = {
          setEnvironmentVariable: function(key, value) { __pmSet("environment", key, value); },
          getEnvironmentVariable: function(key) { return __pmGet("environment", key); },
          clearEnvironmentVariable: function(key) { __pmUnset("environment", key); },
          createEnvironment: function(name) { return __pmEnvironmentCreate(String(name)); },
          setActiveEnvironment: function(nameOrId) { return __pmEnvironmentActivate(String(nameOrId)); },
          setGlobalVariable: function(key, value) { __pmSet("globals", key, value); },
          getGlobalVariable: function(key) { return __pmGet("globals", key); },
          clearGlobalVariable: function(key) { __pmUnset("globals", key); }
        };

        var utils = {};

        function btoa(value) {
          return __base64EncodeBinaryString(String(value));
        }

        function atob(value) {
          return __base64DecodeToBinaryString(String(value));
        }

        var CryptoJS = {
          enc: {
            Utf8: {
              parse: function(value) {
                return { __cryptoValue: String(value), __cryptoEncoding: "utf8" };
              }
            },
            Base64: {
              parse: function(value) {
                return { __cryptoValue: String(value), __cryptoEncoding: "base64" };
              }
            },
            Hex: { __encodingName: "hex" }
          },
          HmacSHA256: function(message, key) {
            var digest = __cryptoHmacSHA256(
              __cryptoNormalize(message),
              __cryptoNormalize(key),
              __cryptoEncoding(key)
            );
            return {
              toString: function(_encoding) {
                return digest;
              }
            };
          }
        };

        pm.crypto = {
          rsa: {
            encryptOAEP_SHA256: function(message, publicKeyPem) {
              return __cryptoRSAEncryptOAEP_SHA256(String(message), String(publicKeyPem));
            }
          },
          aes: {
            decryptCBCNoPaddingFromHex: function(keyBytes, ivValue, cipherHex) {
              return __cryptoAESDecryptCBCNoPaddingFromHex(keyBytes, ivValue, String(cipherHex));
            },
            encryptCBCNoPaddingToHex: function(keyBytes, ivValue, plainBytes) {
              return __cryptoAESEncryptCBCNoPaddingToHex(keyBytes, ivValue, plainBytes);
            },
            encryptECBNoPadding: function(keyBytes, plainBytes) {
              return __cryptoAESEncryptECBNoPadding(keyBytes, plainBytes);
            },
            decryptECBNoPadding: function(keyBytes, cipherBytes) {
              return __cryptoAESDecryptECBNoPadding(keyBytes, cipherBytes);
            }
          }
        };

        function encryptRsa(message, publicKeyPem) {
          return pm.crypto.rsa.encryptOAEP_SHA256(message, publicKeyPem);
        }
        """
    }

    private func executeJavaScript(
        script: ScriptDefinition,
        request: APIRequestModel?,
        utilities: [WorkspaceScriptUtility],
        runtime: inout ScriptRuntimeContext,
        logs: inout [String]
    ) -> Bool {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            logs.append("JavaScript runtime unavailable for script \(script.name).")
            return false
        }

        let bridge = JavaScriptRuntimeBridge(runtime: runtime, request: request)

        let logBlock: @convention(block) (String) -> Void = { message in
            bridge.logs.append(message)
        }
        let getBlock: @convention(block) (String, String) -> Any? = { scope, key in
            bridge.value(in: scope, for: key)
        }
        let setBlock: @convention(block) (String, String, Any?) -> Void = { scope, key, value in
            bridge.setValue(stringValue(from: value), in: scope, for: key)
        }
        let unsetBlock: @convention(block) (String, String) -> Void = { scope, key in
            bridge.unsetValue(in: scope, for: key)
        }
        let environmentCreateBlock: @convention(block) (String) -> String = { name in
            bridge.createEnvironment(named: name).uuidString
        }
        let environmentCreateAndActivateBlock: @convention(block) (String) -> String = { name in
            bridge.createEnvironment(named: name, shouldActivate: true).uuidString
        }
        let environmentActivateBlock: @convention(block) (String) -> Bool = { identifierOrName in
            bridge.activateEnvironment(matching: identifierOrName)
        }
        let environmentGetActiveBlock: @convention(block) () -> [String: Any] = {
            bridge.activeEnvironmentPayload()
        }
        let environmentListBlock: @convention(block) () -> [[String: Any]] = {
            bridge.environmentListPayload()
        }
        let requestHeadersListBlock: @convention(block) () -> [[String: Any]] = {
            bridge.requestHeadersPayload()
        }
        let requestQueryItemsListBlock: @convention(block) () -> [[String: Any]] = {
            bridge.requestQueryItemsPayload()
        }
        let requestHeaderGetBlock: @convention(block) (String) -> String = { key in
            bridge.requestHeaderValue(for: key) ?? ""
        }
        let requestQueryItemGetBlock: @convention(block) (String) -> String = { key in
            bridge.requestQueryItemValue(for: key) ?? ""
        }
        let requestHeaderHasBlock: @convention(block) (String) -> Bool = { key in
            bridge.requestHeaderValue(for: key) != nil
        }
        let requestQueryItemHasBlock: @convention(block) (String) -> Bool = { key in
            bridge.requestQueryItemValue(for: key) != nil
        }
        let requestHeaderSetBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.setRequestHeader(named: key, value: value)
        }
        let requestQueryItemSetBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.setRequestQueryItem(named: key, value: value)
        }
        let requestHeaderAddBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.addRequestHeader(named: key, value: value)
        }
        let requestQueryItemAddBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.addRequestQueryItem(named: key, value: value)
        }
        let requestHeaderRemoveBlock: @convention(block) (String) -> Void = { key in
            bridge.removeRequestHeader(named: key)
        }
        let requestQueryItemRemoveBlock: @convention(block) (String) -> Void = { key in
            bridge.removeRequestQueryItem(named: key)
        }
        let requestBodyGetBlock: @convention(block) () -> [String: Any] = {
            bridge.requestBodyPayload()
        }
        let requestBodySetBlock: @convention(block) (Any?) -> Void = { value in
            bridge.setRequestBody(value)
        }
        let responseCodeBlock: @convention(block) () -> Int = {
            bridge.runtime.response?.statusCode ?? -1
        }
        let responseTextBlock: @convention(block) () -> String = {
            bridge.runtime.response?.body ?? ""
        }
        let incomingMessageBlock: @convention(block) () -> String = {
            bridge.runtime.webSocketMessage ?? ""
        }
        let doneCauseBlock: @convention(block) () -> String = {
            bridge.runtime.webSocketDoneCause ?? ""
        }
        let registerWebSocketHandlerBlock: @convention(block) (JSValue) -> Void = { handler in
            bridge.webSocketMessageHandler = handler
        }
        let registerWebSocketDoneHandlerBlock: @convention(block) (JSValue) -> Void = { handler in
            bridge.webSocketDoneHandler = handler
        }
        let disconnectWebSocketBlock: @convention(block) () -> Void = {
            bridge.runtime.webSocketShouldDisconnect = true
        }
        let cryptoHmacSHA256Block: @convention(block) (String, String, String) -> String = { message, key, keyEncoding in
            hmacSHA256Hex(message: message, key: key, keyEncoding: keyEncoding)
        }
        let cryptoRSAEncryptBlock: @convention(block) (String, String) -> String = { message, publicKeyPem in
            rsaEncryptOAEP_SHA256Hex(message: message, publicKeyPEM: publicKeyPem) ?? ""
        }
        let base64EncodeBlock: @convention(block) (String) -> String = { value in
            base64EncodeBinaryString(value)
        }
        let base64DecodeBlock: @convention(block) (String) -> String = { value in
            base64DecodeToBinaryString(value)
        }
        let cryptoAESDecryptCBCBlock: @convention(block) (Any?, Any?, String?) -> [NSNumber] = { keyValue, ivValue, cipherHex in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let ivData = data(fromJavaScriptBytesOrString: ivValue),
                let cipherHex,
                let cipherData = data(fromHex: cipherHex),
                let decrypted = aesCBCNoPadding(
                    operation: CCOperation(kCCDecrypt),
                    key: keyData,
                    iv: ivData,
                    input: cipherData
                )
            else {
                return []
            }

            return decrypted.map { NSNumber(value: $0) }
        }
        let cryptoAESEncryptCBCBlock: @convention(block) (Any?, Any?, Any?) -> String = { keyValue, ivValue, plainValue in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let ivData = data(fromJavaScriptBytesOrString: ivValue),
                let plainData = data(fromJavaScriptBytes: plainValue),
                let encrypted = aesCBCNoPadding(
                    operation: CCOperation(kCCEncrypt),
                    key: keyData,
                    iv: ivData,
                    input: plainData
                )
            else {
                return ""
            }

            return hexString(from: encrypted)
        }
        let cryptoAESEncryptECBBlock: @convention(block) (Any?, Any?) -> [NSNumber] = { keyValue, plainValue in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let plainData = data(fromJavaScriptBytes: plainValue),
                let encrypted = aesECBNoPaddingEncrypt(
                    key: keyData,
                    input: plainData
                )
            else {
                return []
            }

            return encrypted.map { NSNumber(value: $0) }
        }
        let cryptoAESDecryptECBBlock: @convention(block) (Any?, Any?) -> [NSNumber] = { keyValue, cipherValue in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let cipherData = data(fromJavaScriptBytes: cipherValue),
                let decrypted = aesECBNoPaddingDecrypt(
                    key: keyData,
                    input: cipherData
                )
            else {
                return []
            }

            return decrypted.map { NSNumber(value: $0) }
        }

        let generarQRBlock: @convention(block) (String) -> String = { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                bridge.logs.append("pm.generarqr: no se pudo generar el QR (texto vacío o error de render).")
                return ""
            }
            guard let pngURL = PMQRCodeConsoleRenderer.writeQRPNGToTemporaryFile(for: raw) else {
                bridge.logs.append("pm.generarqr: no se pudo generar el PNG del QR.")
                return ""
            }
            bridge.logs.append(WorkspaceFlowInlineImageLogLine.encode(fileURL: pngURL, caption: "QR (pm.generarqr)"))
            return trimmed
        }

        context.setObject(logBlock, forKeyedSubscript: "__pmLog" as NSString)
        context.setObject(generarQRBlock, forKeyedSubscript: "__pmGenerarQR" as NSString)
        context.setObject(getBlock, forKeyedSubscript: "__pmGet" as NSString)
        context.setObject(setBlock, forKeyedSubscript: "__pmSet" as NSString)
        context.setObject(unsetBlock, forKeyedSubscript: "__pmUnset" as NSString)
        context.setObject(responseCodeBlock, forKeyedSubscript: "__pmResponseCode" as NSString)
        context.setObject(responseTextBlock, forKeyedSubscript: "__pmResponseText" as NSString)
        context.setObject(incomingMessageBlock, forKeyedSubscript: "__pmIncomingMessage" as NSString)
        context.setObject(doneCauseBlock, forKeyedSubscript: "__pmDoneCause" as NSString)
        context.setObject(registerWebSocketHandlerBlock, forKeyedSubscript: "__pmRegisterWebSocketHandler" as NSString)
        context.setObject(registerWebSocketDoneHandlerBlock, forKeyedSubscript: "__pmRegisterWebSocketDoneHandler" as NSString)
        context.setObject(disconnectWebSocketBlock, forKeyedSubscript: "__pmDisconnectWebSocket" as NSString)
        context.setObject(environmentCreateBlock, forKeyedSubscript: "__pmEnvironmentCreate" as NSString)
        context.setObject(environmentCreateAndActivateBlock, forKeyedSubscript: "__pmEnvironmentCreateAndActivate" as NSString)
        context.setObject(environmentActivateBlock, forKeyedSubscript: "__pmEnvironmentActivate" as NSString)
        context.setObject(environmentGetActiveBlock, forKeyedSubscript: "__pmEnvironmentGetActive" as NSString)
        context.setObject(environmentListBlock, forKeyedSubscript: "__pmEnvironmentList" as NSString)
        context.setObject(requestHeadersListBlock, forKeyedSubscript: "__pmRequestHeadersList" as NSString)
        context.setObject(requestQueryItemsListBlock, forKeyedSubscript: "__pmRequestQueryItemsList" as NSString)
        context.setObject(requestHeaderGetBlock, forKeyedSubscript: "__pmRequestHeaderGet" as NSString)
        context.setObject(requestQueryItemGetBlock, forKeyedSubscript: "__pmRequestQueryItemGet" as NSString)
        context.setObject(requestHeaderHasBlock, forKeyedSubscript: "__pmRequestHeaderHas" as NSString)
        context.setObject(requestQueryItemHasBlock, forKeyedSubscript: "__pmRequestQueryItemHas" as NSString)
        context.setObject(requestHeaderSetBlock, forKeyedSubscript: "__pmRequestHeaderSet" as NSString)
        context.setObject(requestQueryItemSetBlock, forKeyedSubscript: "__pmRequestQueryItemSet" as NSString)
        context.setObject(requestHeaderAddBlock, forKeyedSubscript: "__pmRequestHeaderAdd" as NSString)
        context.setObject(requestQueryItemAddBlock, forKeyedSubscript: "__pmRequestQueryItemAdd" as NSString)
        context.setObject(requestHeaderRemoveBlock, forKeyedSubscript: "__pmRequestHeaderRemove" as NSString)
        context.setObject(requestQueryItemRemoveBlock, forKeyedSubscript: "__pmRequestQueryItemRemove" as NSString)
        context.setObject(requestBodyGetBlock, forKeyedSubscript: "__pmRequestBodyGet" as NSString)
        context.setObject(requestBodySetBlock, forKeyedSubscript: "__pmRequestBodySet" as NSString)
        context.setObject(cryptoHmacSHA256Block, forKeyedSubscript: "__cryptoHmacSHA256" as NSString)
        context.setObject(cryptoRSAEncryptBlock, forKeyedSubscript: "__cryptoRSAEncryptOAEP_SHA256" as NSString)
        context.setObject(base64EncodeBlock, forKeyedSubscript: "__base64EncodeBinaryString" as NSString)
        context.setObject(base64DecodeBlock, forKeyedSubscript: "__base64DecodeToBinaryString" as NSString)
        context.setObject(cryptoAESDecryptCBCBlock, forKeyedSubscript: "__cryptoAESDecryptCBCNoPaddingFromHex" as NSString)
        context.setObject(cryptoAESEncryptCBCBlock, forKeyedSubscript: "__cryptoAESEncryptCBCNoPaddingToHex" as NSString)
        context.setObject(cryptoAESEncryptECBBlock, forKeyedSubscript: "__cryptoAESEncryptECBNoPadding" as NSString)
        context.setObject(cryptoAESDecryptECBBlock, forKeyedSubscript: "__cryptoAESDecryptECBNoPadding" as NSString)
        context.setObject(makeRequestObject(from: request, runtime: bridge.runtime), forKeyedSubscript: "request" as NSString)

        setJavaScriptExceptionHandler(
            for: context,
            bridge: bridge,
            sourceName: "JavaScript bootstrap",
            source: makeJavaScriptBootstrap()
        )
        _ = context.evaluateScript(makeJavaScriptBootstrap())
        for utility in utilities where utility.isEnabled && isJavaScriptLanguage(utility.language) {
            setJavaScriptExceptionHandler(
                for: context,
                bridge: bridge,
                sourceName: "utility \(utility.name)",
                source: utility.source
            )
            _ = context.evaluateScript(utility.source, withSourceURL: URL(fileURLWithPath: "/workspace-utility/\(utility.name).js"))
            if let alias = utilityNamespaceAliasScript(for: utility) {
                setJavaScriptExceptionHandler(
                    for: context,
                    bridge: bridge,
                    sourceName: "utility \(utility.name) alias",
                    source: alias
                )
                _ = context.evaluateScript(alias)
            }
        }
        setJavaScriptExceptionHandler(
            for: context,
            bridge: bridge,
            sourceName: script.name,
            source: script.source
        )
        _ = context.evaluateScript(script.source, withSourceURL: URL(fileURLWithPath: "/request-script/\(script.name).js"))
        if bridge.runtime.webSocketMessage?.isEmpty == false,
           let handler = bridge.webSocketMessageHandler {
            setJavaScriptExceptionHandler(
                for: context,
                bridge: bridge,
                sourceName: script.name,
                source: script.source
            )
            _ = handler.call(withArguments: [bridge.runtime.webSocketMessage ?? ""])
        }
        if bridge.runtime.webSocketDoneCause?.isEmpty == false,
           let handler = bridge.webSocketDoneHandler {
            setJavaScriptExceptionHandler(
                for: context,
                bridge: bridge,
                sourceName: script.name,
                source: script.source
            )
            _ = handler.call(withArguments: [bridge.runtime.webSocketDoneCause ?? ""])
        }

        runtime = bridge.runtime
        logs.append(contentsOf: bridge.logs)
        return true
        #else
        logs.append("JavaScriptCore is not available on this platform.")
        return false
        #endif
    }

    public func evaluateTemplateExpression(
        _ expression: String,
        runtime: ScriptRuntimeContext,
        request: APIRequestModel? = nil,
        utilities: [WorkspaceScriptUtility] = []
    ) -> String? {
        evaluateTemplateExpressionReport(
            expression,
            runtime: runtime,
            request: request,
            utilities: utilities
        )?.value
    }

    public func evaluateTemplateExpressionReport(
        _ expression: String,
        runtime: ScriptRuntimeContext,
        request: APIRequestModel? = nil,
        utilities: [WorkspaceScriptUtility] = []
    ) -> TemplateExpressionEvaluationReport? {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            return nil
        }

        let bridge = JavaScriptRuntimeBridge(runtime: runtime, request: request)

        let logBlock: @convention(block) (String) -> Void = { message in
            bridge.logs.append(message)
        }
        let getBlock: @convention(block) (String, String) -> Any? = { scope, key in
            switch scope {
            case "globals":
                return bridge.runtime.globals[key]
            case "collection":
                return bridge.runtime.collection[key]
            case "environment":
                return bridge.runtime.environment[key]
            default:
                return bridge.runtime.local[key]
            }
        }
        let setBlock: @convention(block) (String, String, Any?) -> Void = { scope, key, value in
            let text = stringValue(from: value)
            switch scope {
            case "globals":
                bridge.runtime.globals[key] = text
            case "collection":
                bridge.runtime.collection[key] = text
            case "environment":
                bridge.runtime.environment[key] = text
            default:
                bridge.runtime.local[key] = text
            }
        }
        let unsetBlock: @convention(block) (String, String) -> Void = { scope, key in
            switch scope {
            case "globals":
                bridge.runtime.globals.removeValue(forKey: key)
            case "collection":
                bridge.runtime.collection.removeValue(forKey: key)
            case "environment":
                bridge.runtime.environment.removeValue(forKey: key)
            default:
                bridge.runtime.local.removeValue(forKey: key)
            }
        }
        let environmentCreateBlock: @convention(block) (String) -> String = { name in
            bridge.createEnvironment(named: name).uuidString
        }
        let environmentCreateAndActivateBlock: @convention(block) (String) -> String = { name in
            bridge.createEnvironment(named: name, shouldActivate: true).uuidString
        }
        let environmentActivateBlock: @convention(block) (String) -> Bool = { identifierOrName in
            bridge.activateEnvironment(matching: identifierOrName)
        }
        let environmentGetActiveBlock: @convention(block) () -> [String: Any] = {
            bridge.activeEnvironmentPayload()
        }
        let environmentListBlock: @convention(block) () -> [[String: Any]] = {
            bridge.environmentListPayload()
        }
        let requestHeadersListBlock: @convention(block) () -> [[String: Any]] = {
            bridge.requestHeadersPayload()
        }
        let requestQueryItemsListBlock: @convention(block) () -> [[String: Any]] = {
            bridge.requestQueryItemsPayload()
        }
        let requestHeaderGetBlock: @convention(block) (String) -> String = { key in
            bridge.requestHeaderValue(for: key) ?? ""
        }
        let requestQueryItemGetBlock: @convention(block) (String) -> String = { key in
            bridge.requestQueryItemValue(for: key) ?? ""
        }
        let requestHeaderHasBlock: @convention(block) (String) -> Bool = { key in
            bridge.requestHeaderValue(for: key) != nil
        }
        let requestQueryItemHasBlock: @convention(block) (String) -> Bool = { key in
            bridge.requestQueryItemValue(for: key) != nil
        }
        let requestHeaderSetBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.setRequestHeader(named: key, value: value)
        }
        let requestQueryItemSetBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.setRequestQueryItem(named: key, value: value)
        }
        let requestHeaderAddBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.addRequestHeader(named: key, value: value)
        }
        let requestQueryItemAddBlock: @convention(block) (String, String) -> Void = { key, value in
            bridge.addRequestQueryItem(named: key, value: value)
        }
        let requestHeaderRemoveBlock: @convention(block) (String) -> Void = { key in
            bridge.removeRequestHeader(named: key)
        }
        let requestQueryItemRemoveBlock: @convention(block) (String) -> Void = { key in
            bridge.removeRequestQueryItem(named: key)
        }
        let requestBodyGetBlock: @convention(block) () -> [String: Any] = {
            bridge.requestBodyPayload()
        }
        let requestBodySetBlock: @convention(block) (Any?) -> Void = { value in
            bridge.setRequestBody(value)
        }
        let responseCodeBlock: @convention(block) () -> Int = {
            bridge.runtime.response?.statusCode ?? -1
        }
        let responseTextBlock: @convention(block) () -> String = {
            bridge.runtime.response?.body ?? ""
        }
        let incomingMessageBlock: @convention(block) () -> String = {
            bridge.runtime.webSocketMessage ?? ""
        }
        let doneCauseBlock: @convention(block) () -> String = {
            bridge.runtime.webSocketDoneCause ?? ""
        }
        let registerWebSocketHandlerBlock: @convention(block) (JSValue) -> Void = { handler in
            bridge.webSocketMessageHandler = handler
        }
        let registerWebSocketDoneHandlerBlock: @convention(block) (JSValue) -> Void = { handler in
            bridge.webSocketDoneHandler = handler
        }
        let disconnectWebSocketBlock: @convention(block) () -> Void = {
            bridge.runtime.webSocketShouldDisconnect = true
        }
        let cryptoHmacSHA256Block: @convention(block) (String, String, String) -> String = { message, key, keyEncoding in
            hmacSHA256Hex(message: message, key: key, keyEncoding: keyEncoding)
        }
        let cryptoRSAEncryptBlock: @convention(block) (String, String) -> String = { message, publicKeyPem in
            rsaEncryptOAEP_SHA256Hex(message: message, publicKeyPEM: publicKeyPem) ?? ""
        }
        let base64EncodeBlock: @convention(block) (String) -> String = { value in
            base64EncodeBinaryString(value)
        }
        let base64DecodeBlock: @convention(block) (String) -> String = { value in
            base64DecodeToBinaryString(value)
        }
        let cryptoAESDecryptCBCBlock: @convention(block) (Any?, Any?, String?) -> [NSNumber] = { keyValue, ivValue, cipherHex in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let ivData = data(fromJavaScriptBytesOrString: ivValue),
                let cipherHex,
                let cipherData = data(fromHex: cipherHex),
                let decrypted = aesCBCNoPadding(
                    operation: CCOperation(kCCDecrypt),
                    key: keyData,
                    iv: ivData,
                    input: cipherData
                )
            else {
                return []
            }

            return decrypted.map { NSNumber(value: $0) }
        }
        let cryptoAESEncryptCBCBlock: @convention(block) (Any?, Any?, Any?) -> String = { keyValue, ivValue, plainValue in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let ivData = data(fromJavaScriptBytesOrString: ivValue),
                let plainData = data(fromJavaScriptBytes: plainValue),
                let encrypted = aesCBCNoPadding(
                    operation: CCOperation(kCCEncrypt),
                    key: keyData,
                    iv: ivData,
                    input: plainData
                )
            else {
                return ""
            }

            return hexString(from: encrypted)
        }
        let cryptoAESEncryptECBBlock: @convention(block) (Any?, Any?) -> [NSNumber] = { keyValue, plainValue in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let plainData = data(fromJavaScriptBytes: plainValue),
                let encrypted = aesECBNoPaddingEncrypt(
                    key: keyData,
                    input: plainData
                )
            else {
                return []
            }

            return encrypted.map { NSNumber(value: $0) }
        }
        let cryptoAESDecryptECBBlock: @convention(block) (Any?, Any?) -> [NSNumber] = { keyValue, cipherValue in
            guard
                let keyData = data(fromJavaScriptBytes: keyValue),
                let cipherData = data(fromJavaScriptBytes: cipherValue),
                let decrypted = aesECBNoPaddingDecrypt(
                    key: keyData,
                    input: cipherData
                )
            else {
                return []
            }

            return decrypted.map { NSNumber(value: $0) }
        }

        let generarQRBlock: @convention(block) (String) -> String = { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                bridge.logs.append("pm.generarqr: no se pudo generar el QR (texto vacío o error de render).")
                return ""
            }
            guard let pngURL = PMQRCodeConsoleRenderer.writeQRPNGToTemporaryFile(for: raw) else {
                bridge.logs.append("pm.generarqr: no se pudo generar el PNG del QR.")
                return ""
            }
            bridge.logs.append(WorkspaceFlowInlineImageLogLine.encode(fileURL: pngURL, caption: "QR (pm.generarqr)"))
            return trimmed
        }

        context.setObject(logBlock, forKeyedSubscript: "__pmLog" as NSString)
        context.setObject(generarQRBlock, forKeyedSubscript: "__pmGenerarQR" as NSString)
        context.setObject(getBlock, forKeyedSubscript: "__pmGet" as NSString)
        context.setObject(setBlock, forKeyedSubscript: "__pmSet" as NSString)
        context.setObject(unsetBlock, forKeyedSubscript: "__pmUnset" as NSString)
        context.setObject(responseCodeBlock, forKeyedSubscript: "__pmResponseCode" as NSString)
        context.setObject(responseTextBlock, forKeyedSubscript: "__pmResponseText" as NSString)
        context.setObject(incomingMessageBlock, forKeyedSubscript: "__pmIncomingMessage" as NSString)
        context.setObject(doneCauseBlock, forKeyedSubscript: "__pmDoneCause" as NSString)
        context.setObject(registerWebSocketHandlerBlock, forKeyedSubscript: "__pmRegisterWebSocketHandler" as NSString)
        context.setObject(registerWebSocketDoneHandlerBlock, forKeyedSubscript: "__pmRegisterWebSocketDoneHandler" as NSString)
        context.setObject(disconnectWebSocketBlock, forKeyedSubscript: "__pmDisconnectWebSocket" as NSString)
        context.setObject(environmentCreateBlock, forKeyedSubscript: "__pmEnvironmentCreate" as NSString)
        context.setObject(environmentCreateAndActivateBlock, forKeyedSubscript: "__pmEnvironmentCreateAndActivate" as NSString)
        context.setObject(environmentActivateBlock, forKeyedSubscript: "__pmEnvironmentActivate" as NSString)
        context.setObject(environmentGetActiveBlock, forKeyedSubscript: "__pmEnvironmentGetActive" as NSString)
        context.setObject(environmentListBlock, forKeyedSubscript: "__pmEnvironmentList" as NSString)
        context.setObject(requestHeadersListBlock, forKeyedSubscript: "__pmRequestHeadersList" as NSString)
        context.setObject(requestQueryItemsListBlock, forKeyedSubscript: "__pmRequestQueryItemsList" as NSString)
        context.setObject(requestHeaderGetBlock, forKeyedSubscript: "__pmRequestHeaderGet" as NSString)
        context.setObject(requestQueryItemGetBlock, forKeyedSubscript: "__pmRequestQueryItemGet" as NSString)
        context.setObject(requestHeaderHasBlock, forKeyedSubscript: "__pmRequestHeaderHas" as NSString)
        context.setObject(requestQueryItemHasBlock, forKeyedSubscript: "__pmRequestQueryItemHas" as NSString)
        context.setObject(requestHeaderSetBlock, forKeyedSubscript: "__pmRequestHeaderSet" as NSString)
        context.setObject(requestQueryItemSetBlock, forKeyedSubscript: "__pmRequestQueryItemSet" as NSString)
        context.setObject(requestHeaderAddBlock, forKeyedSubscript: "__pmRequestHeaderAdd" as NSString)
        context.setObject(requestQueryItemAddBlock, forKeyedSubscript: "__pmRequestQueryItemAdd" as NSString)
        context.setObject(requestHeaderRemoveBlock, forKeyedSubscript: "__pmRequestHeaderRemove" as NSString)
        context.setObject(requestQueryItemRemoveBlock, forKeyedSubscript: "__pmRequestQueryItemRemove" as NSString)
        context.setObject(requestBodyGetBlock, forKeyedSubscript: "__pmRequestBodyGet" as NSString)
        context.setObject(requestBodySetBlock, forKeyedSubscript: "__pmRequestBodySet" as NSString)
        context.setObject(cryptoHmacSHA256Block, forKeyedSubscript: "__cryptoHmacSHA256" as NSString)
        context.setObject(cryptoRSAEncryptBlock, forKeyedSubscript: "__cryptoRSAEncryptOAEP_SHA256" as NSString)
        context.setObject(base64EncodeBlock, forKeyedSubscript: "__base64EncodeBinaryString" as NSString)
        context.setObject(base64DecodeBlock, forKeyedSubscript: "__base64DecodeToBinaryString" as NSString)
        context.setObject(cryptoAESDecryptCBCBlock, forKeyedSubscript: "__cryptoAESDecryptCBCNoPaddingFromHex" as NSString)
        context.setObject(cryptoAESEncryptCBCBlock, forKeyedSubscript: "__cryptoAESEncryptCBCNoPaddingToHex" as NSString)
        context.setObject(cryptoAESEncryptECBBlock, forKeyedSubscript: "__cryptoAESEncryptECBNoPadding" as NSString)
        context.setObject(cryptoAESDecryptECBBlock, forKeyedSubscript: "__cryptoAESDecryptECBNoPadding" as NSString)
        context.setObject(makeRequestObject(from: request, runtime: bridge.runtime), forKeyedSubscript: "request" as NSString)

        setJavaScriptExceptionHandler(
            for: context,
            bridge: bridge,
            sourceName: "JavaScript bootstrap",
            source: makeJavaScriptBootstrap()
        )
        _ = context.evaluateScript(makeJavaScriptBootstrap())
        for utility in utilities where utility.isEnabled && isJavaScriptLanguage(utility.language) {
            setJavaScriptExceptionHandler(
                for: context,
                bridge: bridge,
                sourceName: "utility \(utility.name)",
                source: utility.source
            )
            _ = context.evaluateScript(utility.source, withSourceURL: URL(fileURLWithPath: "/workspace-utility/\(utility.name).js"))
            if let alias = utilityNamespaceAliasScript(for: utility) {
                setJavaScriptExceptionHandler(
                    for: context,
                    bridge: bridge,
                    sourceName: "utility \(utility.name) alias",
                    source: alias
                )
                _ = context.evaluateScript(alias)
            }
        }

        let wrappedExpression = """
        (function() {
            var __pmTemplateValue = (\(expression));
            if (__pmTemplateValue === undefined || __pmTemplateValue === null) { return ""; }
            if (typeof __pmTemplateValue === "string") { return __pmTemplateValue; }
            if (typeof __pmTemplateValue === "object") { return JSON.stringify(__pmTemplateValue); }
            return String(__pmTemplateValue);
        })()
        """

        setJavaScriptExceptionHandler(
            for: context,
            bridge: bridge,
            sourceName: "template expression",
            source: wrappedExpression
        )
        let value = context.evaluateScript(wrappedExpression)?.toString()
        return TemplateExpressionEvaluationReport(
            value: value,
            runtime: bridge.runtime,
            logs: bridge.logs
        )
        #else
        return nil
        #endif
    }

    private func makeRequestObject(from request: APIRequestModel?, runtime: ScriptRuntimeContext) -> [String: Any] {
        guard let request else {
            return [:]
        }

        let resolver = VariableResolver()
        let context = VariableResolutionContext(
            globals: variables(from: runtime.globals),
            collection: variables(from: runtime.collection),
            environment: variables(from: runtime.environment),
            local: keyValues(from: runtime.local)
        )

        let effectiveHeaders = runtime.requestHeaders ?? request.headers
        let effectiveQueryItems = runtime.requestQueryItems ?? request.queryItems
        let effectiveBody = runtime.requestBody ?? request.body

        return [
            "name": request.name,
            "method": request.method.rawValue,
            "url": resolver.resolve(request.url, context: context),
            "urlTemplate": request.url,
            "headers": effectiveHeaders
                .filter(\.isEnabled)
                .map {
                    [
                        "key": $0.key,
                        "value": resolver.resolve($0.value, context: context),
                    ]
                },
            "queryItems": effectiveQueryItems
                .filter(\.isEnabled)
                .map {
                    [
                        "key": $0.key,
                        "value": resolver.resolve($0.value, context: context),
                    ]
                },
            "pathVariables": request.pathVariables
                .filter(\.isEnabled)
                .map {
                    [
                        "key": $0.key,
                        "value": resolver.resolve($0.value, context: context),
                    ]
                },
            "cookies": request.cookies
                .filter(\.isEnabled)
                .map {
                    [
                        "key": $0.key,
                        "value": resolver.resolve($0.value, context: context),
                    ]
                },
            "body": [
                "kind": effectiveBody.kind.rawValue,
                "raw": resolver.resolve(effectiveBody.raw, context: context),
                "rawTemplate": effectiveBody.raw,
                "parameters": effectiveBody.parameters
                    .filter(\.isEnabled)
                    .map {
                        [
                            "key": $0.key,
                            "value": resolver.resolve($0.value, context: context),
                        ]
                    },
            ],
        ]
    }

    private func variables(from dictionary: [String: String]) -> [VariableValue] {
        dictionary.keys.sorted().map { key in
            VariableValue(key: key, value: dictionary[key] ?? "")
        }
    }

    private func keyValues(from dictionary: [String: String]) -> [KeyValueEntry] {
        dictionary.keys.sorted().map { key in
            KeyValueEntry(key: key, value: dictionary[key] ?? "")
        }
    }

    private func hmacSHA256Hex(message: String, key: String, keyEncoding: String) -> String {
        #if canImport(CryptoKit)
        let messageData = Data(message.utf8)
        let keyData: Data

        if keyEncoding == "base64", let decoded = Data(base64Encoded: key) {
            keyData = decoded
        } else {
            keyData = Data(key.utf8)
        }

        let symmetricKey = SymmetricKey(data: keyData)
        let digest = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    private func data(fromJavaScriptBytes value: Any) -> Data? {
        if let data = value as? Data {
            return data
        }
        if let bytes = value as? [NSNumber] {
            return Data(bytes.map(\.uint8Value))
        }
        if let bytes = value as? [Int] {
            return Data(bytes.map { UInt8(clamping: $0) })
        }
        if let bytes = value as? [UInt8] {
            return Data(bytes)
        }
        if let array = value as? [Any] {
            let bytes = array.compactMap { element -> UInt8? in
                if let number = element as? NSNumber {
                    return number.uint8Value
                }
                if let number = element as? Int {
                    return UInt8(clamping: number)
                }
                return nil
            }
            return bytes.count == array.count ? Data(bytes) : nil
        }
        if let text = value as? String {
            return Data(text.utf8)
        }
        return nil
    }

    private func base64EncodeBinaryString(_ value: String) -> String {
        guard let data = value.data(using: .isoLatin1, allowLossyConversion: false) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private func base64DecodeToBinaryString(_ value: String) -> String {
        guard
            let data = Data(base64Encoded: value),
            let text = String(data: data, encoding: .isoLatin1)
        else {
            return ""
        }
        return text
    }

    private func data(fromJavaScriptBytesOrString value: Any) -> Data? {
        if let text = value as? String {
            return Data(text.utf8)
        }
        return data(fromJavaScriptBytes: value)
    }

    private func data(fromHex hex: String) -> Data? {
        let cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanHex.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: cleanHex.count / 2)
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            guard let byte = UInt8(cleanHex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    private func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func aesCBCNoPadding(operation: CCOperation, key: Data, iv: Data, input: Data) -> Data? {
        aesCrypt(
            operation: operation,
            key: key,
            iv: iv,
            input: input,
            options: CCOptions(0)
        )
    }

    private func aesECBNoPaddingEncrypt(key: Data, input: Data) -> Data? {
        aesCrypt(
            operation: CCOperation(kCCEncrypt),
            key: key,
            iv: nil,
            input: input,
            options: CCOptions(kCCOptionECBMode)
        )
    }

    private func aesECBNoPaddingDecrypt(key: Data, input: Data) -> Data? {
        aesCrypt(
            operation: CCOperation(kCCDecrypt),
            key: key,
            iv: nil,
            input: input,
            options: CCOptions(kCCOptionECBMode)
        )
    }

    private func aesCrypt(
        operation: CCOperation,
        key: Data,
        iv: Data?,
        input: Data,
        options: CCOptions
    ) -> Data? {
        #if canImport(CommonCrypto)
        guard input.count.isMultiple(of: kCCBlockSizeAES128) else {
            return nil
        }
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) else {
            return nil
        }
        if options & CCOptions(kCCOptionECBMode) == 0,
           iv?.count != kCCBlockSizeAES128 {
            return nil
        }

        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(
                                operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBytes.baseAddress,
                                key.count,
                                ivBytes.baseAddress,
                                inputBytes.baseAddress,
                                input.count,
                                outputBytes.baseAddress,
                                outputCapacity,
                                &outputLength
                            )
                        }
                    }

                    return CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        input.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        output.removeSubrange(outputLength..<output.count)
        return output
        #else
        return nil
        #endif
    }

    private func rsaEncryptOAEP_SHA256Hex(message: String, publicKeyPEM: String) -> String? {
        #if canImport(Security)
        guard let publicKey = makeRSAPublicKey(from: publicKeyPEM) else {
            return nil
        }

        let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            return nil
        }

        let messageData = Data(message.utf8) as CFData
        var error: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(publicKey, algorithm, messageData, &error) as Data? else {
            return nil
        }

        return encryptedData.map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    private func makeRSAPublicKey(from pem: String) -> SecKey? {
        #if canImport(Security)
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("BEGIN CERTIFICATE"),
           let certificateData = decodePEMBody(trimmed),
           let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) {
            return SecCertificateCopyKey(certificate)
        }

        guard let keyData = decodePEMBody(trimmed) else {
            return nil
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: keyData.count * 8,
        ]

        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error)
        #else
        return nil
        #endif
    }

    private func decodePEMBody(_ pem: String) -> Data? {
        let lines = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----BEGIN ") && !$0.hasPrefix("-----END ") }
        let base64 = lines.joined()
        return Data(base64Encoded: base64)
    }

    private func setJavaScriptExceptionHandler(
        for context: JSContext,
        bridge: JavaScriptRuntimeBridge,
        sourceName: String,
        source: String
    ) {
        context.exceptionHandler = { _, exception in
            bridge.logs.append(self.formattedJavaScriptError(exception, sourceName: sourceName, source: source))
        }
    }

    private func formattedJavaScriptError(_ exception: JSValue?, sourceName: String, source: String) -> String {
        let rawMessage = exception?.forProperty("message")?.toString()
            ?? exception?.toString()
            ?? "Unknown error"
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let stack = exception?.forProperty("stack")?.toString()
        let parsedLocation = javaScriptErrorLocation(from: stack)
        let line = jsInt(from: exception?.forProperty("line")) ?? parsedLocation.line
        let column = jsInt(from: exception?.forProperty("column")) ?? parsedLocation.column
        let functionName = javaScriptFunctionName(from: stack) ?? javaScriptFunctionName(in: source, line: line)

        var details: [String] = []
        if let functionName, !functionName.isEmpty {
            details.append("function \(functionName)")
        }
        if let line {
            if let column {
                details.append("line \(line):\(column)")
            } else {
                details.append("line \(line)")
            }
        }

        if details.isEmpty {
            return "JavaScript error in \(sourceName): \(message)"
        }

        return "JavaScript error in \(sourceName): \(message) at \(details.joined(separator: ", "))"
    }

    private func jsInt(from value: JSValue?) -> Int? {
        guard let number = value?.toNumber() else { return nil }
        let intValue = number.intValue
        return intValue > 0 ? intValue : nil
    }

    private func javaScriptErrorLocation(from stack: String?) -> (line: Int?, column: Int?) {
        guard let stack, !stack.isEmpty,
              let regex = try? NSRegularExpression(pattern: #":(\d+):(\d+)"#) else {
            return (nil, nil)
        }

        let range = NSRange(stack.startIndex..<stack.endIndex, in: stack)
        guard let match = regex.firstMatch(in: stack, range: range),
              match.numberOfRanges == 3,
              let lineRange = Range(match.range(at: 1), in: stack),
              let columnRange = Range(match.range(at: 2), in: stack) else {
            return (nil, nil)
        }

        return (Int(stack[lineRange]), Int(stack[columnRange]))
    }

    private func javaScriptFunctionName(from stack: String?) -> String? {
        guard let stack, !stack.isEmpty else { return nil }
        let patterns = [
            #"at\s+([A-Za-z_][A-Za-z0-9_]*)\b"#,
            #"([A-Za-z_][A-Za-z0-9_]*)@[^:\s]+:\d+:\d+"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(stack.startIndex..<stack.endIndex, in: stack)
            guard let match = regex.firstMatch(in: stack, range: range),
                  match.numberOfRanges > 1,
                  let functionRange = Range(match.range(at: 1), in: stack) else {
                continue
            }

            let functionName = String(stack[functionRange])
            if functionName != "globalCode" && functionName != "anonymous" {
                return functionName
            }
        }

        return nil
    }

    private func javaScriptFunctionName(in source: String, line: Int?) -> String? {
        guard let line, line > 0 else { return nil }
        let lines = source.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }

        let searchUpperBound = min(line - 1, lines.count - 1)
        let patterns = [
            #"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#,
            #"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*function\s*\("#,
            #"\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*\{"#,
        ]

        for index in stride(from: searchUpperBound, through: 0, by: -1) {
            let lineText = lines[index]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    continue
                }

                let range = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
                guard let match = regex.firstMatch(in: lineText, range: range),
                      match.numberOfRanges > 1,
                      let functionRange = Range(match.range(at: 1), in: lineText) else {
                    continue
                }

                return String(lineText[functionRange])
            }
        }

        return nil
    }

    private func utilityNamespaceAliasScript(for utility: WorkspaceScriptUtility) -> String? {
        let namespace = sanitizedJavaScriptIdentifier(from: utility.name)
        let exportedSymbols = JavaScriptUtilitySymbolParser.topLevelSymbolNames(in: utility.source)
        var aliasLines: [String] = ["if (typeof utils === \"undefined\") { utils = {}; }"]

        for symbol in exportedSymbols where !symbol.isEmpty {
            aliasLines.append("""
            if (typeof \(symbol) !== "undefined") {
                utils.\(symbol) = \(symbol);
            }
            """)
        }

        if !namespace.isEmpty,
           let primarySymbol = exportedSymbols.first,
           primarySymbol != namespace {
            aliasLines.append("""
            if (typeof \(primarySymbol) !== "undefined") {
                utils.\(namespace) = \(primarySymbol);
            }
            """)
        } else if !namespace.isEmpty, exportedSymbols.isEmpty {
            aliasLines.append("""
            if (typeof \(namespace) !== "undefined") {
                utils.\(namespace) = \(namespace);
            }
            """)
        }

        guard aliasLines.count > 1 else { return nil }

        return """
        (function() {
            \(aliasLines.joined(separator: "\n    "))
        })();
        """
    }

    private func sanitizedJavaScriptIdentifier(from rawName: String) -> String {
        let components = rawName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard let first = components.first else { return "" }
        let identifier = ([first] + components.dropFirst().map { $0.capitalized }).joined()
        if let scalar = identifier.unicodeScalars.first, CharacterSet.decimalDigits.contains(scalar) {
            return "_\(identifier)"
        }
        return identifier
    }
}

#if canImport(JavaScriptCore)
private final class JavaScriptRuntimeBridge {
    var runtime: ScriptRuntimeContext
    var logs: [String]
    var webSocketMessageHandler: JSValue?
    var webSocketDoneHandler: JSValue?
    private let request: APIRequestModel?

    init(runtime: ScriptRuntimeContext, request: APIRequestModel? = nil, logs: [String] = []) {
        self.runtime = runtime
        self.request = request
        self.logs = logs
    }

    func value(in scope: String, for key: String) -> String? {
        switch scope {
        case "globals":
            return runtime.globals[key]
        case "collection":
            return runtime.collection[key]
        case "environment":
            return runtime.environment[key]
        default:
            return runtime.local[key]
        }
    }

    func setValue(_ value: String, in scope: String, for key: String) {
        switch scope {
        case "globals":
            runtime.globals[key] = value
        case "collection":
            runtime.collection[key] = value
        case "environment":
            runtime.environment[key] = value
            synchronizeActiveEnvironmentVariables()
        default:
            runtime.local[key] = value
        }
    }

    func unsetValue(in scope: String, for key: String) {
        switch scope {
        case "globals":
            runtime.globals.removeValue(forKey: key)
        case "collection":
            runtime.collection.removeValue(forKey: key)
        case "environment":
            runtime.environment.removeValue(forKey: key)
            synchronizeActiveEnvironmentVariables()
        default:
            runtime.local.removeValue(forKey: key)
        }
    }

    @discardableResult
    func createEnvironment(named rawName: String, shouldActivate: Bool = false) -> UUID {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "New Environment"
        let baseName = trimmedName.isEmpty ? fallbackName : trimmedName

        if let existing = runtime.environments.first(where: { $0.name.localizedCaseInsensitiveCompare(baseName) == .orderedSame }) {
            return existing.id
        }

        let environment = EnvironmentProfile(
            name: baseName,
            variables: [],
            isEnabled: true
        )
        runtime.environments.append(environment)
        runtime.environments.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if shouldActivate || runtime.activeEnvironmentID == nil {
            _ = activateEnvironment(withID: environment.id)
        }

        return environment.id
    }

    func activateEnvironment(matching identifierOrName: String) -> Bool {
        let trimmed = identifierOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let identifier = UUID(uuidString: trimmed), activateEnvironment(withID: identifier) {
            return true
        }

        if let environment = runtime.environments.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return activateEnvironment(withID: environment.id)
        }

        return false
    }

    func activeEnvironmentPayload() -> [String: Any] {
        guard let activeEnvironment = activeEnvironment() else {
            return [:]
        }

        return payload(for: activeEnvironment)
    }

    func environmentListPayload() -> [[String: Any]] {
        runtime.environments.map(payload(for:))
    }

    func requestHeadersPayload() -> [[String: Any]] {
        effectiveRequestHeaders().filter(\.isEnabled).map {
            [
                "key": $0.key,
                "value": $0.value,
            ]
        }
    }

    func requestQueryItemsPayload() -> [[String: Any]] {
        effectiveRequestQueryItems().filter(\.isEnabled).map {
            [
                "key": $0.key,
                "value": $0.value,
            ]
        }
    }

    func requestBodyPayload() -> [String: Any] {
        let body = effectiveRequestBody()
        return [
            "kind": body.kind.rawValue,
            "raw": body.raw,
            "rawTemplate": body.raw,
            "parameters": body.parameters
                .filter(\.isEnabled)
                .map {
                    [
                        "key": $0.key,
                        "value": $0.value,
                    ]
                },
        ]
    }

    func requestHeaderValue(for key: String) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return effectiveRequestHeaders().last(where: {
            $0.isEnabled && $0.key.localizedCaseInsensitiveCompare(trimmedKey) == .orderedSame
        })?.value
    }

    func requestQueryItemValue(for key: String) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        return effectiveRequestQueryItems().last(where: {
            $0.isEnabled && $0.key.localizedCaseInsensitiveCompare(trimmedKey) == .orderedSame
        })?.value
    }

    func setRequestHeader(named key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        var headers = effectiveRequestHeaders()
        headers.removeAll { $0.key.localizedCaseInsensitiveCompare(trimmedKey) == .orderedSame }
        headers.append(KeyValueEntry(key: trimmedKey, value: value, isEnabled: true))
        runtime.requestHeaders = headers
    }

    func addRequestHeader(named key: String, value: String) {
        setRequestHeader(named: key, value: value)
    }

    func setRequestQueryItem(named key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        var items = effectiveRequestQueryItems()
        items.removeAll { $0.key.localizedCaseInsensitiveCompare(trimmedKey) == .orderedSame }
        items.append(KeyValueEntry(key: trimmedKey, value: value, isEnabled: true))
        runtime.requestQueryItems = items
    }

    func addRequestQueryItem(named key: String, value: String) {
        setRequestQueryItem(named: key, value: value)
    }

    func removeRequestHeader(named key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        var headers = effectiveRequestHeaders()
        headers.removeAll { $0.key.localizedCaseInsensitiveCompare(trimmedKey) == .orderedSame }
        runtime.requestHeaders = headers
    }

    func removeRequestQueryItem(named key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        var items = effectiveRequestQueryItems()
        items.removeAll { $0.key.localizedCaseInsensitiveCompare(trimmedKey) == .orderedSame }
        runtime.requestQueryItems = items
    }

    func setRequestBody(_ value: Any?) {
        let current = effectiveRequestBody()
        let normalized = normalizedRequestBodyValue(from: value)
        let updatedKind: RequestBodyKind

        switch current.kind {
        case .json:
            updatedKind = .json
        case .raw:
            updatedKind = .raw
        case .none:
            updatedKind = normalized.wasJSONObject ? .json : .raw
        case .urlEncoded, .formData:
            updatedKind = normalized.wasJSONObject ? .json : .raw
        }

        runtime.requestBody = RequestBodyModel(
            kind: updatedKind,
            raw: normalized.raw,
            parameters: []
        )
    }

    private func activateEnvironment(withID environmentID: UUID) -> Bool {
        guard let environment = runtime.environments.first(where: { $0.id == environmentID && $0.isEnabled }) else {
            return false
        }

        runtime.activeEnvironmentID = environment.id
        runtime.environment = Dictionary(uniqueKeysWithValues: environment.variables
            .filter(\.isEnabled)
            .map { ($0.key, $0.value) })
        return true
    }

    private func activeEnvironment() -> EnvironmentProfile? {
        guard let activeEnvironmentID = runtime.activeEnvironmentID else {
            return nil
        }
        return runtime.environments.first(where: { $0.id == activeEnvironmentID })
    }

    private func synchronizeActiveEnvironmentVariables() {
        guard let activeEnvironmentID = runtime.activeEnvironmentID,
              let environmentIndex = runtime.environments.firstIndex(where: { $0.id == activeEnvironmentID }) else {
            return
        }

        runtime.environments[environmentIndex].variables = runtime.environment.keys.sorted().map { key in
            VariableValue(key: key, value: runtime.environment[key] ?? "", isEnabled: true)
        }
    }

    private func effectiveRequestHeaders() -> [KeyValueEntry] {
        if let requestHeaders = runtime.requestHeaders {
            return requestHeaders
        }
        return request?.headers ?? []
    }

    private func effectiveRequestQueryItems() -> [KeyValueEntry] {
        if let requestQueryItems = runtime.requestQueryItems {
            return requestQueryItems
        }
        return request?.queryItems ?? []
    }

    private func effectiveRequestBody() -> RequestBodyModel {
        if let requestBody = runtime.requestBody {
            return requestBody
        }
        return request?.body ?? RequestBodyModel()
    }

    private func normalizedRequestBodyValue(from value: Any?) -> (raw: String, wasJSONObject: Bool) {
        switch value {
        case nil:
            return ("", false)
        case let string as String:
            return (string, false)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return (number.boolValue ? "true" : "false", false)
            }
            return (number.stringValue, false)
        case let boolean as Bool:
            return (boolean ? "true" : "false", false)
        case let dictionary as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []),
               let text = String(data: data, encoding: .utf8) {
                return (text, true)
            }
            return (String(describing: dictionary), true)
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array, options: []),
               let text = String(data: data, encoding: .utf8) {
                return (text, true)
            }
            return (String(describing: array), true)
        default:
            return (String(describing: value!), false)
        }
    }

    private func payload(for environment: EnvironmentProfile) -> [String: Any] {
        [
            "id": environment.id.uuidString,
            "name": environment.name,
            "isEnabled": environment.isEnabled,
            "isActive": environment.id == runtime.activeEnvironmentID,
            "variables": environment.variables.map {
                [
                    "id": $0.id.uuidString,
                    "key": $0.key,
                    "value": $0.value,
                    "isEnabled": $0.isEnabled,
                ]
            },
        ]
    }
}
#endif
