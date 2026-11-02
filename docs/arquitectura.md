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
| `RequestTabsCoordinator` | Borradores de pestañas y comparación semántica de peticiones para persistencia |
| `WebSocketExecutionCoordinator` | WebSocket y scripts |
| `FlowExecutionCoordinator` | Validación y ejecución BPMN |
| `WorkspacePersistenceCoordinator` | Persistencia local y workdir |
| `DocumentImportCoordinator` | Import/export documentos |
| `SharedWorkspaceCoordinator` | Carga del workdir compartido |
| `EnvironmentCoordinator` | Variables y entornos |
| `WorkspaceCatalogCoordinator` | Colecciones, flows, utilities |

Helpers: `CollectionScriptSupport`, `SecurityScopedDirectoryAccess`, `PlatformClipboard`.

## Organización del estado y la interfaz

`Sources/EfbyPresentation/MainViewModel.swift` conserva el estado observable, las dependencias y la inicialización. Sus operaciones se agrupan en extensiones `@MainActor` dentro de `Sources/EfbyPresentation/MainViewModel/`:

| Archivo | Responsabilidad |
|---------|-----------------|
| `MainViewModel+Catalog.swift` | Colecciones, carpetas, peticiones, flujos y utilitarios del catálogo |
| `MainViewModel+Environments.swift` | Entornos y variables |
| `MainViewModel+Flows.swift` | Ejecución de flujos y sesiones de resultados |
| `MainViewModel+GitBitbucket.swift` | Operaciones Git, credenciales e importación Bitbucket |
| `MainViewModel+RequestsTabs.swift` | Edición, pestañas y ejecución HTTP |
| `MainViewModel+WebSocket.swift` | Conexiones, mensajes y scripts WebSocket |
| `MainViewModel+WorkspacePersistence.swift` | Carga, cambio de workspace, importación y persistencia |

Las extensiones comparten la misma instancia y sus publicaciones; la lógica especializada sigue delegándose a los coordinadores. Los miembros compartidos entre archivos tienen acceso interno cuando es necesario, sin ampliar la API pública.

`Sources/EFBYPostman/Views/RootView.swift` compone la pantalla y mantiene su estado de presentación. Los componentes están en `Views/Chrome/`, `Sidebar/`, `Workspace/`, `Request/`, `Response/` y `Sheets/`; los controles reutilizables y el tema están en `Common/` y `Theme/`. Cada vista conserva su estado local, enlaces y acciones. Para modificar un panel, abrir su componente en lugar de añadir su implementación a `RootView`.

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

Suite `Tests/AppCoreTests/`: dominio e infraestructura, casos de uso, coordinadores y flujos de `MainViewModel`. `RequestPersistenceEquivalenceTests` verifica que los identificadores generados no provocan escrituras, mientras que los cambios de contenido y orden siguen detectándose.

```bash
swift test
```

Las pruebas de interfaz macOS viven en `Tests/UITests/`, en un target Xcode independiente. `Tools/test_ui.sh` abre la app real de SwiftPM con almacenamiento temporal y HTTP local para verificar navegación, pestañas, workspaces y envío/cancelación. No forman parte de `swift test`; requieren una sesión gráfica. Detalles y comandos en [plan-pruebas.md](plan-pruebas.md).
