# API JavaScript `pm` y criptografía nativa (referencia para agentes)

Este documento describe lo que el **motor de scripts** del producto expone en **JavaScript** (JavaScriptCore en macOS). Debe mantenerse alineado con el bootstrap del motor y con el autocompletado del editor.

**Convención**: el objeto principal de compatibilidad con flujos tipo Postman es **`pm`**. Las funciones criptográficas que usan **Security / CommonCrypto / CryptoKit** del sistema se exponen bajo **`pm.crypto`** y utilidades relacionadas (`CryptoJS` parcial, `btoa`/`atob`, `encryptRsa`).

---

## 1. Contexto de ejecución

- Los scripts se ejecutan en un contexto aislado con un **bootstrap** que define `pm`, `postman`, `console`, `CryptoJS`, `btoa`, `atob`, `encryptRsa` y enlaza puentes nativos (`__pm*` / `__crypto*`).
- **`pm.request`** se construye a partir del modelo de petición actual y se **enlaza** a mutaciones en el runtime (cabeceras, query, cuerpo).
- **`pm.response`**, **`responseBody`**, **`responseCode`** reflejan el estado de respuesta **según el momento del evento** (pre-request vs post-response): en pre-request la respuesta puede estar vacía o ausente.
- Los handlers **WebSocket** (`pm.websocket.*`) reciben mensajes y causas de cierre desde el runtime que la app rellena.

---

## 2. `pm` — variables y entornos

| Miembro | Descripción |
|---------|-------------|
| `pm.globals` | Objeto con `get(key)`, `set(key, value)`, `unset(key)` → mapa **global** del workspace. |
| `pm.collectionVariables` | Igual para variables de **colección** (ámbito de la petición según contexto de ejecución). |
| `pm.environment` | Igual para variables del **entorno activo**, más: `create(name)`, `select(nameOrId)` / `activate(nameOrId)`, `getActive()`, `list()`. |
| `pm.variables` | Variables **locales** a la petición/pestaña. |
| `pm.createEnvironment(name)` / `pm.createenvironment(name)` | Crea y **activa** un entorno nuevo. |
| `pm.setActiveEnvironment(nameOrId)` / `pm.setactiveenvironment(nameOrId)` | Activa un entorno por nombre o id. |

---

## 3. `pm.request` — petición actual

Objeto enriquecido con la forma resuelta (URLs y valores ya pasados por el resolutor de plantillas donde aplica):

| Campo | Tipo / contenido |
|-------|-------------------|
| `name` | Nombre de la petición. |
| `method` | Método HTTP en texto. |
| `url` | URL ya **resuelta** con variables. |
| `urlTemplate` | Plantilla original de URL. |
| `headers` | Lista de `{ key, value }` habilitados; además métodos `get`, `has`, `set`, `add`, `remove`, `all` (mutan el runtime y sincronizan la lista). |
| `queryItems`, `param`, `params` | Alias de la lista de query; mismos métodos que `headers`. |
| `pathVariables`, `cookies` | Listas `{ key, value }` resueltas. |
| `body` | Objeto con `kind`, `raw`, `rawTemplate`, `parameters`, más `get()` y `set(value)` para delegar en el runtime. |

---

## 4. `pm.response` y globales de respuesta

| API | Descripción |
|-----|-------------|
| `pm.response.code` | Getter → código HTTP numérico (o sentinela si no hay respuesta). |
| `pm.response.text()` | Cuerpo de respuesta como texto. |
| `pm.response.json()` | Parse JSON del cuerpo; `null` si vacío. |
| `pm.response.to.have.status(expected)` | Aserta código; lanza si no coincide; registra `PASS`/`FAIL` en consola de script. |
| `responseBody` | Variable global: texto del cuerpo al evaluar el bootstrap. |
| `responseCode` | Variable global: código al evaluar el bootstrap. |

---

## 5. `pm.websocket`

| Miembro | Descripción |
|---------|-------------|
| `pm.websocket.onMessage(handler)` | Registra callback para mensajes entrantes. |
| `pm.websocket.onDone(handler)` | Registra callback al cierre. |
| `pm.websocket.disconnect()` | Marca solicitud de desconexión en el runtime. |
| `pm.websocket.message.text()` | Texto del último mensaje entrante. |
| `pm.websocket.done.cause()` | Causa textual del cierre. |

---

## 6. `pm.crypto` — cifrado nativo (claves públicas y simétrico)

