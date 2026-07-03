# Requisitos no funcionales

Extraídos de [funcionalidades-requeridas.md](../../SDD/tile/rules/funcionalidades-requeridas.md) y ampliados para el proyecto.

## Compatibilidad

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-COMP-001 | macOS mínimo 14 según `Package.swift` | `swift build` en macOS-14 CI |
| NFR-COMP-002 | iOS 17+ para app iPad | Build Xcode `EfbyPostmanPad` sin errores |
| NFR-COMP-003 | Swift 6 con concurrencia estricta | Compilación sin warnings de concurrency |
| NFR-COMP-004 | Postman Collection v2.0 y v2.1 | Tests `PostmanCollectionCodecTests` |
| NFR-COMP-005 | OpenAPI 3.0/3.1 JSON | Tests `OpenAPIImporterTests` |

## Estabilidad

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-STAB-001 | Sin fugas en WebSockets largos | Cierre de pestaña cancela tareas; test `WebSocketExecutionServiceTests` |
| NFR-STAB-002 | Sin retain cycles en tareas async | `@MainActor` ViewModel; revisión manual de closures |
| NFR-STAB-003 | Persistencia atómica | `WorkspaceRepository.save` usa `.atomic` write |
| NFR-STAB-004 | Migración de esquema sin pérdida | Tests `WorkspaceRepositoryTests` con fixtures v1-v3 |
| NFR-STAB-005 | Estado coherente tras error de red | Tests error simulado en `RequestExecutionServiceTests` |

## Seguridad

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-SEC-001 | Secretos no en logs de consola | Regla en [seguridad-encriptacion.md](../../SDD/tile/rules/seguridad-encriptacion.md) |
| NFR-SEC-002 | TLS configurable para laboratorios | Opciones TLS en editor de request |
| NFR-SEC-003 | `pm.crypto` RSA-OAEP-SHA256 y AES nativo | Tests ScriptEngine + spec `javascript-pm-runtime` |
| NFR-SEC-004 | Scripts acotados en JavaScriptCore | Sin acceso a filesystem/red desde script |
| NFR-SEC-005 | Credenciales Git vía Keychain/sistema | No hardcodeadas en repo |

## Rendimiento

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-PERF-001 | UI responsiva durante ejecución HTTP | Operaciones red en `Task` async, no bloqueo main thread |
| NFR-PERF-002 | Carga workspace < 2s para 50 colecciones | Checklist manual con dataset de prueba |
| NFR-PERF-003 | Flujos BPMN con paralelismo controlado | Tests `WorkspaceFlowExecutionServiceTests` |

## Mantenibilidad

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-MAINT-001 | Specs actualizadas con cada cambio de contrato | Revisión en PR + matriz trazabilidad |
| NFR-MAINT-002 | CI verde en cada push | GitHub Actions `ci.yml` |
| NFR-MAINT-003 | Tests unitarios en núcleo | `swift test` ≥ 120 casos |
| NFR-MAINT-004 | Documentación en `docs/` | Índice completo en README y `docs/README.md` |

## Usabilidad

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-UX-001 | Ventana mínima usable 1024×700 | `RootView` min frame |
| NFR-UX-002 | Menús workspace (nueva petición, enviar) | Checklist manual macOS |
| NFR-UX-003 | Errores Git guiados al usuario | Tests `GitRepositoryServiceTests` errores |
| NFR-UX-004 | Cierre ordenado con persistencia | `onDisappear` / `applicationWillTerminate` guarda workspace |

## Distribución

| ID | Requisito | Criterio de verificación |
|----|-----------|--------------------------|
| NFR-DIST-001 | DMG instalable en macOS | GitHub Release con artefacto `.dmg` |
| NFR-DIST-002 | Firma Developer ID (producción) | `build_dmg.sh --sign --notarize` |
| NFR-DIST-003 | Repo público accesible | `github.com/efby/TMF_EFBY_REQUEST_LAB` |
