# Desarrollo asistido por agentes (Cursor, Codex y similares)

Este documento define **cómo deben trabajar los agentes** sobre el repositorio EFBY Request Lab para que el resultado sea coherente con el producto y con el SDD.

## Antes de escribir código

1. Abre la regla [checklist-implementacion-desde-cero.md](checklist-implementacion-desde-cero.md) y sitúa la tarea en la **fase** correcta.
2. Lee el documento de **referencia técnica** enlazado desde esa fase (carpeta `docs/reference/` del tile). Para scripts: **[pm-api-javascript-completa.md](../docs/reference/pm-api-javascript-completa.md)** (`pm.crypto`, `encryptRsa`, `postman`, etc.).
3. Cruza con la spec en `SDD/tile/specs/` si existe para ese ámbito (p. ej. `javascript-pm-runtime.spec.md` para el runtime `pm`).

## Principios

1. **Spec primero**: antes de implementar un cambio grande, lee la spec correspondiente en `SDD/tile/specs/` y alinea el comportamiento con los requisitos y la sección «Comenzar desde cero».
2. **Núcleo vs interfaz**: la lógica de negocio y red vive en la biblioteca de núcleo; la app solo orquesta y presenta. No dupliques reglas de negocio en la capa de UI.
3. **Cambios mínimos**: un diff pequeño que resuelve el ticket es preferible a refactors masivos no solicitados.
4. **Pruebas**: tras tocar el núcleo, ejecuta `swift test` desde la raíz del repo y corrige regresiones antes de dar por cerrada la tarea.

## Cursor

- Activa el servidor MCP de Tessl si el proyecto lo trae configurado (archivo de MCP del editor en la raíz del repo). Así el agente puede consultar documentación y contexto del tile sin inventar APIs.
- Usa el árbol **SDD** como fuente de verdad: `tile/docs/` (arquitectura y módulos), `tile/rules/` (reglas y seguridad), `specs/` (requisitos por área).
- Para ediciones largas en Swift, prefiere compilar incrementalmente (`swift build`) y atiende a los avisos de concurrencia del compilador.

## Codex (CLI u otros modos Codex)

- Pasa el **objetivo** en una sola frase y referencia explícita al ámbito: por ejemplo «ajustar resolución de variables según spec en SDD/tile/specs».
- Limita el alcance a directorios razonables si la herramienta lo permite (núcleo vs ejecutable de UI) para reducir ruido.
- Exige en el prompt: «respeta las reglas en SDD/tile/rules y no cambies archivos fuera del alcance».

## Flujo de trabajo recomendado

1. Entender el bug o feature leyendo **funcionalidades requeridas** y la spec del área.
2. Proponer en comentario o mensaje el **plan** en 3–5 pasos antes de tocar código.
3. Implementar con **commits lógicos** (si usas git): un tema por commit cuando sea posible.
4. Verificar con **build + tests** y, si aplica, prueba manual de la pantalla afectada.

## Qué no debe hacer un agente

- Introducir dependencias nuevas sin acuerdo explícito del equipo (evalúa licencia, tamaño y mantenimiento).
- Desactivar validaciones TLS o políticas de seguridad «para probar» sin dejarlo acotado a builds de depuración y documentado.
- Escribir secretos, tokens o contraseñas reales en el código o en fixtures versionadas.

## Comunicación con humanos

- Resume al final: **qué** cambió, **por qué**, y **cómo verificar** (comandos o pasos en la app).
- Si descubres ambigüedad en una spec, deja constancia en el mensaje y sugiere una frase concreta para añadir a la spec en lugar de asumir.
