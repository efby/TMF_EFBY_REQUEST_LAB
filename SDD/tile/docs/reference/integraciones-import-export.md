# Integraciones: Postman, OpenAPI y Git

Contratos externos que el núcleo debe respetar al **importar o exportar** y al sincronizar con **Git**.

## Colecciones Postman

- Soportar al menos esquemas **v2.0** y **v2.1** de colección JSON (URLs de esquema Postman como referencia de validación opcional).
- Importación: mapear carpetas, peticiones, variables de colección, scripts y metadatos al árbol interno; registrar el **formato de origen** (nativo vs Postman) para trazabilidad.
- Exportación: generar JSON compatible para reabrir en Postman u otra herramienta, preservando campos críticos definidos en la spec de interoperabilidad.

## Entornos Postman

- Importar/exportar variables por perfil, flags de habilitación y nombre de entorno.
- Mantener coherencia con el **entorno activo** del workspace al resolver peticiones.

## OpenAPI

- Aceptar descripciones **3.0** y **3.1** cuando el producto lo implemente.
- Importación típica: generar colección o peticiones a partir de paths y componentes; documentar qué extensiones no se soportan.

## Git

- Operaciones expuestas al usuario (clonar, pull, etc.) deben devolver **errores estructurados** para credenciales, conflicto o red.
- No persistir tokens en claro en el workspace si existe alternativa (URL sin credencial + prompt, SSH, llavero del sistema).

## Orden recomendado de implementación desde cero

1. Modelo interno de colección + **codec** Postman round-trip con pruebas.
2. Codec de **entornos**.
3. **OpenAPI** como capa opcional que alimenta el mismo árbol de colección.
4. **Git** detrás de fachada testeable, integrada al coordinador de UI.
