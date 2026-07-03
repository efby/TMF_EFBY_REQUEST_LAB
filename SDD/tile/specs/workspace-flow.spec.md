---
name: Flujos de workspace (BPMN)
description: Validación, interpretación y ejecución de flujos con gateways, paralelismo y presentación de logs.
targets:
  - ambito:paquete-efby / capa:nucleo / area:flujos-workspace
---

## Comenzar desde cero

1. Formaliza el **modelo de grafo** (nodos, aristas, tipos de gateway, datos adjuntos) independiente de la UI.
2. Implementa un **validador** que rechace grafos inconsistentes antes de ejecutar y devuelva mensajes accionables.
3. Implementa un **parser** desde la representación almacenada en el workspace hacia el modelo de ejecución interno.
4. Implementa el **motor de ejecución** con colas o máquina de estados explícita; soporta ramas, paralelismo y temporizadores según el alcance del producto.
5. Conecta la **salida de logs** (texto e imágenes inline) a un modelo de presentación consumible por el editor de diagramas.
6. Añade pruebas por capa: validación, condición de gateway, ejecución completa de un flujo de referencia y formato de líneas de log.

## Ejecución

- Los flujos válidos deben ejecutarse respetando el grafo y las condiciones de gateway definidas para el producto.
  - **Verificación**: prueba de oro con un flujo de referencia y aserciones sobre el orden de nodos visitados y variables resultantes.

## Gateways

- Las condiciones de gateway deben evaluarse de forma determinista dado un mismo contexto de ejecución.
  - **Verificación**: tabla de casos con entradas de contexto y rama esperada.

## Presentación de logs

- Las líneas de log con imágenes inline deben conservar metadatos necesarios para renderizar en la UI sin pérdida de información.
  - **Verificación**: pruebas de serialización o igualdad estructural del modelo de línea de log.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-FLOW-001 | `executesReferenceFlowInOrder` | Automatizado |
| REQ-FLOW-002 | `exclusiveGatewaySelectsExpectedBranch` | Automatizado |
| REQ-FLOW-003 | `inlineImageLogLinePreservesMetadata` | Automatizado |
| REQ-FLOW-004 | `validatorRejectsInconsistentGraph` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
