# Project Index — EFBY Request Lab

Indice persistido del proyecto para navegar rapido en sesiones futuras sin volver a inspeccionar todo el codigo.

**Repo publico:** `github.com/efby/TMF_EFBY_REQUEST_LAB` | **Documentacion:** `docs/README.md`

## Arquitectura SPM (Clean Architecture)

| Target | Contenido |
| --- | --- |
| `EfbyDomain` | `Sources/AppCore/Domain/` — modelos puros |
| `EfbyApplication` | `Sources/EfbyApplication/` — ports + use cases |
| `EfbyInfrastructure` | `Sources/AppCore/Application/` — servicios, repositorios |
| `EfbyPresentation` | `Sources/EfbyPresentation/` — MainViewModel, 12 coordinadores, composition root |
| `EfbyRequestLabs` | App macOS SwiftUI (`import EfbyPresentation`) |

Composition root: `Sources/EfbyPresentation/Composition/AppDependencies.swift`

## Start Here

| Area | Abrir primero | Para que sirve |
| --- | --- | --- |
| App shell | `Sources/EFBYPostman/EFBYPostmanApp.swift` | Punto de entrada de la app y comandos globales de macOS. |
| Pantalla principal | `Sources/EFBYPostman/Views/RootView.swift` | Layout principal, sidebar, tabs, editor, response pane, overlays. |
| Estado central | `Sources/EfbyPresentation/MainViewModel.swift` | Orquesta UI; delega en 12 coordinadores + `CollectionScriptSupport`. |
| Modelos base | `Sources/AppCore/Domain/HTTPModels.swift` y `Sources/AppCore/Domain/WorkspaceModels.swift` | Requests, responses, scripts, variables, collections, entornos, drafts. |
| HTTP runtime | `Sources/AppCore/Application/RequestExecutionService.swift` | Ejecuta requests HTTP, resuelve variables y corre scripts. |
| WebSocket runtime | `Sources/AppCore/Application/WebSocketExecutionService.swift` | Prepara handshake, procesa mensajes, scripts `onMessage` y `onDone`. |
| Script runtime | `Sources/AppCore/Application/ScriptEngine.swift` | JS runtime, `pm.*`, `pm.crypto.*`, `pm.websocket.*`, mutaciones de request. |
| Persistencia local y workdir | `Sources/AppCore/Application/WorkspaceRepository.swift` y `Sources/AppCore/Application/SharedCollectionsRepository.swift` | Guarda `workspace.json`, snapshot compartido y carpetas del workdir. |

## Quick Navigation

| Quiero cambiar... | Abrir |
| --- | --- |
| La barra superior, sidebar o tabs | `Sources/EFBYPostman/Views/RootView.swift` |
| El editor de scripts o utilitarios | `Sources/EFBYPostman/Views/ScriptsTabView.swift`, `Sources/EFBYPostman/Views/WorkspaceUtilityEditor.swift`, `Sources/EFBYPostman/Views/MacCodeEditor.swift` |
| El editor BPMN de flows | `Sources/EFBYPostman/Views/WorkspaceFlowEditor.swift`, `Sources/EFBYPostman/Views/BPMNFlowWebEditor.swift` |
| La semantica de variables `{{...}}` | `Sources/AppCore/Application/VariableResolver.swift` |
| Lo que expone `pm.environment`, `pm.request`, `pm.websocket`, `pm.crypto` | `Sources/AppCore/Application/ScriptEngine.swift` |
| El build local, firma y notarizacion | `Tools/build_dmg.sh` |
| La importacion/exportacion Postman/OpenAPI | `Sources/AppCore/Application/PostmanCollectionCodec.swift`, `Sources/AppCore/Application/PostmanEnvironmentCodec.swift`, `Sources/AppCore/Application/OpenAPIImporter.swift` |
| Git pull/push/connect | `Sources/AppCore/Application/GitRepositoryService.swift`, `GitSessionCoordinator`, `GitWorkspaceCoordinator` |
| Tests de una zona concreta | `Tests/AppCoreTests/*` (166 tests) |
| Documentacion del proyecto | `docs/README.md` |
| Matriz trazabilidad SDD/TDD | `docs/traceability-matrix.md` |
| Specs SDD | `SDD/tile/specs/*.spec.md` |

