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

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-PERS-001 | `loadMissingFileReturnsStarterState` | Automatizado |
| REQ-PERS-002 | `migratesLegacySchemaToCurrent` | Automatizado |
| REQ-PERS-003 | `rejectsFutureSchemaVersion` | Automatizado |
| REQ-PERS-004 | `saveAndLoadRoundTripPreservesCollections` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
