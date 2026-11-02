---
name: Ejecución de peticiones HTTP
description: Resolución de variables, scripts previos y envío con resultado trazable.
targets:
  - ambito:paquete-efby / capa:nucleo / area:ejecucion-http
---

## Comenzar desde cero

1. Define en papel el orden: variables → scripts de pre-request → construcción de URL y cuerpo → envío → respuesta y logs.
2. Implementa el resolutor de variables como componente puro y testeable sin red.
3. Implementa el motor de scripts con un contexto explícito (variables mutables, APIs permitidas, límites de tiempo).
4. Encapsula la sesión de red y las políticas TLS en un único servicio de ejecución que reciba modelos de dominio y devuelva resultado enriquecido (respuesta, texto crudo, variables actualizadas, logs).
5. Conecta el coordinador de UI para que una sola pestaña tenga un ciclo de vida claro: inicio de envío, cancelación, fin con éxito o error.
6. Escribe pruebas que cubran: sustitución correcta, mutación por script, error de red y transición del estado “enviando”.

## Comportamiento

- Las peticiones deben ejecutarse aplicando variables de entorno, colección y global según las reglas de precedencia acordadas antes de contactar la red.
  - **Verificación**: casos de prueba automatizados que ejerciten el servicio de ejecución con datos de entrada fijos y aserciones sobre URL final, cabeceras y cuerpo.
- Los scripts de pre-request deben poder mutar cabeceras, query, cuerpo y variables del runtime sin persistir cambios hasta que el flujo de la aplicación lo confirme.
  - **Verificación**: pruebas que simulen script con mutaciones y comprueben el modelo en memoria frente al persistido.

## Errores y límites

- Fallos de red o TLS deben traducirse en un resultado de ejecución coherente y no dejar el estado de la pestaña incoherente (por ejemplo, bandera de “enviando” sin tarea asociada).
  - **Verificación**: pruebas con respuestas simuladas de error y comprobación del estado publicado al terminar.
- Una tarea cancelada antes del envío no inicia tráfico. La instalación de la tarea nativa y su cancelación se sincronizan para que no se pierda una cancelación temprana.
- Una cancelación durante red, espera de reintento o scripts no devuelve éxito ni publica cambios de variables. Los callbacks tardíos completan la espera una sola vez.
- Regresiones en `RequestCancellationTests` (precancelación, espera de respuesta, reintentos y registro tardío), `ScriptRequestInterruptionTests` (scripts y plantillas sin tráfico ni resultados parciales) y `FlowCancellationIntegrationTests` (cancelación de flujos antes de iniciar y después de respuestas tardías).

## Reutilización de transporte

- Un servicio reutiliza sesiones por validación TLS y versión mínima: como máximo ocho combinaciones. La configuración base, incluida la inyección de protocolos para pruebas, se conserva.
- Cada tarea tiene su propio diagnóstico; una petición no reutiliza mensajes TLS de otra. Cancelar una petición sólo cancela su tarea nativa.
- El cierre explícito `invalidate()` es permanente y cierra las sesiones del pool; liberar el servicio también las invalida, sin cerrar la sesión base inyectada.
- `HTTPTransportReuseTests` verifica concurrencia, políticas separadas, cancelación de una petición sin cortar otra y liberación de recursos. La preparación WebSocket no crea sesiones; cada conexión mantiene su ciclo de vida independiente.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-HTTP-001 | `resolvesVariablesBeforeNetworkCall` | Automatizado |
| REQ-HTTP-002 | `preRequestScriptMutatesHeadersInMemory` | Automatizado |
| REQ-HTTP-003 | `networkErrorReturnsStructuredResult` | Automatizado |
| REQ-HTTP-004 | `sendingFlagClearedAfterCompletion` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