## Core Entry Points

### App + UI

| Referencia | Que hace |
| --- | --- |
| `Sources/EFBYPostman/EFBYPostmanApp.swift` | Entry point SwiftUI y app delegate. |
| `Sources/EFBYPostman/Views/RootView.swift:6` | `RootView`: pantalla base de la aplicacion. |
| `Sources/EFBYPostman/Views/RootView.swift:271` | `TopChromeBar`: selector de workspace, workdir, Git, pull, push. |
| `Sources/EFBYPostman/Views/RootView.swift:361` | `SidebarPane`: colecciones, historial, utilitarios, flows, entornos. |
| `Sources/EFBYPostman/Views/RootView.swift:1460` | `WorkspacePane`: contenedor del request abierto. |
| `Sources/EFBYPostman/Views/RootView.swift:1480` | `RequestTabsBar`: tabs de requests. |
| `Sources/EFBYPostman/Views/RootView.swift:1632` | `RequestHeader`: URL, metodo, botones de ejecucion y estado. |
| `Sources/EFBYPostman/Views/RootView.swift:2951` | `ResponsePane`: cuerpo/console/transcript de respuesta. |
| `Sources/EFBYPostman/Views/RootView.swift:3673` | `EnvironmentEditor`: editor visual del environment activo. |
| `Sources/EFBYPostman/Views/RootView.swift:4312` | `EditableVariableList`: renderer reusable para variables editables. |

### ViewModel y coordinadores

| Referencia | Que hace |
| --- | --- |
| `Sources/EfbyPresentation/MainViewModel.swift` | Estado UI; delega en coordinadores. |
| `Sources/EfbyPresentation/RequestTabState.swift` | Estado de pestaña de request. |
| `Sources/EfbyPresentation/Composition/AppDependencies.swift` | Composition root. |
| `Sources/EfbyPresentation/Coordinators/BitbucketPadCoordinator.swift` | Plan e import Bitbucket (iPad). |
| `Sources/EfbyPresentation/Support/CollectionScriptSupport.swift` | Scripts y auth heredada de colección/carpeta. |
| `Sources/EfbyPresentation/Coordinators/GitSessionCoordinator.swift` | Pull, stash, merge, connect, consola Git. |
| `Sources/EfbyPresentation/Coordinators/GitWorkspaceCoordinator.swift` | Use cases pull/push y push gate. |
| `Sources/EfbyPresentation/Coordinators/EnvironmentCoordinator.swift` | Variables y sincronización de entornos. |
| `Sources/EfbyPresentation/Coordinators/WorkspaceCatalogCoordinator.swift` | Catálogo colecciones/flows/utilities. |
| `Sources/EfbyPresentation/Coordinators/SharedWorkspaceCoordinator.swift` | Carga/fusión del workdir compartido. |
| `Sources/EfbyPresentation/Coordinators/WorkspacePersistenceCoordinator.swift` | Persistencia local + workdir. |
| `Sources/EfbyPresentation/Coordinators/FlowExecutionCoordinator.swift` | Validación y ejecución BPMN. |
| `Sources/EfbyPresentation/Coordinators/RequestTabCoordinator.swift` | Ejecución HTTP. |
| `Sources/EfbyPresentation/Coordinators/RequestTabsCoordinator.swift` | Drafts de pestañas. |
| `Sources/EfbyPresentation/Coordinators/WebSocketExecutionCoordinator.swift` | WebSocket + scripts. |
| `Sources/EfbyPresentation/Coordinators/DocumentImportCoordinator.swift` | Import/export documentos. |

