# Historial de versiones

## 1.0.5 — 2026-11-02

### Correcciones

- Recupera el workspace seleccionado entre sesiones y versiones, incluso cuando la referencia guardada a su carpeta dejó de resolverse. Conserva los datos y comprueba los permisos reales de acceso.
- Aísla peticiones, conexiones WebSocket y flujos entre workspaces; descarta resultados tardíos y respeta la cancelación.
- Permite interrumpir scripts bloqueados y sus peticiones pendientes.
- Protege la integridad de los archivos compartidos, las operaciones Git y la importación y exportación de colecciones.

### Rendimiento y mantenimiento

- Agrupa el autoguardado, evita escrituras idénticas y reutiliza sesiones HTTP compatibles.
- Separa MainViewModel y RootView en archivos por responsabilidad.
- Añade pruebas de interfaz para navegación, pestañas, workspaces, reapertura, envío y cancelación.
- Integra las pruebas de interfaz en CI y conserva reportes, capturas y resultados de Xcode ante fallos.

### Validación

- Núcleo: 298 pruebas, 296 aprobadas y 2 omitidas por requerir credenciales externas.
- Interfaz macOS: 8 pruebas aprobadas.
- Exportador de reportes: 14 pruebas aprobadas, con verificación de capturas y reportes de un fallo controlado.
