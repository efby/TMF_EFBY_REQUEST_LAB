# Runtime de peticiones, scripts y variables

Contrato técnico para implementar el **pipeline de envío** alineado con un laboratorio tipo Postman.

## Orden lógico de una petición HTTP

1. Partir del **modelo de petición** de la pestaña o del flujo.
2. **Resolver plantillas** en URL, cabeceras, query y cuerpo usando variables según el orden de precedencia del producto (típicamente: local → entorno activo → colección → global).
3. Ejecutar scripts con evento **pre-request**: pueden mutar cabeceras, query, cuerpo y tablas de variables expuestas en el contexto de ejecución.
4. Ejecutar la **llamada de red** (HTTP) con la política TLS del producto.
5. Opcional: scripts **post-response** u homólogos si el producto los define.
6. Devolver **respuesta**, representación textual cruda/friendly, **variables actualizadas** y **logs** de consola.

## Contexto de scripts (capas mutables)

El motor de scripts trabaja sobre un contexto que incluye al menos:

- Mapas clave-valor para **global**, **colección**, **entorno** (del perfil activo), **local**.
- Lista de **perfiles de entorno** y el **ID del entorno activo** para permitir cambios de entorno desde script si el producto lo permite.
- Referencias mutables a **cabeceras**, **query** y **cuerpo** de la petición en curso.
- Tras la respuesta: **modelo de respuesta** inyectado en el contexto para scripts que corren después de recibir datos.

## Lenguaje y eventos

- Los scripts se asocian a **definiciones** con tipo de lenguaje y **evento** (pre-request, etc.).
- Soporte típico: **JavaScript** vía motor del sistema (JavaScriptCore en Apple) más líneas de compatibilidad o mini-comandos para colecciones importadas.
- Los scripts no deben tener acceso ilimitado al sistema de archivos ni red arbitraria salvo API explícita del sandbox del producto.

## WebSocket

- El contexto puede incluir el **último mensaje**, causa de cierre o banderas para desconectar, según el diseño del producto.
- La ejecución WebSocket es un **caminos paralelo** al HTTP: mismo concepto de pestaña y logs, distinta máquina de estados de conexión.

## Errores

- Fallos de red, TLS o timeout deben traducirse a un resultado único que la UI pueda mostrar sin colgar el estado **“enviando”**.

## Herramientas de editor

- **Autocompletado**, **formateo** y **listado de símbolos** son utilidades puras sobre texto fuente del script, alineadas con el mismo contrato de APIs globales que el runtime de ejecución.

## API `pm` y criptografía nativa (detalle completo)

Todas las funciones expuestas a scripts (`pm`, `pm.crypto` con RSA de clave pública OAEP-SHA256, AES nativo, `postman`, `CryptoJS`, `btoa`/`atob`, WebSocket, tests, QR, etc.) están catalogadas en **[pm-api-javascript-completa.md](pm-api-javascript-completa.md)**. Los agentes deben usar ese documento al implementar o extender el runtime.