## Domain Model Map

| Referencia | Que contiene |
| --- | --- |
| `Sources/AppCore/Domain/HTTPModels.swift:37` | `HTTPMethod` |
| `Sources/AppCore/Domain/HTTPModels.swift:61` | `KeyValueEntry` |
| `Sources/AppCore/Domain/HTTPModels.swift:88` | `RequestBodyModel` |
| `Sources/AppCore/Domain/HTTPModels.swift:112` | `AuthConfiguration` |
| `Sources/AppCore/Domain/HTTPModels.swift:157` | `ScriptEventType` |
| `Sources/AppCore/Domain/HTTPModels.swift:162` | `ScriptDefinition` |
| `Sources/AppCore/Domain/HTTPModels.swift:184` | `APIRequestModel` |
| `Sources/AppCore/Domain/HTTPModels.swift:266` | `HTTPResponseModel` |
| `Sources/AppCore/Domain/WorkspaceModels.swift:47` | `EnvironmentProfile` |
| `Sources/AppCore/Domain/WorkspaceModels.swift:121` | `CollectionModel` |
| `Sources/AppCore/Domain/WorkspaceModels.swift:230` | `WorkspaceState` |
| `Sources/AppCore/Domain/FlowModels.swift:28` | `WorkspaceFlowDefinition` |

## Execution Pipelines

### HTTP

| Referencia | Rol |
| --- | --- |
| `Sources/AppCore/Application/RequestExecutionService.swift:155` | `execute(...)`: pipeline HTTP completo. |
| `Sources/AppCore/Application/RequestExecutionService.swift:296` | `executeHTTPRequest(...)`: transporte `URLSession`. |
| `Sources/AppCore/Application/RequestExecutionService.swift:366` | `configuredTransport(...)`: TLS inseguro opcional y diagnostico. |
| `Sources/AppCore/Application/RequestExecutionService.swift:465` | `makeURLRequest(...)`: arma request final con body/headers/query resueltos. |

Orden real del pipeline:

1. `pre-request`
2. resolucion de variables y expresiones
3. construccion de `URLRequest`
4. llamada HTTP
5. `test` / post-response
6. merge de variables y mutaciones de request

### WebSocket

| Referencia | Rol |
| --- | --- |
| `Sources/AppCore/Application/WebSocketExecutionService.swift:186` | `prepareConnection(...)`: corre `pre-request` y arma handshake. |
| `Sources/AppCore/Application/WebSocketExecutionService.swift:263` | `connect(...)`: abre WebSocket y recibe transcript. |
| `Sources/AppCore/Application/WebSocketExecutionService.swift:364` | `executeIncomingMessageScripts(...)`: corre `onMessage`. |
| `Sources/AppCore/Application/WebSocketExecutionService.swift:411` | `executeDoneScripts(...)`: corre `onDone`. |
| `Sources/AppCore/Application/WebSocketExecutionService.swift:487` | `configuredTransport(...)`: diagnostico TLS/handshake. |
| `Sources/AppCore/Application/WebSocketExecutionService.swift:833` | `makeURLRequest(...)`: request final del handshake WS. |

## Script Runtime Map

| Referencia | Rol |
| --- | --- |
| `Sources/AppCore/Application/ScriptEngine.swift:86` | `execute(...)`: entrada general de scripts por evento. |
| `Sources/AppCore/Application/ScriptEngine.swift:131` | `handleMiniCommand(...)`: DSL compacta (`set`, `assert.status`, `assert.json`). |
| `Sources/AppCore/Application/ScriptEngine.swift:202` | `handlePostmanCompatibility(...)`: compatibilidad parcial estilo Postman. |
| `Sources/AppCore/Application/ScriptEngine.swift:618` | registro de `pm.crypto.*` y otros bridges JS nativos. |
| `Sources/AppCore/Application/ScriptEngine.swift:646` | `executeJavaScript(...)`: runtime JavaScriptCore. |

