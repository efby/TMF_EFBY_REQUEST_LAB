---
name: Resolución de variables
description: Sustitución y precedencia de variables globales, de colección, de entorno y locales.
targets:
  - ambito:paquete-efby / capa:nucleo / area:variables
---

## Comenzar desde cero

1. Documenta el **orden de precedencia** entre capas (por ejemplo: local > entorno > colección > global) y los delimitadores de plantilla aceptados.
2. Implementa el resolutor como componente **sin efectos de red**: solo lectura de tablas de variables y texto de entrada.
3. Define el comportamiento para **valor ausente** (cadena vacía, marcador de error, excepción controlada) y aplícalo de forma uniforme.
4. Si permites **referencias encadenadas**, implementa detección de ciclos y límite de profundidad.
5. Añade pruebas de tabla: cada fila es un conjunto de variables + plantilla + resultado esperado.

## Sustitución

- Las plantillas deben resolverse según las reglas de capas y el entorno activo del workspace.
  - **Verificación**: matriz de casos automatizados con nombres legibles por escenario.

## Casos borde

- Valores ausentes o ciclos no deben tumbar el proceso ni exponer fallos no controlados en la API pública del resolutor.
  - **Verificación**: casos que fuerzen ausencia y auto-referencia; la salida debe ser la acordada (error modelado o marcador).

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-VAR-001 | `environmentOverridesCollection` | Automatizado |
| REQ-VAR-002 | `resolvesTemplateSyntax` | Automatizado |
| REQ-VAR-003 | `missingVariableReturnsEmptyOrMarker` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
