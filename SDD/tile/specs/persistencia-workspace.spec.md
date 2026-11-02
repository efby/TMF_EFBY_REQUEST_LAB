---
name: Persistencia del workspace
description: JSON en Application Support, versión de esquema, migraciones y escritura atómica.
targets:
  - ambito:paquete-efby / capa:nucleo / area:persistencia-workspace
---

## Comenzar desde cero

1. Define un tipo raíz **codable** que incluya `schemaVersion` entero y todos los submodelos del workspace.
2. Fija `currentSchemaVersion` en una constante de producto; incrementa solo cuando el JSON cambie de forma incompatible.
3. Implementa **decode** tolerante a claves ausentes para versiones antiguas y una función **migrate** que eleve cada versión intermedia hasta la actual.
4. Implementa **save** con escritura atómica y **load** que devuelva estado inicial si el archivo no existe.
5. Usa actor o serialización única si la UI y los flujos pueden guardar concurrentemente.
6. Prueba con archivos de fixture por versión de esquema.

## Comportamiento

- Archivos de versión de esquema **mayor** que la soportada deben rechazarse con error claro para el usuario.
- Migraciones no deben perder colecciones ni entornos salvo que el cambio de producto esté documentado y aceptado.

## Verificación

- Pruebas automatizadas que carguen fixtures viejos y comparen el modelo migrado con expectativas.
- Prueba de escritura concurrente o rápida repetición sin archivo corrupto.

### Recuperación entre sesiones y versiones

- La instalación en Aplicaciones conserva `Application Support/EFBYPostman/workspace.json` y el nombre del workspace seleccionado.
- El arranque intenta restaurar el bookmark guardado y admite referencias ordinarias de versiones anteriores. Si la referencia ya no se resuelve, intenta la ruta absoluta previamente guardada, siempre comprobando que el sistema permite leer el directorio.
- Un acceso ordinario válido no requiere que `startAccessingSecurityScopedResource()` adquiera un alcance adicional. Los alcances adquiridos se liberan una sola vez; no se interpreta un permiso denegado como acceso válido.
- Una recuperación correcta renueva el bookmark cuando es posible. Si la carpeta falta o es inaccesible, se conserva la selección y el contenido local recuperable, y se pide seleccionar una carpeta accesible.
- Regresiones en `SecurityScopedDirectoryAccessTests`, `WorkspaceSessionRestorationTests` y los dos casos de reapertura de `RequestLabUITests`.

### Autoguardado y escrituras eficientes

- El autoguardado agrupa ediciones durante 250 ms, con espera máxima de 2 s. Mantiene un estado pendiente por destino y un escritor serial; los flush simultáneos drenan también lo que llegue mientras hay una escritura en curso.
- El último snapshot local se separa de las colecciones, entornos, utilidades y flujos explícitamente autorizados para compartir. La fusión de solicitudes no amplía esos permisos a cambios posteriores locales.
- Los fallos conservan pendientes y borradores recuperables, sin adelantar baselines. La confirmación ocurre después del éxito; el guardado compartido conserva dos fases locales cuando es necesario.
- Enviar, cambiar de workspace y cerrar requieren flush exitoso. El cierre de una pestaña conserva la edición si falla; el cierre de la aplicación devuelve éxito/fallo al delegado nativo.
- Un save compara con los bytes actuales del disco y evita escribir si no cambiaron. Los conjuntos idénticos evitan staging/copias/movimientos, conservando validación y recuperación. Un conjunto cambiado mantiene la transacción de directorio.
- Regresiones en `AutosaveQueueTests`, `AutosaveTests`, `AutosavePersistenceTests` y `RepositoryWriteEfficiencyTests`. `PerformanceMeasurementTests` mide cargas repetibles y comprueba cantidades de escrituras, además del último estado. Resultados en [rendimiento.md](../../../docs/rendimiento.md).

## Trazabilidad

### Integridad del workdir compartido

- Cada conjunto (colecciones, entornos, utilidades o flujos) se codifica y valida antes de reemplazar su directorio. Un respaldo permite restaurar el conjunto anterior si falla la instalación; una carga posterior recupera el respaldo si falta el directorio actual.
- Los JSON inválidos se notifican con su ruta y bloquean la sustitución del conjunto. Los archivos ajenos y subdirectorios se conservan.
- La recuperación es por conjunto y por instancia serial; no ofrece una transacción global del workspace ni coordinación entre procesos. El formato JSON y la versión de esquema no cambian.
- Regresiones en `SharedCollectionsRepositoryTests`: `testFailedPreparationLeavesPreviousCollectionsIntact`, `testFailedInstallationRollsBackPreviousCollections`, `testFailedRollbackKeepsBackupAndNextLoadRecoversIt` y `testCorruptCollectionReportsFilenameAndBlocksReplacement`, entre otras.

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-PERS-001 | `loadMissingFileReturnsStarterState` | Automatizado |
| REQ-PERS-002 | `migratesLegacySchemaToCurrent` | Automatizado |
| REQ-PERS-003 | `rejectsFutureSchemaVersion` | Automatizado |
| REQ-PERS-004 | `saveAndLoadRoundTripPreservesCollections` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
