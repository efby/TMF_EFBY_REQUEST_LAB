# Primeros pasos

## Comenzar desde cero

1. **Máquina**: usa macOS 14 o superior.
2. **Herramientas**: instala Xcode desde la App Store **o** solo el paquete de línea de comandos “Command Line Tools” / toolchain de Swift que coincida con la `swift-tools-version` del manifiesto del paquete en la raíz del repo.
3. **Código**: obtén una copia limpia del repositorio (clon o archivo descomprimido).
4. **Terminal**: sitúate siempre en la **raíz del repositorio** (misma carpeta que el manifiesto del paquete) antes de los comandos siguientes.
5. **Compilación inicial**: ejecuta `swift build` y corrige cualquier error de entorno (versión de Swift, SDK) hasta que termine en éxito.
6. **Pruebas**: ejecuta `swift test` y deja la suite en verde antes de tocar comportamiento del núcleo.
7. **Ejecutable de la app**: para generar el binario de la aplicación de escritorio, usa el producto cuyo nombre figura en el manifiesto del paquete (producto principal de la UI); en modo depuración basta `swift build` y localizar el binario en la salida de compilación, o en modo release `swift build -c release` con el mismo producto.
8. **IDE opcional**: puedes abrir el paquete en Xcode con “Open Package” apuntando a la raíz del repo si prefieres depuración gráfica.

## Requisitos (resumen)

- Toolchain de Swift alineada con el manifiesto del paquete.
- macOS acorde a la plataforma mínima declarada en el manifiesto.

## Compilar

```bash
swift build
```

Compilar la aplicación en modo release (sustituye el nombre del producto si el manifiesto usa otro):

```bash
swift build -c release --product EfbyRequestLabs
```

## Ejecutar tests

```bash
swift test
```

El target de pruebas declarado en el manifiesto ejercita la biblioteca de núcleo; mantén esas pruebas al día cuando cambies reglas de negocio.

## Qué partes componen el repo (sin rutas a código)

- **Núcleo**: biblioteca con modelos de dominio, servicios de red, flujos, importación y persistencia; reutilizable por la app y por herramientas de línea de comandos.
- **Aplicación de escritorio**: capa de interfaz que arranca la ventana principal, menús y editores.
- **Ejecutable de depuración de flujos**: herramienta opcional para probar flujos sin levantar toda la UI.
- **Pruebas automatizadas**: validan el núcleo de forma aislada de la interfaz.
- **SDD / Tessl**: carpeta `SDD` con el tile (`tile.json`, `docs/`, `rules/`, **`specs/`** con los `.spec.md` que sí se publican con `tessl tile publish ./SDD/tile`); sirve para humanos y para agentes con Tessl o reglas del proyecto.
- **Referencia técnica**: en `tile/docs/reference/` están los contratos para reimplementar el sistema (SPM, datos, persistencia, runtime, BPMN, integraciones, UI); empieza por [contrato-paquete-spm.md](reference/contrato-paquete-spm.md). La API de scripts **`pm`** (incluye **cifrado nativo** RSA con clave pública y AES) está en [pm-api-javascript-completa.md](reference/pm-api-javascript-completa.md).
- **Checklist por fases**: [checklist-implementacion-desde-cero.md](../rules/checklist-implementacion-desde-cero.md).

## Desarrollo con agentes (Cursor, Codex, etc.)

1. Lee el índice del tile [index.md](index.md), en especial la tabla **Reglas para agentes y desarrollo** y los enlaces a `rules/`.
2. Incorpora en el prompt el alcance (solo núcleo, solo UI o ambos) y la obligación de ejecutar `swift test` tras cambios en el núcleo.
3. No pidas ni aceptes en el diff secretos reales ni debilitamiento de TLS por defecto; sigue [seguridad-encriptacion.md](../rules/seguridad-encriptacion.md).
