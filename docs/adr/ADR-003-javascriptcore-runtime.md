# ADR-003: JavaScriptCore para runtime Postman parcial

## Estado

Aceptado

## Contexto

Postman usa scripts JavaScript (pre-request, tests) con API `pm.*`. Reimplementar un motor JS completo es inviable. Se necesita compatibilidad razonable para migrar colecciones existentes del equipo.

## Decisión

Usar **JavaScriptCore** (framework Apple) con un bootstrap controlado que expone:

- `pm.variables`, `pm.environment`, `pm.request`, `pm.response`
- `pm.crypto` (RSA-OAEP-SHA256, AES CBC/ECB)
- `pm.sendRequest` limitado
- Hooks WebSocket (`onMessage`, `onDone`)

Scripts ejecutan en sandbox sin acceso a filesystem ni red directa (salvo `pm.sendRequest` controlado).

## Consecuencias

### Positivas

- Nativo en macOS/iOS sin dependencias npm.
- Compatibilidad parcial verificable con tests.
- Cifrado delegado a CryptoKit/CommonCrypto vía puente Swift.

### Negativas

- No 100 % compatible con Postman (lodash, cheerio, etc. ausentes).
- `ScriptEngine.swift` es un archivo grande (~2K líneas).
- Debugging de scripts limitado vs Node en Postman.

## Verificación

Spec `javascript-pm-runtime.spec.md` + suite `ScriptEngineTests`.
