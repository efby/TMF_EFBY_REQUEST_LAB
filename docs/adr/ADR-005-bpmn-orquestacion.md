# ADR-005: BPMN como orquestación de flujos API

## Estado

Aceptado

## Contexto

Postman Collection Runner ejecuta requests en secuencia lineal. El equipo necesita ramas condicionales, paralelismo y temporizadores para simular flujos de negocio API (ventas, asistencias, etc.) de forma visual.

## Decisión

Integrar un **editor BPMN** embebido (HTML/JS en WebView) con motor de ejecución Swift (`WorkspaceFlowExecutionService`) que:

- Parsea definiciones BPMN del workspace
- Ejecuta tareas como peticiones HTTP del workspace
- Soporta gateways (exclusive, parallel), timers y condiciones
- Emite logs y estado para resaltar nodos en el diagrama

## Consecuencias

### Positivas

- Diferenciador claro vs Postman.
- Flujos reutilizan colecciones y variables existentes.
- Depuración headless vía `FlowDebugRunner` CLI.

### Negativas

- Complejidad alta en parser y ejecutor.
- Subset BPMN (no todos los elementos estándar).
- Editor BPMN añade dependencia WebView.

## Verificación

Spec `workspace-flow.spec.md` + suites `WorkspaceFlow*Tests`.

## Alternativas rechazadas

- **Solo Collection Runner lineal**: insuficiente para casos de negocio del equipo.
- **YAML/JSON de flujos custom**: menos visual, peor adopción.