Implementación nativa macOS: **RSA** vía **Security** (`SecKey`); **AES** vía **CommonCrypto** (CBC/ECB, sin padding PKCS#7 en el borde: el payload debe cumplir restricciones de tamaño de bloque).

### 6.1 `pm.crypto.rsa`

#### `pm.crypto.rsa.encryptOAEP_SHA256(message, publicKeyPem)` → `string`

- **Algoritmo**: RSA con **OAEP** y **SHA-256** (`rsaEncryptionOAEPSHA256`).
- **`message`**: cadena UTF-8; se cifra como bytes de la cadena.
- **`publicKeyPem`**: PEM completo. Se acepta:
  - Certificado **`BEGIN CERTIFICATE`** → se extrae la **clave pública** del certificado.
  - Clave pública en PEM cuyo cuerpo sea **DER** decodificable desde Base64 (p. ej. `PUBLIC KEY` / SPKI según lo que acepte el decodificador del producto).
- **Salida**: **hexadecimal minúsculas** del ciphertext (bytes concatenados como `%02x`). Si falla (PEM inválido, clave no soportada, error de cifrado), el puente devuelve **cadena vacía** `""` → el script debe comprobar longitud o resultado antes de usarlo.
- **Alias global**: `encryptRsa(message, publicKeyPem)` equivale a esta llamada.

**Desarrollo / agentes**: no loguear el PEM completo ni mensajes sensibles en `console.log` en entornos compartidos.

### 6.2 `pm.crypto.aes`

Restricciones comunes del motor:

- **Tamaño de clave**: **16, 24 u 32 bytes** (AES-128/192/256).
- **Bloque**: operaciones **sin padding PKCS#7** en el borde nativo: longitudes de entrada deben ser **múltiplo de 16 bytes** para cifrado/descifrado exitoso.
- **IV en CBC**: **16 bytes** (típicamente se pasa como array de bytes o cadena UTF-8 de 16 caracteres si aplica el puente de “bytes o string”).

#### `pm.crypto.aes.encryptCBCNoPaddingToHex(keyBytes, ivValue, plainBytes)` → `string`

- Cifra **AES-CBC** sin padding añadido por el motor.
- **`keyBytes`**, **`plainBytes`**: ver sección **Representación de bytes** más abajo.
- **`ivValue`**: bytes o string interpretable como bytes (ver puente `fromJavaScriptBytesOrString`).
- **Salida**: **hex minúsculas** del ciphertext, o `""` si falla.

#### `pm.crypto.aes.decryptCBCNoPaddingFromHex(keyBytes, ivValue, cipherHex)` → `number[]`

- **`cipherHex`**: string hexadecimal (ciphertext).
- **Salida**: arreglo de **bytes** (0–255) como números; **`[]`** si falla.

#### `pm.crypto.aes.encryptECBNoPadding(keyBytes, plainBytes)` → `number[]`

- **AES-ECB** cifrado; salida bytes como arreglo numérico; **`[]`** si falla.

#### `pm.crypto.aes.decryptECBNoPadding(keyBytes, cipherBytes)` → `number[]`

- Descifrado ECB; **`cipherBytes`** como bytes; **`[]`** si falla.

### 6.3 Representación de bytes en JavaScript

Los puentes aceptan, entre otros:

- `Array` de números enteros en rango **0–255** (o `NSNumber` equivalente desde el bridge).
- `Uint8Array` / tipos que el bridge pueda mapear a bytes.
- **`String`**: se interpreta como **UTF-8** (`Data(string.utf8)`).

Usar literales `[0x00, 0x01, …]` o construir buffers desde hex en script si hace falta.

---

## 7. `CryptoJS` (subconjunto compatible)

| API | Comportamiento |
|-----|----------------|
| `CryptoJS.enc.Utf8.parse(value)` | Objeto marcador `{ __cryptoValue, __cryptoEncoding: "utf8" }` para normalización interna. |
| `CryptoJS.enc.Base64.parse(value)` | Igual con encoding **base64**. |
| `CryptoJS.enc.Hex` | Marcador de encoding hex (metadato). |
| `CryptoJS.HmacSHA256(message, key)` | HMAC-SHA256 nativo (CryptoKit); la clave puede ser UTF-8 o, si el marcador indica **base64**, se decodifica Base64. El resultado de `.toString()` es **hex minúsculas** del digest. |

---

## 8. Codificación y utilidades

| Símbolo | Descripción |
|---------|-------------|
| `btoa(value)` | Base64 de la cadena tratada como **Latin-1** (binario ISO-8859-1). |
| `atob(value)` | Decodifica Base64 a cadena **Latin-1**. |
| `encryptRsa(message, publicKeyPem)` | Alias de `pm.crypto.rsa.encryptOAEP_SHA256`. |

---

## 9. `postman` (compatibilidad)

| Función | Equivalente conceptual |
|---------|-------------------------|
| `setEnvironmentVariable` / `getEnvironmentVariable` / `clearEnvironmentVariable` | Entorno activo. |
| `setGlobalVariable` / `getGlobalVariable` / `clearGlobalVariable` | Globales. |
| `createEnvironment` / `setActiveEnvironment` | Crear / activar entorno (variantes de nombre en minúsculas según bootstrap). |

---

## 10. `console` y pruebas ligeras

| API | Descripción |
|-----|-------------|
| `console.log(...args)` | Une argumentos (strings o `JSON.stringify`) y los envía al **log del script** visible en la app. |

| API | Descripción |
|-----|-------------|
| `pm.test(name, fn)` | Ejecuta `fn`; captura errores y escribe `PASS` / `FAIL` en el log. |
| `pm.expect(actual)` | Encadenar `.to.equal`, `.to.eql`, `.to.be.true` / `.false` (comportamiento tipo Chai reducido). |

---

## 11. Utilidades gráficas en consola

| API | Descripción |
|-----|-------------|
| `pm.generarQR(text)` / `pm.generarqr(text)` | Genera un **QR** a partir del texto; el motor puede emitir una línea de log con **imagen inline** (PNG temporal) para el flujo de workspace. |

---

## 12. Objetos estándar del lenguaje

En el autocompletado se sugieren también `JSON`, `Math`, `Object`, `Array`, `Date`, etc., según lo permita el runtime JavaScriptCore del sistema. No dependas de APIs de **Node.js** ni del navegador (`fetch`, `Buffer`, etc.) salvo que el producto las añada explícitamente.

---

## 13. Checklist para agentes que implementan o extienden `pm`

1. Cualquier función nueva bajo **`pm.`** debe documentarse **aquí** y en **`JavaScriptRuntimeAutocomplete`** (claves anidadas) para que el editor y los agentes no diverjan.
2. Criptografía: preferir **APIs del sistema**; documentar formato de entrada/salida (hex, bytes, PEM).
3. Errores: devolver valores vacíos o arrays vacíos es patrón actual en puentes AES/RSA; si se mejora a errores explícitos, actualizar este documento y las specs.
4. Seguridad: revisar [seguridad-encriptacion.md](../../rules/seguridad-encriptacion.md) antes de exponer nuevas primitivas.
