# Arquitectura — EFBY Request Lab

Clean Architecture en capas SPM, con presentación MVVM.

## Capas

```
EfbyRequestLabs / EfbyPostmanPad (UI SwiftUI)
        ↓
EfbyPresentation (MainViewModel, coordinadores, AppDependencies)
        ↓
EfbyApplication (Ports + Use Cases)
        ↓
EfbyDomain (modelos)
        ↑
EfbyInfrastructure (implementa Ports)
```

| Target | Ruta | Responsabilidad |
|--------|------|-----------------|
| `EfbyDomain` | `Sources/AppCore/Domain/` | Modelos de dominio |
| `EfbyApplication` | `Sources/EfbyApplication/` | Puertos y casos de uso |
| `EfbyInfrastructure` | `Sources/AppCore/Application/` | HTTP, WebSocket, Git, scripts, codecs, repositorios |
| `EfbyPresentation` | `Sources/EfbyPresentation/` | ViewModel, coordinadores, composition root |
| `EfbyRequestLabs` | `Sources/EFBYPostman/` | App macOS |
| `FlowDebugRunner` | `Sources/FlowDebugRunner/` | CLI de flujos |

La app iPad (`Apps/EfbyPostmanPad`) consume el producto `EfbyPresentation`.

## Reglas de dependencia

```
EfbyDomain          → (ninguna dependencia de proyecto)
EfbyApplication     → EfbyDomain
EfbyInfrastructure  → EfbyDomain, EfbyApplication
EfbyPresentation    → EfbyDomain, EfbyApplication, EfbyInfrastructure
EfbyRequestLabs     → EfbyPresentation
FlowDebugRunner     → EfbyInfrastructure
```

Domain no importa SwiftUI. Application no usa URLSession directamente (solo vía ports implementados en Infrastructure).

## Composition root

`Sources/EfbyPresentation/Composition/AppDependencies.swift` ensambla repositorios, codecs, servicios y use cases (`AppDependencies.live()`).

## Coordinadores de presentación

| Coordinador | Responsabilidad |
|-------------|-----------------|
| `GitWorkspaceCoordinator` | Pull/push, push gate, remoto |
| `GitSessionCoordinator` | Sesión Git (stash, merge, connect, consola) |
| `BitbucketPadCoordinator` | Import Bitbucket (mirror iPad) |
| `RequestTabCoordinator` | Ejecución HTTP |
| `RequestTabsCoordinator` | Drafts de pestañas |
| `WebSocketExecutionCoordinator` | WebSocket y scripts |
| `FlowExecutionCoordinator` | Validación y ejecución BPMN |
| `WorkspacePersistenceCoordinator` | Persistencia local y workdir |
| `DocumentImportCoordinator` | Import/export documentos |
| `SharedWorkspaceCoordinator` | Carga del workdir compartido |
| `EnvironmentCoordinator` | Variables y entornos |
| `WorkspaceCatalogCoordinator` | Colecciones, flows, utilities |

Helpers: `CollectionScriptSupport`, `SecurityScopedDirectoryAccess`, `PlatformClipboard`.

## Flujo típico (HTTP)

1. La vista llama a `MainViewModel.sendCurrentRequest()`.
2. `RequestTabCoordinator` invoca `ExecuteHTTPRequestUseCase`.
3. El use case usa `HTTPExecutionServiceProtocol`.
4. `RequestExecutionService` ejecuta la petición y los scripts.
5. El ViewModel aplica variables y persiste vía `WorkspacePersistenceCoordinator`.

## Persistencia

1. **Local** — `WorkspaceRepository` → `~/Library/Application Support/EFBYPostman/workspace.json`.
2. **Workdir Git** — `SharedCollectionsRepository` (colecciones, entornos, flows, snapshot).
3. **Remoto** — pull/push manual (`GitSessionCoordinator` / `GitWorkspaceCoordinator`).

## Puertos y casos de uso

Puertos en `Sources/EfbyApplication/Ports/` (workspace, colecciones compartidas, HTTP, Git, codecs Postman/OpenAPI, WebSocket).

Casos de uso en `Sources/EfbyApplication/UseCases/` (ejecutar HTTP, import/export, load/save workspace, pull/push Git, persistir snapshot).

## Tests

Suite `Tests/AppCoreTests/` (166 tests): dominio e infraestructura, casos de uso, coordinadores y flujos de `MainViewModel`.

```bash
swift test
```
