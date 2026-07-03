# Módulo de la aplicación con interfaz gráfica

Ejecutable que arranca **EFBY Request Lab** como app de escritorio.

El comportamiento del coordinador, pestañas y ciclo de vida de la app está especificado en [ui-estado-y-navegacion.md](../reference/ui-estado-y-navegacion.md).

## Comenzar desde cero

1. En el manifiesto del paquete, localiza el **target ejecutable** que declara la app (depende del núcleo).
2. Identifica el **punto de entrada** del ejecutable: tipo marcado como arranque de la aplicación y escena principal.
3. La **ventana principal** debe inyectar el coordinador de pantalla del núcleo y enlazarlo a la vista raíz.
4. Los **menús** y atajos (nueva petición, duplicar, enviar) deben llamar métodos del coordinador, no servicios de red directamente.
5. El **delegado de aplicación** debe coordinar el cierre: pedir al view model que vuelque estado antes de que el proceso termine.
6. Los **recursos embebidos** (editor BPMN, soporte del editor de código) se declaran en el manifiesto como recursos copiados del target; tras añadir archivos, limpia y recompila.
7. Prueba siempre en ventana real: cambio de tamaño mínimo, cierre con peticiones en curso y reconexión WebSocket.

## Punto de entrada

- Declaración de la app del sistema con escena principal y enlace al delegado de ciclo de vida.
- Registro del coordinador de pantalla como estado observable de la escena.

## Vistas principales

- **Vista raíz**: contenedor de navegación y paneles enlazados al coordinador.
- **Editor de flujos**: edición y visualización BPMN; estado de ejecución reflejado desde el coordinador.
- **Editores de petición y scripts**: pestañas de cuerpo, cabeceras, consola y panel de scripts con autocompletado.

## Recursos

- Activos del **diagrama BPMN** embebido en el bundle del target.
- Activos del **editor de código** (resaltado, temas o grammars según el producto).

La interfaz depende exclusivamente del **target de biblioteca de núcleo** para reglas de negocio y red.
