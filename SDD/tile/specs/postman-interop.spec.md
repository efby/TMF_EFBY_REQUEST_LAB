---
name: Interoperabilidad Postman
description: Codificación y decodificación de colecciones y entornos compatibles con Postman.
targets:
  - ambito:paquete-efby / capa:nucleo / area:interoperabilidad-postman
---

## Comenzar desde cero

1. Obtén **ejemplos reales** exportados desde Postman (colección mínima y entorno mínimo) y guárdalos como datos de prueba versionados (JSON), no como código fuente de la app.
2. Define el **mapeo campo a campo** hacia el modelo interno del workspace en una tabla de equivalencias revisable por el equipo.
3. Implementa primero la **lectura** (importación) con pruebas que comparen el modelo resultante con un golden struct o snapshot estable.
4. Implementa la **escritura** (exportación) y la ronda de ida y vuelta: importar → exportar → reimportar; los datos semánticos críticos deben conservarse.
5. Documenta las **limitaciones** conocidas (campos no soportados, extensiones propietarias) en la spec o en la guía de usuario.

## Colecciones

- Importar y exportar colecciones debe preservar los campos que el modelo interno necesita para ejecutar peticiones y organizar carpetas.
  - **Verificación**: batería de JSON de ejemplo y aserciones sobre el árbol de colección resultante.

## Entornos

- Los perfiles de entorno deben serializarse y deserializarse conservando variables y el vínculo con el resolutor de variables del workspace.
  - **Verificación**: casos con varios entornos, variables secretas marcadas y sustitución posterior en una petición de prueba.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-POST-001 | `importsV21CollectionPreservesTree` | Automatizado |
| REQ-POST-002 | `importsV2Collection` | Automatizado |
| REQ-POST-003 | `exportImportRoundTripPreservesSemantics` | Automatizado |
| REQ-POST-004 | `importsOpenAPI30Document` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
