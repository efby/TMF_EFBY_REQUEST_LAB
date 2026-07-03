# EFBY Request Lab

Cliente de escritorio para inspeccionar y ejecutar APIs: pestañas de petición, scripts de pre-request, variables por capas (global, colección, entorno, local), importación Postman/OpenAPI, WebSockets y orquestación de flujos tipo BPMN sobre el mismo workspace.

## Guía para desarrollar el mismo sistema

Esta guía sirve para **cualquier persona o equipo** que quiera mantener este repo, **reimplementar un producto equivalente** desde cero o **incorporar a un colaborador nuevo**. No sustituye leer los enlaces; ordena *qué* leer y *en qué orden*.

### Cómo está organizado el SDD

| Ubicación en el repo | Qué contiene |
|----------------------|----------------|
| `SDD/tile/docs/` (esta carpeta) | Visión de producto, arquitectura, módulos y **referencia técnica** (contratos para implementar). |
| `SDD/tile/rules/` | Reglas de proceso, calidad, seguridad y **checklist por fases** para Tessl y agentes. |
| `SDD/tile/specs/` (dentro del tile) | Especificaciones `.spec.md` incluidas al publicar con Tessl; requisitos y “Comenzar desde cero” por área (HTTP, flujos, `pm`/crypto, persistencia, etc.). |

