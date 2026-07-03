# Especificaciones de desarrollo

Normas técnicas para mantener calidad, consistencia y evolución segura del código.

Los **contratos de producto** (SPM, modelo de datos, persistencia, pipelines de red y flujos) viven en `docs/reference/` del tile; úsalos al definir APIs nuevas o al revisar PRs grandes.

## Lenguaje y plataforma

- **Swift** en la versión indicada por el manifiesto del paquete en la raíz del repo (`swift-tools-version`).
- **macOS** como plataforma objetivo; respeta la versión mínima declarada en el manifiesto.
- Usa APIs modernas de Swift y el modelo de **concurrencia estricta** cuando el compilador lo exija (`Sendable`, actores o aislamiento al hilo principal en UI).

## Arquitectura

- **Dominio**: modelos sin efectos secundarios; tipos claros para peticiones, respuestas, workspace y flujos.
- **Aplicación**: servicios con dependencias inyectables; evita singletons ocultos salvo que ya sea patrón establecido del repo.
- **Presentación**: el coordinador de pantalla publica estado observable para SwiftUI; operaciones largas en `async`/`Task` con cancelación explícita donde ya exista el patrón.

## Estilo y legibilidad

- Nombres descriptivos en **inglés** para símbolos públicos y código nuevo, salvo que el archivo ya use otra convención dominante: en ese caso, **sigue al archivo**.
- Evita comentarios que repiten el código; comenta **invariantes**, **trucos de plataforma** y **decisiones de diseño** no obvias.
- Mantén funciones acotadas; si un tipo crece sin control, propón extracción en mensaje al revisor antes de mega-refactors.

## Errores y mensajes

- Propaga errores como tipos **representables** (enum o struct) que la UI pueda traducir a texto para el usuario.
- No abras diálogos desde capas profundas del núcleo: sube el error al coordinador o al flujo de presentación acordado.

## Rendimiento y red

- No bloquees el hilo principal con E/S de red o disco.
- Para listas grandes en UI, reutiliza identificadores estables y evita recalcular agregados en cada render si el patrón del proyecto ya optimiza eso.

## Pruebas

- Añade o actualiza pruebas en el target de tests del paquete para **cambios de comportamiento** en el núcleo.
- Las pruebas deben ser **deterministas**; usa dobles o datos locales en lugar de servicios externos no controlados.

## Internacionalización

- Cadenas visibles al usuario: si el producto aún no tiene tabla de strings, al menos centraliza literales nuevos donde el equipo ya lo haga; no disperses texto mágico por vistas sin criterio.

## Revisiones

- Todo cambio que toque **seguridad, persistencia o formato de archivo** debe revisarse con la guía de **seguridad y cifrado** del mismo directorio `rules/`.
