---
name: Runtime JavaScript pm y criptografía nativa
description: Contrato del objeto pm, puentes nativos RSA-OAEP-SHA256 y AES, compatibilidad Postman y CryptoJS parcial.
targets:
  - ambito:paquete-efby / capa:nucleo / area:runtime-javascript-pm
---

## Comenzar desde cero

1. Lee la referencia del tile: [pm-api-javascript-completa.md](../docs/reference/pm-api-javascript-completa.md) (única fuente de verdad documentada para agentes).
2. Implementa el **bootstrap** JS y los **bloques bridge** en el motor de scripts del núcleo; mantén el autocompletado del editor sincronizado con las mismas firmas.
3. Para RSA: solo cifrado con clave **pública**, OAEP-SHA256, salida **hex**; PEM certificado o clave pública decodificable.
4. Para AES: CBC/ECB **sin padding** en el borde nativo; claves 16/24/32 bytes; IV 16 bytes en CBC; documentar fallos como `""` o `[]`.
5. Añade pruebas que validen al menos: RSA con PEM de prueba conocido, AES-CBC round-trip en un bloque, y que `encryptRsa` alias coincida con `pm.crypto.rsa.encryptOAEP_SHA256`.

## Comportamiento

- `pm.crypto.rsa.encryptOAEP_SHA256` debe producir hexadecimal del ciphertext o cadena vacía ante error, sin lanzar al bridge nativo.
- `pm.crypto.aes.*` debe respetar múltiplos de bloque y tamaños de clave; resultados vacíos ante entrada inválida.
- `encryptRsa` debe permanecer como alias documentado de RSA OAEP-SHA256.
- `pm.environment.set` modifica o agrega una fila conservando su identidad y las variables ajenas, incluidas las deshabilitadas. Una fila deshabilitada de la clave escrita se habilita conservando su ID.
- `pm.environment.unset` elimina únicamente la clave indicada; `clear` elimina todas las filas. Volver a activar el entorno no restaura los valores eliminados. Las expresiones de plantilla aplican las mismas reglas.
- Regresiones en `ScriptEngineTests`: `testEnvironmentSetPreservesDisabledVariablesAndExistingIdentifiers`, `testEnvironmentSetEnablesExistingDisabledVariableAndPreservesIdentifier`, `testEnvironmentUnsetDeletesOnlyRequestedKeyAndDoesNotRestoreItOnActivation`, `testEnvironmentClearRemovesAllVariablesAndDoesNotRestoreThemOnActivation` y `testTemplateExpressionUsesSameEnvironmentMutationRules`.

## Verificación

- Pruebas automatizadas del núcleo con vectores conocidos o fixtures PEM generados para tests.
- Lint del tile Tessl tras cambiar la referencia `pm-api-javascript-completa.md`.

## Interrupción de ejecución

- `ScriptEngine(executionTimeLimit:)` aplica un límite de ejecución (5 segundos por defecto) al código JavaScript, incluidas utilidades, expresiones de plantilla y callbacks WebSocket. La cancelación de la tarea Swift también interrumpe el motor.
- Una interrupción devuelve `interruption` en el reporte y conserva el runtime de entrada; no se aplican mutaciones parciales ni se continúa con scripts posteriores. `checkInterruption()` traduce la cancelación a `CancellationError` y los límites a un error explícito.
- HTTP y preparación de WebSocket verifican la interrupción antes de enviar tráfico. La resolución de mensajes WebSocket puede lanzar errores; los callbacks devuelven `scriptError` y solicitan desconexión en lugar de publicar variables parciales.
- La implementación usa las entradas exportadas de WebKit `JSContextGroupSetExecutionTimeLimit` y `JSContextGroupClearExecutionTimeLimit`, declaradas en [JSContextRefPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRefPrivate.h). Son SPI y no forman parte del SDK público de Apple: esta decisión corresponde a la distribución actual por DMG e instalación directa de iPad, no garantiza aceptación en App Store.
- Ambos símbolos se comprueban en tiempo de ejecución. Si falta el mecanismo, el motor rechaza el script; no lo ejecuta sin protección. El límite depende de los puntos de interrupción de JavaScriptCore y no es una cuota de memoria ni puede detener una llamada nativa ya iniciada.
- Las pruebas de bucles infinitos se ejecutan con un límite externo para que una regresión del watchdog no bloquee toda la suite.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-PM-001 | `rsaEncryptProducesHexCiphertext` | Automatizado |
| REQ-PM-002 | `aesCBCEncryptDecryptRoundTrip` | Automatizado |
| REQ-PM-003 | `encryptRsaAliasMatchesRSAOAEP` | Automatizado |
| REQ-PM-004 | `invalidRSAInputReturnsEmptyString` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
