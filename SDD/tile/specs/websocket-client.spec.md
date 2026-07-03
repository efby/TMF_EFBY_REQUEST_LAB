---
name: Cliente WebSocket
description: Conexión, transcript y ciclo de vida de tareas asociadas a pestañas WebSocket.
targets:
  - ambito:paquete-efby / capa:nucleo / area:websocket
---

## Comenzar desde cero

1. Modela el estado de una pestaña WebSocket: desconectado, conectando, conectado, error; más contadores opcionales (pings, última actividad).
2. Implementa un servicio que abra la conexión, escriba en transcript y propague errores de forma controlada.
3. Asegura **tareas cancelables** para recepción, ping y keep-alive; al cerrar la pestaña, cancela todo y limpia referencias.
4. Integra con el coordinador de pantalla para que la UI solo observe propiedades publicadas en el hilo principal.
5. Cubre con pruebas: conexión exitosa, mensaje entrante, cierre limpio y cancelación al destruir el estado de pestaña.

## Comportamiento

- El servicio debe completar el handshake, recibir mensajes y actualizar el estado de conexión de forma predecible para la interfaz.
  - **Verificación**: pruebas con dobles de red o URLs de eco controladas según la estrategia del proyecto.

## Ciclo de vida

- Al cerrar pestañas o destruir el estado asociado, no deben quedar handlers ni tareas en segundo plano activas.
  - **Verificación**: pruebas que fuercen deinit o cierre y comprueben ausencia de fugas mediante expectativas sobre cancelación o contadores de tareas.

## Trazabilidad

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-WS-001 | `receivesIncomingMessageUpdatesTranscript` | Automatizado |
| REQ-WS-002 | `connectionStateTransitionsCorrectly` | Automatizado |
| REQ-WS-003 | `closingTabCancelsBackgroundTasks` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
