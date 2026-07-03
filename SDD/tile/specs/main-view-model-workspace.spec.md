---
name: Coordinador principal — workspace y pestañas
description: Orquestación de entornos, duplicación de flujos y coherencia entre pestañas y el workspace.
targets:
  - ambito:paquete-efby / capa:nucleo / area:coordinacion-ui-workspace
---

## Comenzar desde cero

1. Dibuja el **estado observable** mínimo: workspace activo, lista de pestañas, pestaña seleccionada, mensajes de error/información.
2. Reglas explícitas: qué ocurre al **nueva petición**, **duplicar**, **cerrar pestaña**, **cambiar entorno activo**.
3. Implementa la sincronización workspace ↔ pestaña con **puntos únicos de commit** (por ejemplo, al enviar con éxito o al guardar explícito).
4. Para **flujos**, define cómo se reflejan variables mutadas durante la ejecución en el workspace y en las pestañas abiertas.
5. Cubre con pruebas de integración ligera el coordinador usando servicios dobles donde la red o Git no sean necesarios.

## Entornos y flujos

- Los cambios de variables de entorno durante la ejecución de un flujo deben propagarse al estado publicado sin romper la coherencia entre pestañas y workspace.
  - **Verificación**: escenario de prueba con flujo simulado y aserciones sobre variables visibles en la pestaña y en el workspace.

## Clonación de flujos

- Duplicar nodos o flujos debe conservar las relaciones necesarias para seguir ejecutando el workspace.
  - **Verificación**: prueba que clone un subgrafo y ejecute el mismo escenario antes y después de la duplicación con resultados equivalentes.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-VM-001 | `flowExecutionUpdatesEnvironmentVariables` | Automatizado |
| REQ-VM-002 | `tabStateReflectsWorkspaceEnvironment` | Automatizado |
| REQ-VM-003 | `clonedFlowExecutesEquivalentScenario` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
