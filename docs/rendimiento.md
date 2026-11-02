# Rendimiento — entrega 3

## Cambios verificados

- Autoguardado con pausa de 250 ms y espera máxima de 2 s durante edición continua. Cada destino conserva un último estado pendiente y un escritor serial, en lugar de una cadena de tareas por tecla.
- Enviar, abrir, cambiar de workspace, guardar explícitamente y cerrar drenan los cambios pendientes. Un fallo conserva la edición y permite reintentar; el cierre de la app se cancela si no se pudo guardar.
- El estado local más reciente y los valores autorizados para compartir se conservan por separado. Agrupar un guardado de E1 con una edición local E2 no publica E2 ni adelanta su baseline compartido.
- Archivos idénticos evitan escrituras atómicas. Directorios idénticos evitan staging, copias y movimientos. Se leen y validan los archivos actuales: una modificación externa de Git o un JSON corrupto no queda oculto por una caché.
- HTTP reutiliza sesiones por combinación de validación TLS y versión mínima, con un máximo de ocho por servicio. Los diagnósticos son propios de cada petición; cancelarla no invalida la sesión de sus hermanas. `invalidate()` y la liberación del servicio cierran las sesiones.
- Preparar WebSocket sólo genera datos y logs; no crea una sesión descartable. Cada conexión mantiene su propia sesión y su cierre independiente.

## Medición antes y después

Microbenchmarks locales en Debug, Swift 6.3.3, Mac arm64. Se capturó el baseline antes de modificar las implementaciones y se repitieron los mismos tres casos después, en procesos nuevos y con las mismas restricciones de ejecución.

El dataset de persistencia contiene 50 colecciones, 10 peticiones por colección y un body de 1.024 caracteres por petición. Los contadores corresponden a llamadas de escritura reales del repositorio de prueba y bytes de JSON enviados a `.write(.atomic)`; no son contadores de bloques físicos del sistema operativo.

| Carga | Antes | Después |
|---|---:|---:|
| 50 ediciones rápidas + flush: escrituras locales | 102 | 1 |
| Volumen de JSON escrito en esa ráfaga | 174.475.060 bytes | 1.710.540 bytes |
| Tiempo de encolar las 50 ediciones | 0,1256 s | 0,0625 s |
| Tiempo de la ráfaga hasta terminar el flush | 2,8372 s | 0,0841 s |
| 20 guardados idénticos: copias de directorio | 20 | 0 |
| 20 guardados idénticos: movimientos de directorio | 40 | 0 |
| Tiempo de esos 20 guardados | 3,6500 s | 0,5278 s |
| 20 HTTP secuenciales con la misma política: sesiones | 20 | 1 |
| Tiempo del mock HTTP local | 0,1614 s | 0,1013 s |

La ráfaga reduce un 99,02 % las escrituras y el volumen de JSON local. Los tiempos son muestras individuales, no una comparación estadística: pueden variar por cachés y carga del equipo. El mock HTTP no mide DNS, TCP, TLS ni latencia de un servidor real; el ahorro de sesiones sí se verifica con una fábrica contadora y peticiones simultáneas. Una primera observación del mock optimizado dio 0,2187 s, por lo que no se afirma una mejora garantizada de latencia HTTP.

### Caso con directorio compartido

Con el mismo dataset y 50 ediciones, el caso adicional produjo 2 escrituras locales (3.426.700 bytes), 1 copia y 2 movimientos del directorio de colecciones; el último estado quedó tanto en disco local como en el compartido. La última suite midió 0,2347 s.

Las dos escrituras locales son deliberadas: primero se guarda una versión recuperable con el baseline anterior; después del éxito compartido se confirma el baseline. Una prueba fuerza un fallo entre ambas fases, inicia otro ViewModel y verifica recuperación del borrador, reintento y segundo reinicio limpio.

## Repetir las comprobaciones

```bash
swift test --filter PerformanceMeasurementTests
swift test --filter 'AutosaveTests|AutosaveQueueTests|AutosavePersistenceTests'
swift test --filter RepositoryWriteEfficiencyTests
swift test --filter HTTPTransportReuseTests
swift test
```

Las mediciones imprimen líneas `EFBY_PERF`. Los tests comprueban el último valor, límites de escrituras y operaciones, serialización, flush simultáneo, reintento, modificaciones externas y aislamiento TLS. Los tiempos se imprimen para observación; no se usan umbrales frágiles de velocidad como condición de éxito.

## Validación final

La suite completa ejecutó 273 pruebas con acceso normal a los servicios de macOS: 271 aprobadas, 2 omitidas por requerir credenciales externas y ningún fallo. Las credenciales de integración AWS/Bitbucket se desactivaron explícitamente para esta ejecución.

En el entorno restringido, la prueba de 20 peticiones HTTP paralelas agotaba su plazo y el caso QR fallaba. Con el mismo binario, la prueba de concurrencia pasó tres veces fuera de esas restricciones y la ejecución completa también pasó, incluido QR. No se modificó el generador QR para conseguir ese resultado.

No se midieron memoria residente, tiempo de arranque de la interfaz ni conexiones TCP reales. Los cambios de directorio siguen usando la recuperación por conjunto de la entrega 1; cuando hay cambios, todavía se copia el árbol a staging para conservar esa protección.
