<div align="center">
    <img src="Ice/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="160" height="160" alt="Icono de Hielo: el Illimani">
    <h1>Hielo</h1>
    <p>Gestor de la barra de menús para macOS 27, en español e inglés.</p>
</div>

**Hielo** oculta y muestra los elementos de la barra de menús del Mac. Es un *fork* de
[Ice](https://github.com/jordanbaird/Ice), de Jordan Baird, adaptado para que funcione en
**macOS 27** y con algunas funciones propias.

*Hielo is a fork of [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird, adapted to
macOS 27, localized to Spanish and English, with a few features of its own.*

## Qué aporta Hielo sobre Ice

- Soporte completo para **macOS 27**: los iconos se capturan de la ventana interna de
  MenuBarAgent (con color y transparencia), los elementos del sistema aparecen en su sección,
  y *mostrar al pasar el puntero* y *mostrar al desplazar* funcionan.
- Tres secciones: **Visibles**, **Ocultos** y **Siempre ocultos**, sin iconos duplicados al
  arrastrar entre ellas.
- **Reloj propio** con fecha (y hora opcional), del mismo tamaño que los demás elementos.
- **Barra de Hielo** con fondo configurable: como la barra de menús, translúcido o
  transparente, con control de opacidad.
- Interfaz en **español** e **inglés**; icono del **Illimani**.
- Sin actualizaciones automáticas del Ice original (reemplazarían a Hielo).

## Compilar e instalar

Requiere Xcode 27 o posterior y un certificado de firma local llamado `Ice Local Signing`
en el llavero (un certificado autofirmado de *firma de código*; con él los permisos de
Accesibilidad y Grabación de pantalla sobreviven a cada recompilación).

```bash
bash build_install.sh
```

El script compila la app, la firma, la instala en `/Applications/Hielo.app` y la abre.
La primera vez, macOS pedirá los permisos de **Accesibilidad** y **Grabación de pantalla**.

## Créditos y licencia

- **Hielo** — © 2026 Mauricio Chumacero.
- **Ice** — © Jordan Baird, <https://github.com/jordanbaird/Ice>. Hielo parte de la rama
  `macos-27-support` de la comunidad de Ice (carlossantos74, PR #1001).

Hielo se distribuye, igual que Ice, bajo la **GNU General Public License v3** (ver
[LICENSE](LICENSE)). Los archivos modificados respecto a Ice se identifican en el historial
de git de este repositorio.
