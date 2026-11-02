# Plan de pruebas

## Objetivo

Garantizar que las 10 especificaciones SDD tienen verificación automatizada o manual documentada, con CI ejecutando la suite en cada cambio.

## Tipos de prueba

| Tipo | Alcance | Herramienta | Frecuencia |
|------|---------|-------------|------------|
| Unitaria | Servicios, use cases, coordinadores, codecs, repositorios | XCTest (`AppCoreTests`) | Cada commit (CI) |
| Integración | ViewModel + servicios reales | XCTest con fixtures | Cada PR |
| Interfaz macOS | Navegación, pestañas, workspaces, envío y cancelación HTTP | XCTest + XCUIAutomation (`RequestLabUITests`) | Cada push/PR en CI y ejecución local en sesión gráfica |
| Manual | UI SwiftUI, BPMN editor visual | Checklist en spec | Pre-release |
| Smoke | Build y arranque app | `swift build` + launch manual | Pre-release |

## Comandos

```bash
# Desde la raíz del repositorio
swift build
swift test
swift test --filter OpenAPIImporterTests

# Pruebas de interfaz macOS (requieren Xcode completo y una sesión gráfica)
./Tools/test_ui.sh
# Solo compilar la app y el runner de interfaz
./Tools/test_ui.sh --build-only
# Ejecutar una clase o caso concreto
./Tools/test_ui.sh -only-testing:EfbyRequestLabUITests/RequestLabUITests

# Verificar y ejecutar el exportador de reportes de CI
python3 -B -m unittest discover -s Tests/ToolTests -v
python3 Tools/export_ui_test_results.py \
  --result-bundle RUTA/Results.xcresult \
  --output-directory RUTA/report \
  --test-exit-code 0
```

## Pruebas de interfaz automatizadas

El proyecto `Tests/UITests/EfbyRequestLabUITests.xcodeproj` ejecuta la aplicación macOS real compilada por SwiftPM. `Tools/test_ui.sh` prepara una app debug con identificador independiente y firma local; no sustituye la aplicación instalada. El esquema compartido permite repetir la ejecución desde Xcode después de preparar la app con `--build-only`.

La configuración `--ui-testing` existe solo en debug. Cada prueba usa un directorio temporal `efby-ui-tests-*`, con workspaces Alpha y Beta, y un servidor HTTP enlazado a `127.0.0.1` en un puerto libre. Se usan los repositorios y el transporte HTTP de producción. El arranque rechaza una configuración incompleta o un directorio fuera de las ubicaciones temporales; nunca recurre al almacenamiento habitual para una ejecución de interfaz.

| Caso | Verificación |
|------|--------------|
| Navegación | Cambiar secciones del editor y de respuesta; abrir/cerrar el editor de entorno y volver a la petición |
| Pestañas | Abrir, seleccionar, crear y cerrar; conservar URL y sección por petición; al cerrar la última se crea una nueva |
| Workspace | Alpha → Beta → Alpha confirma el aviso informativo, cambia colecciones y entornos, y recupera el borrador de una petición nueva sin mezclar contenido |
| Envío HTTP | Mostrar respuesta 200 y cuerpo del servidor local, actualizar historial y dejar Cancel deshabilitado |
| Cancelación | Mostrar envío pendiente, habilitar Cancel, cancelar y permitir un nuevo envío; descartar respuesta tardía |
| Cambio durante envío | Cambiar a Beta con una petición Alpha pendiente y mantener el resultado e historial de Beta aislados |
| Reapertura | Cerrar normalmente y volver a abrir conserva el workspace seleccionado, su petición y su entorno, sin pedir de nuevo la carpeta |
| Versiones anteriores | Una referencia a carpeta que ya no se resuelve se recupera desde la ruta guardada accesible y se renueva el bookmark |

El cambio de workspace conserva el comportamiento existente: las pestañas de colección sin cambios se vuelven a abrir desde la barra lateral; los borradores de peticiones nuevas se restauran automáticamente.

Las esperas se basan en elementos accesibles y condiciones del servidor. La respuesta lenta se libera explícitamente desde la prueba. Los fallos adjuntan captura de pantalla y árbol de accesibilidad al resultado de Xcode. Los resultados se guardan en `.build/ui-tests/Results/*.xcresult`; se puede elegir otra ruta con `--result-bundle RUTA`.

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

