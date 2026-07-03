# Seguridad y soporte de cifrado

Directrices para agentes y desarrolladores humanos. El objetivo es **reducir exposición de secretos** y **usar criptografía de forma correcta** en un cliente de APIs de escritorio.

## Scripts: `pm.crypto` y claves públicas

- **`pm.crypto.rsa.encryptOAEP_SHA256`** cifra con la **clave pública** del cliente (PEM o certificado); no expone descifrado RSA ni clave privada en el runtime documentado.
- La salida es **hexadecimal**; tratar cadenas vacías como fallo controlado y **no** reintentar con PEM alterado en bucles que filtren secretos al log.
- **AES** bajo `pm.crypto.aes` es simétrico y opera sobre **bytes** y, en CBC cifrado, salida **hex**; cumple restricciones de bloque (sin padding PKCS en el borde). No uses estas APIs para almacenar claves maestras en scripts versionados.
- La lista completa de firmas y tipos está en la referencia del tile [pm-api-javascript-completa.md](../docs/reference/pm-api-javascript-completa.md).

## Transporte (TLS)

- Las peticiones **HTTPS** deben usar la pila TLS del sistema salvo que exista un modo documentado y acotado para laboratorios (por ejemplo certificados no confiables solo en debug).
- No desactives validación de certificados en **releases** ni como valor por defecto silencioso.
- **WebSockets** (`wss://`): mismo criterio que HTTPS; evita `ws://` en entornos con datos sensibles salvo uso local explícito.

## Secretos y credenciales

- **No** versiones en el repositorio: tokens de API, contraseñas, claves privadas, cookies de sesión reales o dumps de workspace con datos productivos.
- Usa **variables de entorno** o archivos locales ignorados por git para datos de prueba personales.
- Para credenciales de usuario en macOS, privilegia **Keychain** (o el mecanismo que el proyecto ya use) frente a plist o JSON en texto plano.
- Al mostrar secretos en UI, aplica **enmascaramiento** (puntos o “•••”) cuando el campo sea tipo secreto o marcado como sensible.

## Almacenamiento local del workspace

- Si el workspace puede contener tokens, define si el archivo en disco debe ir **cifrado** o al menos **excluido de copias de seguridad** del sistema según política del producto.
- Cualquier cifrado en reposo debe usar **APIs del sistema** (CryptoKit, Security framework) con claves derivadas de forma segura, no algoritmos caseros.
- Documenta en el mensaje de cambio si introduces un **nuevo formato** de archivo y cómo migrar versiones anteriores.

## Logs y diagnóstico

- Los **logs de consola** de scripts o de depuración no deben imprimir cabeceras de autorización completas, cuerpos con PII ni claves.
- Para soporte, usa **redacción** (truncar + sustituir por `[REDACTED]`) en utilidades de log compartidas.

## Git y remotos

- URLs con **token embebido** son un riesgo; si el producto las muestra o guarda, advierte al usuario y ofrece alternativas (SSH, asistente de credenciales).
- No registres en log el resultado completo de comandos git que puedan incluir URLs con secretos.

## Cumplimiento y alcance

- Este cliente **no sustituye** a un HSM ni a un gestor corporativo de secretos: deja claro en UI o documentación los límites cuando el usuario guarde credenciales en el workspace.
- Si añades una opción «permitir certificados no confiables» o similar, debe ser **explícita**, visible y desactivada por defecto en builds de producción.

## Checklist antes de merge (agente o humano)

- [ ] No hay secretos nuevos en texto plano en el diff.
- [ ] TLS no se debilita por defecto.
- [ ] Logs y fixtures de test no contienen datos reales sensibles.
- [ ] Cambios en persistencia consideran migración y, si aplica, cifrado.
