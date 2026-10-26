# screensets

**Enciende y apaga las pantallas del Mac con un atajo de teclado, sin quedarte nunca a oscuras.**

[English](README.md) · [Documentación técnica](docs/es/TECNICA.md)

screensets es una pequeña app para la barra de menús de macOS (un solo fichero Swift, sin dependencias) que cambia entre *sets* de pantallas: «solo el portátil», «solo la externa», «portátil + externa», etc. Una pantalla apagada desaparece de verdad: las ventanas, el Dock y la barra de menús pasan a las que quedan encendidas.

Está construida alrededor de una prioridad por encima de todo: **que nunca te quedes sin una pantalla que funcione**. Eso incluye la trampa clásica de tener la pantalla del portátil apagada y desenchufar el monitor externo.

## Características

- **Sets de pantallas con atajos globales**: ⌃⌥⌘ + tecla por defecto, configurable.
- **Icono en la barra de menús**: muestra cada pantalla con una marca ✓ (un clic la enciende o la apaga) y lista tus sets.
- **Ventana para editar los sets**: crea, edita, reordena y prueba sets con el ratón. Por detrás sigue habiendo un JSON sencillo, para quien lo prefiera.
- **Identifica los monitores por el número de serie del EDID**, así que dos monitores iguales se controlan por separado.
- **Pantalla principal por set** (la de la barra de menús), opcional.
- **Interruptor de Control Universal** en el menú: apaga o enciende el enlace que permite pasar el ratón por un borde de la pantalla a otro Mac o iPad.
- **Redes de seguridad**:
  - nunca apaga la última pantalla encendida;
  - una cuenta atrás de «¿Mantener esta configuración?» deshace el cambio si no respondes;
  - si no queda ninguna pantalla utilizable, vuelve a encender la del portátil automáticamente (por ejemplo, al desenchufar el único monitor);
  - un atajo de emergencia lo enciende todo;
  - los cambios solo duran la sesión actual, así que al reiniciar vuelven todas.
- **No necesita permiso de Accesibilidad.**
- Interfaz en español o en inglés.

## Requisitos

- macOS en Apple Silicon. Desarrollado y probado en macOS 26 (Tahoe). Puede funcionar en versiones anteriores y en Macs Intel, pero no está probado.
- Las Command Line Tools de Apple, para compilarla: `xcode-select --install`.

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/rubo88/screensets/main/install.sh | bash
```

O desde una copia del repositorio:

```bash
git clone https://github.com/rubo88/screensets.git
cd screensets
./install.sh
```

El instalador:

1. compila la app;
2. la instala en `~/.local/bin/screensets`;
3. crea una configuración inicial en `~/.config/screensets/sets.json` (nunca sobrescribe una que ya exista);
4. registra un LaunchAgent para que arranque al iniciar sesión y se reinicie si alguna vez falla.

Vuelve a ejecutarlo cuando quieras para actualizar.

> Si otra app ya usa los mismos atajos, ciérrala o cambia sus atajos para evitar conflictos.

## Uso

### Atajos

La configuración inicial incluye:

| Atajo | Set |
|---|---|
| ⌃⌥⌘ 1 | Solo el portátil (apaga todas las externas) |
| ⌃⌥⌘ 2 | Solo las externas (apaga el portátil) |
| ⌃⌥⌘ 0 | Todas encendidas (**emergencia**) |

### Barra de menús

Pulsa el icono de dos pantallas:

- **Pantallas**: las conectadas, con ✓ en las encendidas. Un clic en una la enciende o la apaga.
- **Sets**: tus sets con su atajo. Un clic en uno lo aplica.
- **Control Universal (ratón al otro Mac)**: ✓ mientras macOS deja pasar el ratón y el teclado a un Mac o iPad cercano. Un clic apaga ese enlace o lo vuelve a encender. Es el mismo interruptor que *Ajustes del Sistema › Pantallas › Avanzado*, se aplica en menos de un segundo y se queda como lo dejes, también al reiniciar.
- **Editar sets…** (la ventana del editor), **Abrir sets.json** y **Ver registro**.

Si no ves el icono, puede que lo esté escondiendo un gestor de la barra de menús como Bartender.

### La cuenta atrás de confirmación

Cada vez que un atajo o un clic **apaga una pantalla**, aparece:

> **¿Mantener esta configuración de pantallas?** Si no respondes, se deshará en 15 s.

- **Intro**: mantiene el cambio.
- **Esc**: lo deshace.
- **No hacer nada**: se deshace solo. Esto cubre el caso de que la pantalla que queda encendida no se vea, por ejemplo porque el monitor está apagado o con otra entrada.

Encender pantallas nunca pide confirmación.

## Configuración

### Con el ratón: el editor de sets

Elige **Editar sets…** en el icono de la barra de menús.

- **A la izquierda**: tus sets. Con **+** / **−** añades o borras un set, y con **↑** / **↓** los reordenas.
- **A la derecha**: el set seleccionado:
  - su **nombre** y su **atajo**;
  - una fila por pantalla con tres opciones, **No tocar** / **Encender** / **Apagar**. Las filas son la pantalla del Mac, todas las externas, todas las pantallas, las que mencionan tus sets (marcadas como *no conectada* si no están) y cualquier otra que esté conectada;
  - la **pantalla principal**, opcional;
  - **Probar este set ahora**, que lo aplica al momento, con la confirmación de siempre.
- **Arriba**: las teclas modificadoras comunes a todos los atajos, la cuenta atrás de confirmación y el idioma.
- **Guardar** escribe `sets.json` y aplica los atajos nuevos al momento. **Cancelar** descarta los cambios.

El editor no deja guardar sets sin nombre, nombres repetidos, atajos repetidos ni atajos sin ⌃, ⌥ o ⌘ (capturarían lo que escribes).

### A mano: sets.json

Todo está en `~/.config/screensets/sets.json` (**Abrir sets.json** en el menú):

```json
{
  "modifiers": "ctrl+alt+cmd",
  "confirmSeconds": 15,
  "language": "auto",
  "sets": [
    { "key": "1", "name": "Solo portátil",       "on": ["builtin"], "off": ["external"] },
    { "key": "2", "name": "Escritorio",          "on": ["DELL U2720Q"], "off": ["builtin"] },
    { "key": "3", "name": "Portátil + monitor",  "on": ["builtin", "DELL U2720Q"], "main": "DELL U2720Q" },
    { "key": "0", "name": "Todas encendidas",    "on": ["*"] }
  ]
}
```

| Campo | Significado |
|---|---|
| `modifiers` | Modificadores de **todos** los atajos: combinaciones de `ctrl`, `alt`/`opt`, `cmd` y `shift`, unidas con `+`. |
| `confirmSeconds` | Duración de la cuenta atrás. `0` la desactiva (no recomendado). |
| `language` | `auto` (sigue a macOS), `en` o `es`. |
| `key` | Tecla del atajo: `0`–`9`, `a`–`z`, `-` o `=`. Opcional: un set sin tecla solo se usa desde el menú. Son posiciones físicas de tecla, así que funcionan igual con cualquier distribución de teclado. |
| `name` | Nombre en el menú. |
| `on` / `off` | Pantallas que se encienden o se apagan. Las que no aparecen en ninguna lista no se tocan, y las que no están conectadas se ignoran. |
| `main` | Opcional: la pantalla que pasa a ser la principal. |

### Cómo nombrar las pantallas

| Selector | Qué pantallas |
|---|---|
| `builtin` | La pantalla del portátil |
| `external` | Todas las externas conectadas |
| `*` | Todas, incluida la del portátil aunque macOS haya dejado de listarla |
| `DELL U2720Q` | Las que tengan ese nombre |
| `DELL U2720Q#ABC123` | Ese monitor concreto (nombre + número de serie del EDID). Úsalo si tienes dos monitores iguales. |
| `3` | Un ID de CoreGraphics. No es estable entre reconexiones; mejor evitarlo. |