### Objetos JS importantes ya expuestos

| Namespace | Uso |
| --- | --- |
| `pm.environment`, `pm.globals`, `pm.collectionVariables`, `pm.variables` | get/set/unset de variables. |
| `pm.request.headers`, `pm.request.param`, `pm.request.body` | mutacion del request desde scripts. |
| `pm.websocket.onMessage`, `pm.websocket.onDone`, `pm.websocket.disconnect` | hooks de runtime WebSocket. |
| `pm.crypto.aes.*`, `pm.crypto.rsa.*` | cifrado AES/RSA expuesto a JS. |

## Persistence Map

### Local

| Referencia | Que guarda |
| --- | --- |
| `Sources/AppCore/Application/WorkspaceRepository.swift:3` | actor de persistencia local. |
| `Sources/AppCore/Application/WorkspaceRepository.swift:19` | `load()`: lee `~/Library/Application Support/EFBYPostman/workspace.json`. |
| `Sources/AppCore/Application/WorkspaceRepository.swift:30` | `save(...)`: guarda el snapshot local completo. |

### Workdir compartido

| Referencia | Que guarda |
| --- | --- |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:3` | actor para todo lo compartido/versionable. |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:4` | `workdirMarkerFilename = _directoritrabajo` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:5` | `workspaceSnapshotFilename = workspace-state.json` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:55` | `saveCollections(...)` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:106` | `saveEnvironments(...)` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:145` | `saveUtilityLibraries(...)` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:157` | `saveFlows(...)` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:169` | `loadWorkspaceSnapshot(...)` |
| `Sources/AppCore/Application/SharedCollectionsRepository.swift:178` | `saveWorkspaceSnapshot(...)` |

### Estructura esperada del workdir

```text
<repo o workdir>/
  <workspace-name>/
    collections/
    environments/
    utilities/
    flows/
    workspace-state.json
```

## Import / Export / Git

| Referencia | Que hace |
| --- | --- |
| `Sources/AppCore/Application/PostmanCollectionCodec.swift:6` | importa Postman Collection JSON a `CollectionModel`. |
| `Sources/AppCore/Application/PostmanCollectionCodec.swift:36` | exporta coleccion a formato Postman. |
| `Sources/AppCore/Application/PostmanEnvironmentCodec.swift:6` | importa environment Postman. |
| `Sources/AppCore/Application/PostmanEnvironmentCodec.swift:26` | exporta environment Postman. |
| `Sources/AppCore/Application/OpenAPIImporter.swift:6` | importa OpenAPI JSON a coleccion interna. |
| `Sources/AppCore/Application/GitRepositoryService.swift:139` | `status(...)` |
| `Sources/AppCore/Application/GitRepositoryService.swift:245` | `pull(...)` |
| `Sources/AppCore/Application/GitRepositoryService.swift:335` | `commitAndPush(...)` |
| `Sources/AppCore/Application/GitRepositoryService.swift:400` | `connectFlow(...)` |

## Editor / Productivity Tooling

| Referencia | Que hace |
| --- | --- |
| `Sources/EFBYPostman/Views/MacCodeEditor.swift` | bridge del editor web embebido. |
| `Sources/EFBYPostman/Resources/CodeEditor/code-editor.html` | editor real con folding, gutter, scroll y wrapping. |
| `Sources/EFBYPostman/Views/CodeEditorAutocomplete.swift` | UI y contexto de autocomplete. |
| `Sources/AppCore/Application/JavaScriptRuntimeAutocomplete.swift` | catalogo de sugerencias del runtime JS. |
| `Sources/AppCore/Application/JavaScriptUtilitySymbolParser.swift` | extrae simbolos exportados de utilitarios JS. |
| `Sources/AppCore/Application/JavaScriptSourceFormatter.swift` | formatter JS simple del editor. |
| `Sources/EFBYPostman/Views/RememberingVerticalScrollView.swift` | conserva scroll entre tabs y requests. |