- Se ejecuta en push y pull requests a `main` y `master`, y mediante `workflow_dispatch`.
- Usa `macos-26`, prefiere Xcode 26.6 y comprueba que Swift sea compatible con tools 6.3. La [imagen alojada](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) dispone de una sesión gráfica para XCTest UI.
- Mantiene el job `test-and-package`: verifica el exportador, resuelve dependencias, ejecuta `swift test` y la suite UI, publica el resumen y guarda artefactos. El DMG de este workflow solo se construye si todas las comprobaciones terminan correctamente.
- UI sigue ejecutándose si falla la suite del núcleo y las dependencias se resolvieron. Las pruebas conservan su código de salida; no se usa `continue-on-error`. La ejecución UI es secuencial, con límites de 120 segundos por caso y un máximo de 180; cada suite tiene un límite de paso de 15 minutos.
- Antes de ejecutar UI, `Tools/configure_ui_test_display.swift` comprueba una pantalla de al menos 1440×900 puntos y selecciona un modo compatible, preferentemente 1920×1080, si hace falta. Si CoreGraphics no puede configurarlo, intenta las utilidades Anka/VMware preinstaladas, cuando existen, y verifica el tamaño efectivo. Solo permite cambiar la resolución en GitHub Actions; `--check-only` y `--self-test` no modifican pantallas. Si no se consigue una resolución válida, falla la preparación y se omite la suite UI, conservando el diagnóstico.
- La exportación y subida de resultados se ejecutan también tras un fallo. El artefacto `EFBYRequestLab-test-results-<run_id>-<run_attempt>` se conserva 14 días y contiene únicamente `.build/ci-results/`.

Contenido del artefacto:

| Ruta | Contenido |
|------|-----------|
| `toolchain.log` | Versión de macOS, Xcode y Swift usada |
| `core/tests.log`, `core/exit-code.txt` | Salida completa y estado de `swift test`, incluidos los casos omitidos |
| `ui/tests.log`, `ui/exit-code.txt` | Compilación, ejecución de interfaz y código de salida |
| `ui/display.log`, `ui/display-selection-tests.log` | Modos de pantalla disponibles, resolución efectiva y verificación de selección de modo |
| `ui/Results.xcresult` | Resultado original para abrir en Xcode |
| `ui/report/summary.md`, `summary.json`, `tests.json` | Resumen legible, recuentos y resultados por caso |
| `ui/report/junit.xml` | Reporte JUnit de la suite UI |
| `ui/report/attachments/` | Capturas, árbol de accesibilidad y demás adjuntos de los casos fallidos |

Para investigar un fallo, abrir la ejecución de **CI** en GitHub Actions y descargar su artefacto de pruebas. `ui/report/summary.md` identifica el caso; las imágenes y el árbol están en `attachments/`. El `.xcresult` conserva el detalle completo. Si falla la compilación o el arranque antes de producirlo, quedan el log y un reporte diagnóstico que indica que no hay resultados de casos disponibles; la exportación también marca fallo.

El exportador recibe el estado original mediante `--test-exit-code` y lo documenta. Exportar correctamente pruebas fallidas no convierte su ejecución en exitosa. El directorio de salida debe ser nuevo o estar vacío para evitar mezclar adjuntos de distintas ejecuciones. Los logs del núcleo conservan el resultado nativo de XCTest; no se usa el XML vacío que [SwiftPM puede generar](https://github.com/swiftlang/swift-package-manager/issues/9961) para una suite sin Swift Testing.

## Gestión de fixtures

- Postman: `Examples/postman-v21-sample.json`, `Examples/postman-v2-sample.json`
- OpenAPI: `Examples/openapi-sample.json`
- Persistencia: fixtures inline en `WorkspaceRepositoryTests` (JSON por versión de esquema)

## Registro de incidencias

Las incidencias de prueba se documentan como:

1. ID `REQ-*` afectado en la matriz de trazabilidad.
2. Test que reproduce el fallo (Red TDD).
3. Fix + verificación Green.
