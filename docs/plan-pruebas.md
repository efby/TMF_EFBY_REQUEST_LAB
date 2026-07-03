# Plan de pruebas

## Objetivo

Garantizar que las 10 especificaciones SDD tienen verificación automatizada o manual documentada, con CI ejecutando la suite en cada cambio.

## Tipos de prueba

| Tipo | Alcance | Herramienta | Frecuencia |
|------|---------|-------------|------------|
| Unitaria | Servicios, use cases, coordinadores, codecs, repositorios | XCTest (`AppCoreTests`, 166 tests) | Cada commit (CI) |
| Integración | ViewModel + servicios reales | XCTest con fixtures | Cada PR |
| Manual | UI SwiftUI, BPMN editor visual | Checklist en spec | Pre-release |
| Smoke | Build y arranque app | `swift build` + launch manual | Pre-release |

## Comandos

```bash
# Desde la raíz del repositorio
swift build
swift test
swift test --filter OpenAPIImporterTests
```

## Suites automatizadas

| Suite | Tests aprox. | Spec relacionada |
|-------|--------------|------------------|
| `RequestExecutionServiceTests` | 32 | `http-request-execution` |
| `VariableResolverTests` | 3+ | `variable-resolution` |
| `PostmanCollectionCodecTests` | 7 | `postman-interop` |
| `PostmanEnvironmentCodecTests` | 2 | `postman-interop` |
| `GitRepositoryServiceTests` | 12 | `git-workspace` |
| `WebSocketExecutionServiceTests` | 7 | `websocket-client` |
| `WorkspaceFlowExecutionServiceTests` | 7 | `workspace-flow` |
| `WorkspaceFlowGatewayConditionTests` | 18 | `workspace-flow` |
| `WorkspaceFlowInlineImageLogLineTests` | 3 | `workspace-flow` |
| `JavaScriptRuntimeAutocompleteTests` | 5 | `javascript-tooling` |
| `JavaScriptSourceFormatterTests` | 2 | `javascript-tooling` |
| `JavaScriptUtilitySymbolParserTests` | 3 | `javascript-tooling` |
| `MainViewModelEnvironmentFlowTests` | 7 | `main-view-model-workspace` |
| `MainViewModelFlowCloneTests` | 2 | `main-view-model-workspace` |
| `BitbucketHTTPSArchiveImporterTests` | 5 | `postman-interop` |
| `OpenAPIImporterTests` | 5+ | `postman-interop` |
| `WorkspaceRepositoryTests` | 6+ | `persistencia-workspace` |
| `SharedCollectionsRepositoryTests` | 4+ | `git-workspace` |
| `ScriptEngineTests` | 5+ | `javascript-pm-runtime` |

## Criterios de aceptación por spec

Cada spec define criterios en su sección **Comportamiento** y **Trazabilidad**. El estado global se resume en [traceability-matrix.md](traceability-matrix.md).

**Meta del proyecto**: ≥ 80 % de requisitos con verificación **Automatizada**.

## Cobertura de código

### Generación local (opcional)

```bash
swift test --enable-code-coverage
xcrun llvm-cov report .build/debug/codecov/default.profdata \
  --instr-profile .build/debug/codecov/default.profdata \
  --ignore-filename-regex=".build|Tests"
```

### Áreas prioritarias de cobertura

1. `RequestExecutionService` — pipeline HTTP crítico
2. `VariableResolver` — precedencia de variables
3. `WorkspaceRepository` — migraciones de esquema
4. `ScriptEngine` — runtime `pm.crypto`
5. `WorkspaceFlowExecutionService` — motor BPMN

## Pruebas manuales pre-release

| # | Caso | Pasos | Resultado esperado |
|---|------|-------|-------------------|
| M-01 | Importar colección Postman | Archivo → Import → seleccionar `Examples/postman-v21-sample.json` | Árbol de colección visible |
| M-02 | Ejecutar GET público | Abrir request → Send | Respuesta 200 en panel |
| M-03 | Variables entorno | Crear entorno, activar, `{{var}}` en URL | URL resuelta correctamente |
| M-04 | WebSocket | Nueva pestaña WS → conectar echo server | Mensajes en transcript |
| M-05 | Flujo BPMN | Crear flujo → ejecutar | Nodos resaltados, logs visibles |
| M-06 | Git pull/push | Configurar repo → Pull | Colecciones actualizadas |
| M-07 | Persistencia | Cerrar app → reabrir | Workspace restaurado |
| M-08 | DMG install | Descargar release → instalar | App abre sin Gatekeeper block |

## CI/CD

Workflow `.github/workflows/ci.yml`:

- Trigger: push y pull_request a `main`
- Runner: `macos-14`
- Steps: checkout → `swift build` → `swift test`

## Gestión de fixtures

- Postman: `Examples/postman-v21-sample.json`, `Examples/postman-v2-sample.json`
- OpenAPI: `Examples/openapi-sample.json`
- Persistencia: fixtures inline en `WorkspaceRepositoryTests` (JSON por versión de esquema)

## Registro de incidencias

Las incidencias de prueba se documentan como:

1. ID `REQ-*` afectado en la matriz de trazabilidad.
2. Test que reproduce el fallo (Red TDD).
3. Fix + verificación Green.
