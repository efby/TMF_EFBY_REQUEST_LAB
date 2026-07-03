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

## Verificación

- Pruebas automatizadas del núcleo con vectores conocidos o fixtures PEM generados para tests.
- Lint del tile Tessl tras cambiar la referencia `pm-api-javascript-completa.md`.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-PM-001 | `rsaEncryptProducesHexCiphertext` | Automatizado |
| REQ-PM-002 | `aesCBCEncryptDecryptRoundTrip` | Automatizado |
| REQ-PM-003 | `encryptRsaAliasMatchesRSAOAEP` | Automatizado |
| REQ-PM-004 | `invalidRSAInputReturnsEmptyString` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