## Flow / BPMN

| Referencia | Que hace |
| --- | --- |
| `Sources/EFBYPostman/Views/WorkspaceFlowEditor.swift` | editor visual de flows. |
| `Sources/EFBYPostman/Views/BPMNFlowWebEditor.swift` | wrapper del webview BPMN. |
| `Sources/EFBYPostman/Resources/BPMN/bpmn-editor.html` | UI BPMN embebida. |
| `Sources/AppCore/Application/WorkspaceFlowExecutionService.swift:57` | ejecuta flows. |
| `Sources/AppCore/Application/WorkspaceFlowValidator.swift` | validaciones de flows antes de correr. |

## Tests Map

| Test | Cobertura principal |
| --- | --- |
| `Tests/AppCoreTests/RequestExecutionServiceTests.swift` | HTTP runtime, scripts, request mutations. |
| `Tests/AppCoreTests/WebSocketExecutionServiceTests.swift` | handshake WS, scripts `onMessage` y `onDone`. |
| `Tests/AppCoreTests/MainViewModelEnvironmentFlowTests.swift` | sincronizacion de environments y flujo del view model. |
| `Tests/AppCoreTests/PostmanCollectionCodecTests.swift` | import/export de colecciones. |
| `Tests/AppCoreTests/PostmanEnvironmentCodecTests.swift` | import/export de environments. |
| `Tests/AppCoreTests/VariableResolverTests.swift` | resolucion de `{{variables}}`. |
| `Tests/AppCoreTests/GitRepositoryServiceTests.swift` | logica Git. |
| `Tests/AppCoreTests/WorkspaceFlowExecutionServiceTests.swift` | ejecucion de flows. |
| `Tests/AppCoreTests/JavaScriptRuntimeAutocompleteTests.swift` | autocomplete JS. |
| `Tests/AppCoreTests/JavaScriptUtilitySymbolParserTests.swift` | parsing de simbolos de utilitarios. |
| `Tests/AppCoreTests/JavaScriptSourceFormatterTests.swift` | formatter JS. |

## Build / Distribution

| Referencia | Uso |
| --- | --- |
| `Package.swift` | manifiesto Swift Package. |
| `Tools/build_dmg.sh` | build local, firma, notarizacion y DMG. |
| `Tools/generate_app_icon.swift` | genera icono final. |
| `Resources/AppIcon.png` | Fuente del icono (`.icns` se genera con `Tools/build_dmg.sh`) |

### Comandos frecuentes

```bash
swift build
swift test
./Tools/build_dmg.sh
./Tools/build_dmg.sh --sign
./Tools/build_dmg.sh --notarize
```

## Search Hints

Usar estas busquedas acota mucho el codigo:

```bash
rg -n "persistWorkspace|persistPendingChanges|updateEnvironmentVariables" Sources/AppCore/Presentation/MainViewModel.swift
rg -n "prepareConnection|executeIncomingMessageScripts|executeDoneScripts" Sources/AppCore/Application/WebSocketExecutionService.swift
rg -n "pm.crypto|pm.websocket|pm.request.param|pm.request.headers|pm.request.body" Sources/AppCore/Application/ScriptEngine.swift
rg -n "saveWorkspaceSnapshot|saveUtilityLibraries|saveFlows|saveEnvironments" Sources/AppCore/Application/SharedCollectionsRepository.swift
rg -n "ResponsePane|EnvironmentEditor|RequestHeader|WorkspacePane" Sources/EFBYPostman/Views/RootView.swift
```

## Maintenance Rule

Cuando se agreguen nuevas superficies importantes, actualizar este archivo en el mismo cambio:

- nuevo servicio de `Application`
- nuevo editor/panel principal
- nuevo runtime JS expuesto
- nueva carpeta persistida en el workdir
- nuevo flujo de build/distribucion
