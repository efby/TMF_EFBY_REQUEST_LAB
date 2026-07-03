---
name: Herramientas JavaScript del editor
description: Autocompletado, formateo y extracción de símbolos para scripts de petición.
targets:
  - ambito:paquete-efby / capa:nucleo / area:tooling-javascript-editor
---

## Comenzar desde cero

1. Enumera las **APIs globales** expuestas al script de petición (objetos, funciones, convenciones de nombres) y congélalas como contrato. El inventario autorizado de **`pm.*`** y cifrado nativo está en [pm-api-javascript-completa.md](../docs/reference/pm-api-javascript-completa.md); la spec hermana [javascript-pm-runtime.spec.md](javascript-pm-runtime.spec.md) cubre el contrato de runtime y pruebas del motor.
2. Implementa el **autocompletado** como función pura: entrada = texto + posición del cursor + contrato de runtime; salida = lista de sugerencias ordenada y documentada.
3. Implementa el **formateo** como paso opcional invocado por la UI; define entradas mínimas (fragmento, ancho, estilo) y salida estable.
4. Implementa el **parser de símbolos** para navegación (lista de identificadores o outline) sin ejecutar código del usuario.
5. Cubre cada pieza con pruebas unitarias de cadenas representativas y regresión cuando amplíes el contrato del runtime.

## Autocompletado

- Las sugerencias deben alinearse con el runtime documentado para scripts de petición.
  - **Verificación**: casos con prefijos comunes y expectativa explícita de etiquetas sugeridas.

## Formateo

- Entradas equivalentes deben producir la misma salida formateada bajo la misma configuración.
  - **Verificación**: pruebas de estabilidad y de fragmentos con saltos de línea anidados.

## Símbolos

- El análisis debe extraer identificadores útiles para outline y navegación sin ejecutar el script.
  - **Verificación**: ejemplos con funciones, objetos anidados y comentarios que no confundan al parser.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-TOOL-001 | `suggestsPmCryptoSymbols` | Automatizado |
| REQ-TOOL-002 | `formatsNestedBlocksConsistently` | Automatizado |
| REQ-TOOL-003 | `extractsFunctionAndObjectSymbols` | Automatizado |
| REQ-TOOL-004 | `ignoresCommentsInSymbolExtraction` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
