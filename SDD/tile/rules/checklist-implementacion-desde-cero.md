# Checklist: implementar el laboratorio desde cero

Usa esta lista como **orden sugerido** y como verificación de completitud. Cada ítem enlaza a la documentación técnica del tile.

## Fase 0 — Fundamentos

- [ ] Revisar [contrato-paquete-spm.md](../docs/reference/contrato-paquete-spm.md) y fijar `swift-tools-version`, plataforma y productos SPM.
- [ ] Aplicar [especificaciones-desarrollo.md](especificaciones-desarrollo.md) y [seguridad-encriptacion.md](seguridad-encriptacion.md) desde el primer commit.

## Fase 1 — Dominio y persistencia

- [ ] Modelar el agregado del workspace según [modelo-datos-y-persistencia.md](../docs/reference/modelo-datos-y-persistencia.md).
- [ ] Implementar carga/guardado JSON con **versión de esquema** y migraciones; pruebas con fixtures por versión.
- [ ] Cumplir la spec de persistencia en `SDD/tile/specs/` (incluida al publicar el tile).

## Fase 2 — Peticiones y variables

- [ ] Implementar resolución de variables y precedencia (spec en `SDD/tile/specs/`).
- [ ] Implementar pipeline HTTP según [runtime-peticiones-scripts.md](../docs/reference/runtime-peticiones-scripts.md) y spec de ejecución HTTP.
- [ ] Motor de scripts y contexto de runtime alineados con el mismo documento y con [pm-api-javascript-completa.md](../docs/reference/pm-api-javascript-completa.md) (incluye `pm.crypto` y alias `encryptRsa`).
- [ ] Spec de runtime `pm` y criptografía (`javascript-pm-runtime.spec.md` en `SDD/tile/specs/`) satisfecha en pruebas cuando se toque el bootstrap o los puentes criptográficos.

## Fase 3 — WebSocket

- [ ] Servicio de conexión, transcript y cancelación (spec WebSocket en `SDD/tile/specs/`).

## Fase 4 — Interoperabilidad

- [ ] Codecs Postman y OpenAPI según [integraciones-import-export.md](../docs/reference/integraciones-import-export.md) y specs de interoperabilidad.
- [ ] Git con errores estructurados (spec Git en `SDD/tile/specs/`).

## Fase 5 — Flujos

- [ ] Modelo de nodos y motor según [flujos-workspace-bpmn.md](../docs/reference/flujos-workspace-bpmn.md) y spec de flujos.
- [ ] Integración con el coordinador para variables de entorno durante flujos (spec del view model en `SDD/tile/specs/`).

## Fase 6 — Interfaz

- [ ] Coordinador y pestañas según [ui-estado-y-navegacion.md](../docs/reference/ui-estado-y-navegacion.md).
- [ ] Editores embebidos y recursos del bundle de la app (contrato SPM).

## Fase 7 — Calidad y agentes

- [ ] Cobertura mínima descrita en [testing.md](../docs/reference/testing.md).
- [ ] Para trabajo con IA, seguir [agents-cursor-codex.md](agents-cursor-codex.md) y la tabla de funcionalidades en [funcionalidades-requeridas.md](funcionalidades-requeridas.md).