Instala Tessl y publica el tile si quieres que los agentes consuman esta documentación vía Registry; los pasos están [más abajo](#publicar-este-tile-en-tessl).

### Por objetivo: qué abrir primero

| Tu objetivo | Primer documento | Luego |
|-------------|------------------|--------|
| Entender el producto y compilar | [getting-started.md](getting-started.md) | [architecture.md](architecture.md), [funcionalidades-requeridas.md](../rules/funcionalidades-requeridas.md) |
| Reimplementar el núcleo (datos + disco + red) | [contrato-paquete-spm.md](reference/contrato-paquete-spm.md) | [modelo-datos-y-persistencia.md](reference/modelo-datos-y-persistencia.md), [runtime-peticiones-scripts.md](reference/runtime-peticiones-scripts.md), [specs del tile](../specs/) |
| Scripts de petición y cifrado (`pm`, RSA, AES) | [pm-api-javascript-completa.md](reference/pm-api-javascript-completa.md) | [javascript-pm-runtime.spec.md](../specs/javascript-pm-runtime.spec.md), [seguridad-encriptacion.md](../rules/seguridad-encriptacion.md) |
| Flujos BPMN en el workspace | [flujos-workspace-bpmn.md](reference/flujos-workspace-bpmn.md) | [workspace-flow.spec.md](../specs/workspace-flow.spec.md), [architecture.md](architecture.md) |
| Import/export Postman, OpenAPI, Git | [integraciones-import-export.md](reference/integraciones-import-export.md) | [postman-interop.spec.md](../specs/postman-interop.spec.md), [git-workspace.spec.md](../specs/git-workspace.spec.md) |
| Solo la app SwiftUI | [efby-postman-ui.md](modules/efby-postman-ui.md) | [ui-estado-y-navegacion.md](reference/ui-estado-y-navegacion.md), [app-core.md](modules/app-core.md) |
| Trabajo con IA (Cursor, Codex, …) | [agents-cursor-codex.md](../rules/agents-cursor-codex.md) | [checklist-implementacion-desde-cero.md](../rules/checklist-implementacion-desde-cero.md), [especificaciones-desarrollo.md](../rules/especificaciones-desarrollo.md) |

### Rutas de lectura sugeridas

1. **Colaborador nuevo (repo ya existente)**  
   [getting-started.md](getting-started.md) → [architecture.md](architecture.md) → módulos [app-core](modules/app-core.md) / [efby-postman-ui](modules/efby-postman-ui.md) → [testing.md](reference/testing.md). Antes del primer merge que toque secretos o red: [seguridad-encriptacion.md](../rules/seguridad-encriptacion.md).

2. **Equipo que construye un clon o reescritura limpia**  
   [checklist-implementacion-desde-cero.md](../rules/checklist-implementacion-desde-cero.md) fase a fase, leyendo en paralelo cada archivo de [referencia técnica](#referencia-técnica-creación-desde-cero). Valida cada fase con `swift build` y `swift test` como indica [getting-started.md](getting-started.md).

3. **Quien solo extiende una pieza (p. ej. variables o WebSocket)**  
   Abre la spec correspondiente en [specs/](../specs/), el apartado “Comenzar desde cero” de esa spec y el documento de referencia enlazado en la tabla **Por objetivo** más arriba.

### Reglas que aplican a todos

- **Núcleo vs UI**: la lógica de negocio y red vive en la biblioteca de núcleo; la app orquesta y pinta. Detalle en [especificaciones-desarrollo.md](../rules/especificaciones-desarrollo.md).
- **Cambios pequeños y probados**: prefija `swift test` tras tocar el núcleo; no mezcles refactors masivos con features.
- **Seguridad y datos sensibles**: TLS, secretos, logs y `pm.crypto` en [seguridad-encriptacion.md](../rules/seguridad-encriptacion.md).
- **Contrato de scripts**: cualquier función nueva bajo `pm` debe documentarse en [pm-api-javascript-completa.md](reference/pm-api-javascript-completa.md) y alinearse con el autocompletado del editor en código.

### Comandos que deberías poder ejecutar

En la raíz del clon, tras instalar la toolchain correcta:

```bash
swift build
swift test
swift build -c release --product EfbyRequestLabs
```

Si alguno falla, corrige entorno (Xcode / Command Line Tools, versión de Swift) antes de seguir implementando; guía en [getting-started.md](getting-started.md).

Después de esta guía, sigue la lista numerada **Comenzar desde cero** para un checklist operativo rápido (clon, build, tests, lecturas y agentes).

## Comenzar desde cero

1. Clona o copia el repositorio del producto en tu máquina con macOS reciente.
2. Instala una toolchain de Swift compatible con la versión declarada en el manifiesto del paquete en la raíz del proyecto (línea `swift-tools-version`).
3. Abre una terminal en la **raíz del repositorio** (donde está el manifiesto del paquete).
4. Compila el paquete con `swift build` y, si quieres la app lista para distribuir, `swift build -c release --product EfbyRequestLabs`.
5. Ejecuta la batería de pruebas con `swift test` antes de cambiar lógica compartida.
6. Lee en este orden: [Primeros pasos](getting-started.md) → [Arquitectura](architecture.md) → [AppCore](modules/app-core.md) → [Interfaz](modules/efby-postman-ui.md) → [Pruebas y specs](reference/testing.md).
7. Si vas a **implementar o rehacer un módulo**, abre la [referencia técnica](#referencia-técnica-creación-desde-cero) y la checklist [checklist-implementacion-desde-cero.md](../rules/checklist-implementacion-desde-cero.md) (orden por fases: SPM → dominio → HTTP → WebSocket → import → flujos → UI).
8. Si desarrollas con **agentes** (Cursor, Codex u otros), sigue la sección [Reglas para agentes y desarrollo](#reglas-para-agentes-y-desarrollo-steering): especifica alcance en el prompt, respeta seguridad/cifrado y prioriza cambios pequeños verificados con `swift test`.
9. Para requisitos por área funcional, abre los `.spec.md` en [specs/](../specs/) (carpeta **dentro del tile**, se publican con Tessl): cada uno incluye cómo abordar el tema desde cero y cómo verificar el resultado.

## Información del paquete

- **Nombre del paquete**: `EfbyRequestLabs` (nombre lógico en el manifiesto).
- **Productos**: biblioteca de núcleo, aplicación de escritorio con interfaz declarativa, ejecutable auxiliar para depuración de flujos.
- **Plataforma mínima**: macOS 14 (según el manifiesto).
- **Lenguaje**: Swift con modo de concurrencia estricta acorde al manifiesto.

## Documentación en esta carpeta

| Documento | Contenido |
|-----------|-------------|
| [getting-started.md](getting-started.md) | Entorno, compilación, pruebas y primer arranque |
| [architecture.md](architecture.md) | Capas, flujo de datos y dependencias |
| [modules/app-core.md](modules/app-core.md) | Núcleo compartido (dominio y servicios) |
| [modules/efby-postman-ui.md](modules/efby-postman-ui.md) | Aplicación con interfaz gráfica |
| [reference/testing.md](reference/testing.md) | Cómo verificar cambios y enlazar requisitos con pruebas |

## Referencia técnica (creación desde cero)

Documentos de **contrato e implementación** para reconstruir el producto sin adivinar detalles.

| Documento | Contenido |
|-----------|-------------|
| [reference/contrato-paquete-spm.md](reference/contrato-paquete-spm.md) | swift-tools-version, productos, targets, recursos, comandos de verificación |
| [reference/modelo-datos-y-persistencia.md](reference/modelo-datos-y-persistencia.md) | Agregado workspace, nodos, variables, JSON en disco, migraciones de esquema |
| [reference/runtime-peticiones-scripts.md](reference/runtime-peticiones-scripts.md) | Pipeline HTTP, contexto de scripts, WebSocket, errores, tooling de editor |
| [reference/flujos-workspace-bpmn.md](reference/flujos-workspace-bpmn.md) | Tipos de nodo BPMN, enlace tarea–petición, ejecución y pruebas mínimas |
| [reference/integraciones-import-export.md](reference/integraciones-import-export.md) | Postman v2/v2.1, entornos, OpenAPI 3.x, Git y orden de implementación |
| [reference/ui-estado-y-navegacion.md](reference/ui-estado-y-navegacion.md) | Coordinador, pestañas, ciclo de vida macOS, editores embebidos |
| [reference/pm-api-javascript-completa.md](reference/pm-api-javascript-completa.md) | **Toda** la API `pm`, cifrado nativo RSA/AES, `postman`, `CryptoJS`, WebSocket, tests, QR |

## Reglas para agentes y desarrollo (steering)

Documentos consumidos por Tessl y por el flujo de trabajo con IA; viven junto al tile en `rules/`.

| Regla | Contenido |
|--------|-----------|
| [checklist-implementacion-desde-cero.md](../rules/checklist-implementacion-desde-cero.md) | Orden por fases desde SPM hasta UI y calidad |
| [agents-cursor-codex.md](../rules/agents-cursor-codex.md) | Cómo deben operar Cursor, Codex y similares sobre este repo |
| [especificaciones-desarrollo.md](../rules/especificaciones-desarrollo.md) | Arquitectura Swift, estilo, pruebas y revisiones |
| [funcionalidades-requeridas.md](../rules/funcionalidades-requeridas.md) | Alcance funcional que el producto debe mantener o ampliar |
| [seguridad-encriptacion.md](../rules/seguridad-encriptacion.md) | TLS, secretos, Keychain, logs y persistencia segura |

## Especificaciones (SDD)

Las especificaciones están en **[specs/](../specs/)** junto a `docs/` y `rules/` **dentro de `SDD/tile/`**, para que `tessl tile publish ./SDD/tile` las suba con el proyecto al Registry. Son Markdown con frontmatter Tessl (`name`, `description`, `targets` como ámbito lógico). Cada spec incluye “Comenzar desde cero” y criterios de verificación. Archivos: HTTP, WebSocket, flujos, Postman, variables, scripts/editor, **runtime `pm` y criptografía** (`javascript-pm-runtime.spec.md`), Git, coordinador de workspace, **persistencia** (`persistencia-workspace.spec.md`). Opcionalmente, en la raíz del árbol `SDD/` puede quedar una carpeta `specs/` con un README que redirija aquí (ese archivo **no** forma parte del paquete publicado del tile).

Índice rápido: [http-request-execution.spec.md](../specs/http-request-execution.spec.md) · [websocket-client.spec.md](../specs/websocket-client.spec.md) · [workspace-flow.spec.md](../specs/workspace-flow.spec.md) · [postman-interop.spec.md](../specs/postman-interop.spec.md) · [variable-resolution.spec.md](../specs/variable-resolution.spec.md) · [javascript-tooling.spec.md](../specs/javascript-tooling.spec.md) · [javascript-pm-runtime.spec.md](../specs/javascript-pm-runtime.spec.md) · [git-workspace.spec.md](../specs/git-workspace.spec.md) · [main-view-model-workspace.spec.md](../specs/main-view-model-workspace.spec.md) · [persistencia-workspace.spec.md](../specs/persistencia-workspace.spec.md).

## Publicar este tile en Tessl

1. Asegura la CLI: `brew install tesslio/tap/tessl` (o el instalador oficial indicado en la documentación de Tessl).
2. Inicia sesión: `tessl login` (abre el enlace, confirma el código del dispositivo).
3. Crea o elige un **workspace** en Tessl (interfaz web o comandos de workspace de la CLI) y anota su identificador.
4. Desde la **raíz del repositorio**, valida: `tessl tile lint ./SDD/tile`.
5. Publica: `tessl tile publish ./SDD/tile --workspace TU_WORKSPACE` sustituyendo `TU_WORKSPACE` por el id real.

El manifiesto del tile es `SDD/tile/tile.json` (nombre `efbyproyectos/efby-request-lab`, versión semver). Tras cambios en la documentación o reglas, sube la versión en ese archivo antes de volver a publicar.

En este repo, `tessl init` ya dejó `tessl.json` (dependencias de tiles del proyecto) y `.cursor/mcp.json` (MCP `tessl mcp start` para Cursor). Si la CLI avisa de `~/.local/bin`, añade esa ruta a tu `PATH` **o** usa la Tessl instalada por Homebrew asegurando que `/opt/homebrew/bin` esté en el `PATH` del editor.