Para ver el selector de cada pantalla conectada, ejecuta `screensets list`:

```
1	ON 	builtin
3	ON 	DELL U2720Q#ABC123
4	off	DELL U2720Q#XYZ789
```

Los cambios se detectan solos en un par de segundos, atajos incluidos. No hace falta reiniciar nada.

En [examples/sets.example.json](examples/sets.example.json) hay un ejemplo más completo, con dos monitores iguales.

## Línea de comandos

| Comando | Efecto |
|---|---|
| `screensets list` | Pantallas, su estado y su selector |
| `screensets sets` | Sets configurados |
| `screensets set 1` / `screensets set "Solo portátil"` | Aplica un set, por tecla o por nombre |
| `screensets on builtin` / `off external` / `toggle builtin` | Enciende o apaga pantallas directamente |
| `screensets init [--force]` | Crea la configuración inicial |
| `screensets version` | Muestra la versión |

Desde la línea de comandos no hay cuenta atrás. Sí se mantiene la protección de no apagar la última pantalla.

## Si algo falla

| Problema | Qué hacer |
|---|---|
| No se ve ninguna pantalla | Espera un par de segundos al rescate automático. Si no vuelve, pulsa el atajo de emergencia (⌃⌥⌘ 0 por defecto) o vuelve a enchufar el monitor externo. Cerrar sesión o reiniciar restaura siempre todas las pantallas. |
| Los atajos no hacen nada | Mira `~/Library/Logs/screensets.log`. Debe aparecer `Hotkeys registered`. `Could not register key X` significa que otra app tiene ese atajo. `Error in …sets.json` significa que el JSON está mal formado. |
| Un set no hace nada | Si el registro dice `Set «…»: on=[] off=[]`, ninguna de sus pantallas coincide. Compara los selectores con `screensets list`. |
| Los modificadores no cuadran | Algunos teclados (o sus utilidades) intercambian ⌘ y ⌃. Pon en `modifiers` lo que macOS recibe de verdad. |

## Desinstalar

```bash
./uninstall.sh            # conserva tus sets
./uninstall.sh --purge    # borra también ~/.config/screensets y el registro
```

## Cómo funciona

screensets enciende y apaga pantallas con `CGSConfigureDisplayEnabled`, una API **privada** de CoreGraphics. Lee el nombre y el número de serie de cada monitor del IORegistry, y registra los atajos con `RegisterEventHotKey` de Carbon, por eso no necesita permiso de Accesibilidad.

Lo más delicado es el rescate. Cuando se desenchufa la única pantalla encendida, macOS crea una pantalla fantasma «activa» y deja de listar la del portátil apagada. Por eso screensets solo cuenta las pantallas activas **y** conectadas físicamente, y recuerda el ID de la pantalla del portátil para poder encenderla.

Más detalles en [docs/es/TECNICA.md](docs/es/TECNICA.md).

**Aviso:** al depender de APIs privadas, una actualización de macOS podría romperla. Tras una actualización importante, comprueba que `screensets off builtin` y `screensets on builtin` siguen funcionando con una pantalla externa encendida.

## Licencia

[MIT](LICENSE)
