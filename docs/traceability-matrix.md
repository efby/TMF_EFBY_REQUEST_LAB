# Matriz de trazabilidad

Enlace entre especificaciones SDD, IDs de requisito, casos de prueba y estado de verificación.

**Leyenda de estado:** Automatizado | Manual | Pendiente

## Resumen por spec

| Spec | Requisitos | Automatizado | Cobertura |
|------|------------|--------------|-----------|
| `http-request-execution` | 4 | 4 | Alta |
| `variable-resolution` | 3 | 3 | Alta |
| `postman-interop` | 4 | 4 | Alta |
| `git-workspace` | 3 | 3 | Alta |
| `websocket-client` | 3 | 3 | Alta |
| `workspace-flow` | 4 | 4 | Alta |
| `javascript-pm-runtime` | 4 | 4 | Alta |
| `persistencia-workspace` | 4 | 4 | Alta |
| `main-view-model-workspace` | 3 | 3 | Alta |
| `javascript-tooling` | 4 | 4 | Alta |
| **Total** | **36** | **36** | **100 %** |

## Detalle por requisito

### http-request-execution.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-HTTP-001 | Variables aplicadas antes de red | `resolvesVariablesBeforeNetworkCall` | Automatizado |
| REQ-HTTP-002 | Scripts pre-request mutan modelo | `preRequestScriptMutatesHeadersInMemory` | Automatizado |
| REQ-HTTP-003 | Error de red coherente | `networkErrorReturnsStructuredResult` | Automatizado |
| REQ-HTTP-004 | Estado enviando consistente | `sendingFlagClearedAfterCompletion` | Automatizado |

**Suite:** `RequestExecutionServiceTests`

### variable-resolution.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-VAR-001 | Precedencia local > entorno > colección > global | `environmentOverridesCollection` | Automatizado |
| REQ-VAR-002 | Plantillas `{{name}}` resueltas | `resolvesTemplateSyntax` | Automatizado |
| REQ-VAR-003 | Valor ausente sin crash | `missingVariableReturnsEmptyOrMarker` | Automatizado |

**Suite:** `VariableResolverTests`

### postman-interop.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-POST-001 | Import colección v2.1 | `importsV21CollectionPreservesTree` | Automatizado |
| REQ-POST-002 | Import colección v2.0 | `importsV2Collection` | Automatizado |
| REQ-POST-003 | Export round-trip | `exportImportRoundTripPreservesSemantics` | Automatizado |
| REQ-POST-004 | Import OpenAPI 3.x JSON | `importsOpenAPI30Document` | Automatizado |

**Suites:** `PostmanCollectionCodecTests`, `PostmanEnvironmentCodecTests`, `OpenAPIImporterTests`

### git-workspace.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-GIT-001 | Errores estructurados en pull | `pullAuthFailureReturnsStructuredError` | Automatizado |
| REQ-GIT-002 | Status del repositorio | `statusReportsModifiedFiles` | Automatizado |
| REQ-GIT-003 | Colecciones compartidas en directorio Git | `loadsCollectionsFromManagedDirectory` | Automatizado |

**Suites:** `GitRepositoryServiceTests`, `SharedCollectionsRepositoryTests`

### websocket-client.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-WS-001 | Handshake y mensajes | `receivesIncomingMessageUpdatesTranscript` | Automatizado |
| REQ-WS-002 | Estado de conexión predecible | `connectionStateTransitionsCorrectly` | Automatizado |
| REQ-WS-003 | Cancelación al cerrar pestaña | `closingTabCancelsBackgroundTasks` | Automatizado |

**Suite:** `WebSocketExecutionServiceTests`

### workspace-flow.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-FLOW-001 | Ejecución respeta grafo | `executesReferenceFlowInOrder` | Automatizado |
| REQ-FLOW-002 | Gateway condicional determinista | `exclusiveGatewaySelectsExpectedBranch` | Automatizado |
| REQ-FLOW-003 | Logs con imágenes inline | `inlineImageLogLinePreservesMetadata` | Automatizado |
| REQ-FLOW-004 | Validación rechaza grafo inválido | `validatorRejectsInconsistentGraph` | Automatizado |

**Suites:** `WorkspaceFlowExecutionServiceTests`, `WorkspaceFlowGatewayConditionTests`, `WorkspaceFlowInlineImageLogLineTests`

### javascript-pm-runtime.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-PM-001 | RSA OAEP-SHA256 hex output | `rsaEncryptProducesHexCiphertext` | Automatizado |
| REQ-PM-002 | AES CBC round-trip | `aesCBCEncryptDecryptRoundTrip` | Automatizado |
| REQ-PM-003 | Alias encryptRsa | `encryptRsaAliasMatchesRSAOAEP` | Automatizado |
| REQ-PM-004 | Error devuelve vacío sin crash | `invalidRSAInputReturnsEmptyString` | Automatizado |

**Suite:** `ScriptEngineTests`

### persistencia-workspace.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-PERS-001 | Load sin archivo devuelve starter | `loadMissingFileReturnsStarterState` | Automatizado |
| REQ-PERS-002 | Migración esquema antiguo | `migratesLegacySchemaToCurrent` | Automatizado |
| REQ-PERS-003 | Rechaza esquema futuro | `rejectsFutureSchemaVersion` | Automatizado |
| REQ-PERS-004 | Save atómico preserva datos | `saveAndLoadRoundTripPreservesCollections` | Automatizado |

**Suite:** `WorkspaceRepositoryTests`

### main-view-model-workspace.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-VM-001 | Variables de flujo propagadas | `flowExecutionUpdatesEnvironmentVariables` | Automatizado |
| REQ-VM-002 | Coherencia pestaña-workspace | `tabStateReflectsWorkspaceEnvironment` | Automatizado |
| REQ-VM-003 | Clonación de flujo conserva relaciones | `clonedFlowExecutesEquivalentScenario` | Automatizado |

**Suites:** `MainViewModelEnvironmentFlowTests`, `MainViewModelFlowCloneTests`

### javascript-tooling.spec.md

| ID | Requisito | Caso de prueba | Estado |
|----|-----------|----------------|--------|
| REQ-TOOL-001 | Autocompletado alinea con pm.* | `suggestsPmCryptoSymbols` | Automatizado |
| REQ-TOOL-002 | Formateo estable | `formatsNestedBlocksConsistently` | Automatizado |
| REQ-TOOL-003 | Parser extrae símbolos | `extractsFunctionAndObjectSymbols` | Automatizado |
| REQ-TOOL-004 | Comentarios no confunden parser | `ignoresCommentsInSymbolExtraction` | Automatizado |

**Suites:** `JavaScriptRuntimeAutocompleteTests`, `JavaScriptSourceFormatterTests`, `JavaScriptUtilitySymbolParserTests`

## Pruebas manuales (NFR / UI)

| ID | Caso | Documento |
|----|------|-----------|
| REQ-MAN-001 | UI ventana mínima usable | `07-plan-pruebas.md` M-01 a M-08 |
| REQ-MAN-002 | DMG instalación end-user | `08-despliegue.md` |

## Mantenimiento

Al añadir un requisito:

1. Asignar ID `REQ-<AREA>-<NNN>` en la spec.
2. Añadir fila en esta matriz.
3. Crear o ampliar test con nombre legible.
4. Verificar `swift test` y CI verde.
