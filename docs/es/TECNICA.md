# screensets — Documentación técnica

Cómo está construido screensets, qué APIs de macOS usa, por qué está diseñado así y qué hemos aprendido sobre el comportamiento de las pantallas en macOS. Para el uso, ver el [README](../../README.es.md).

Desarrollado y probado en un MacBook Pro (M3 Pro) con macOS 26.6 (Tahoe), compilado con el Swift del sistema.

---

## 1. Visión general

screensets es **un único fichero Swift** (`screensets.swift`, unas 500 líneas, sin dependencias) que se compila en un binario con dos modos:

- **CLI** (`list`, `on`, `off`, `toggle`, `set`, `sets`, `init`, `version`): ejecuta la orden y termina.
- **Daemon** (`screensets daemon`): proceso permanente, lanzado por `launchd`, que ofrece:
  - los atajos globales;
  - el icono y el menú de la barra de menús;
  - la cuenta atrás de confirmación;
  - la red de seguridad (rescate automático).

```
          launchd (LaunchAgent: al iniciar sesión, KeepAlive)
                        │
                        ▼
              screensets daemon ──────────────► ~/Library/Logs/screensets.log
       ┌────────────────┼──────────────────────────┐
       │                │                          │
 Atajos Carbon     Menú NSStatusItem      Vigilancia de pantallas
 (modif.+tecla)   (pantallas + sets)      (callback de reconfiguración
       │                │                  + temporizador de 2 s)
       └──────┬─────────┘                          │
              ▼                                    ▼
       runAction(): aplica                  ensureSomeDisplay():
       el set; si ha apagado                no queda ninguna pantalla
       algo, pide confirmación              utilizable → rescate
              │                                    │
              └──────────────┬─────────────────────┘
                             ▼
         configure(): CGBeginDisplayConfiguration
                      + CGSConfigureDisplayEnabled (privada)
                      + CGCompleteDisplayConfiguration(.forSession)
                             ▲
                             │
          ~/.config/screensets/sets.json   (se relee en cada acción)
          ~/.config/screensets/builtin-id  (ID recordado de la interna)
```

### Ficheros

| Fichero | Papel |
|---|---|
| `screensets.swift` | Todo el código |
| `install.sh` / `uninstall.sh` | Compilación + instalación + LaunchAgent / desinstalación |
| `examples/sets.example.json` | Configuración de ejemplo |
| `~/.local/bin/screensets` | Binario instalado |
| `~/.config/screensets/sets.json` | Configuración. El directorio se puede cambiar con la variable de entorno `SCREENSETS_CONFIG_DIR`. |
| `~/.config/screensets/builtin-id` | ID de la pantalla interna (se escribe solo) |
| `~/Library/LaunchAgents/io.github.rubo88.screensets.plist` | LaunchAgent |
| `~/Library/Logs/screensets.log` | stdout y stderr del daemon |

---

## 2. APIs

| API | Tipo | Para qué |
|---|---|---|
| `CGSConfigureDisplayEnabled` | **Privada** (SkyLight/CoreGraphics) | Encender o apagar una pantalla dentro de una transacción de configuración |
| `CGSGetDisplayList` | **Privada** | Listar las pantallas **también las apagadas**. `CGGetOnlineDisplayList` no las incluye. |
| `CoreDisplay_DisplayCreateInfoDictionary` | **Privada** (CoreDisplay.framework) | Obtener `IODisplayLocation`, la ruta del framebuffer en el IORegistry |
| `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` | Pública | Transacciones de configuración |
| `CGConfigureDisplayOrigin` | Pública | Mover pantallas para elegir la principal |
| `CGGetActiveDisplayList`, `CGDisplayIsBuiltin`, `CGDisplayBounds` | Pública | Estado de las pantallas |
| `CGDisplayRegisterReconfigurationCallback` | Pública | Aviso de cada cambio de pantallas |
| `IORegistryEntryFromPath` / `IORegistryEntryCreateCFProperty` | Pública (IOKit) | Leer el EDID ya interpretado (`DisplayAttributes`) |
| `RegisterEventHotKey` / `InstallEventHandler` | Pública (Carbon) | Atajos globales **sin permiso de Accesibilidad** |
| `NSStatusItem`, `NSMenu`, `NSAlert` | Pública (AppKit) | Icono, menú y confirmación |
| `ProcessInfo.beginActivity` | Pública | Evitar App Nap |

Las funciones privadas se declaran con `@_silgen_name` y se enlaza con `-F /System/Library/PrivateFrameworks -framework CoreDisplay`.

**Riesgo:** una actualización de macOS puede cambiar o eliminar estas funciones privadas. SwitchResX y BetterDisplay usan el mismo mecanismo, así que también se romperían. Tras una actualización importante, lo primero es comprobar que `screensets off builtin` y `screensets on builtin` siguen funcionando con una pantalla externa encendida.

---

## 3. Identificación de pantallas

`displays()` devuelve una lista de:

```swift
struct Display {
    let id: CGDirectDisplayID   // ID de CoreGraphics (estable mientras sigue conectada)
    let builtin: Bool
    let name: String            // ProductName del EDID
    let serial: String          // AlphanumericSerialNumber del EDID
    let connected: Bool         // físicamente presente (aunque esté apagada)
    var active: Bool            // en CGGetActiveDisplayList ahora mismo
}
```

Cómo se construye cada entrada:

1. `CGSGetDisplayList` da todos los IDs. Incluye los de las pantallas apagadas y, a veces, IDs huérfanos de pantallas que ya no existen.
2. Para cada ID, `CoreDisplay_DisplayCreateInfoDictionary(id)["IODisplayLocation"]` da una ruta como
   `IOService:/AppleARMPE/arm-io@10F00000/AppleH15IO/dispext0@C0000000/IOMobileFramebufferShim`.
3. En ese nodo del IORegistry, `DisplayAttributes → ProductAttributes` contiene el EDID interpretado: `ProductName`, `AlphanumericSerialNumber`, `ManufacturerID`, etc.
4. **`connected = true`** si el nodo tiene `ProductAttributes`, o si es la interna. Los IDs huérfanos aparecen como `Unknown` / `--` en `screensets list` y se ignoran.

**¿Por qué el serial alfanumérico?** Dos monitores iguales tienen el mismo nombre, y `CGDisplaySerialNumber` devuelve el serial *numérico* del EDID, que muchos monitores dejan a 0. El serial alfanumérico sí los distingue. SwitchResX usa el mismo dato (`edidSerialString`). El diccionario de CoreDisplay no lo incluye, por eso screensets lo lee del IORegistry.

Una pantalla **apagada** sigue devolviendo su `IODisplayLocation`, así que se puede identificar y volver a encender.

### Selectores

`resolve(selector, in:)` traduce un texto de `sets.json` en pantallas, **solo entre las conectadas**:

| Selector | Resultado |
|---|---|
| `*` / `all` | Todas las conectadas, más la interna aunque no esté listada (ver §7) |
| `builtin` | La interna |
| `external` | Todas las conectadas que no son la interna |
| número | Ese ID de CoreGraphics |
| `Nombre` | Coincidencia de `name`, sin distinguir mayúsculas |
| `Nombre#SERIE` | Coincidencia de `name` y `serial` |

---

## 4. Encender y apagar

### `configure(ids, enabled, option = .forSession)`

```swift
CGBeginDisplayConfiguration(&cfg)
for d in ids { CGSConfigureDisplayEnabled(cfg, d, enabled) }
CGCompleteDisplayConfiguration(cfg, option)
```

Se usa **`.forSession`**: los cambios duran hasta cerrar sesión o reiniciar. Es una medida de seguridad deliberada: al reiniciar vuelven siempre todas las pantallas.

### `apply(on:off:main:)`

Siempre en este orden, para no pasar nunca por un estado sin pantallas:

1. **Encender** las de `on` que no estén activas.
2. **Comprobar** que apagar las de `off` deja al menos una pantalla activa. Si no, no apaga ninguna, anota `Refused: …` y devuelve `false`.
3. **Apagar** las de `off` que estén activas y guardar sus IDs en `lastTurnedOff`.
4. **Elegir la principal**, si el set tiene `main` y esa pantalla está activa.

### Pantalla principal

En macOS, la pantalla principal es la que tiene el origen en (0, 0). `setMain(id)` desplaza todas las pantallas activas restándoles el origen actual de `id`, en una sola transacción, así que se conserva la disposición relativa.

### Fuera de alcance

No cambia resoluciones, frecuencias, rotación ni perfiles de color, ni guarda disposiciones. macOS ya recuerda la resolución y la disposición de cada combinación de pantallas.

---

## 5. El daemon

### Arranque (`runDaemon`)

1. `NSApplication` con `activationPolicy = .accessory`: sin icono en el Dock, pero puede tener `NSStatusItem` y mostrar alertas.
2. `ProcessInfo.beginActivity([.userInitiatedAllowingIdleSystemSleep, .latencyCritical])` para que **App Nap** no retrase los temporizadores. Un proceso sin ventanas visibles es candidato a App Nap.
3. Crea el menú.
4. Registra los atajos.
5. Registra el callback de reconfiguración y un temporizador de 2 s.
6. Ejecuta `ensureSomeDisplay()` una vez y entra en `app.run()`.

### Atajos

- Se usa **`RegisterEventHotKey`** de Carbon, que no necesita permiso de Accesibilidad. Un `CGEventTap` sí lo necesitaría.
- Las teclas se traducen con la tabla `keyCodes` (`kVK_ANSI_*`). Son **posiciones físicas**, independientes de la distribución del teclado.
- Los modificadores salen de `modifiers` en `sets.json` (por defecto `ctrl+alt+cmd`).
- Firma de los atajos: `'DSPL'` (`0x4453504C`). Cada tecla tiene un `id` que se guarda en `hotkeySetKeys`.
- **Se registran al arrancar y se resuelven al pulsar:** las teclas se registran una vez, pero cada pulsación vuelve a leer `sets.json` y busca el set por su tecla. Por eso cambiar lo que hace un set no requiere reiniciar, pero añadir teclas o cambiar los modificadores sí.

Algunos teclados, o sus utilidades del fabricante, intercambian ⌘ y ⌃ antes de que llegue a macOS. En ese caso `hidutil property --get UserKeyMapping` está vacío y no aparece nada en Ajustes del Sistema, pero los atajos solo responden con los modificadores «equivocados». La solución es poner en `modifiers` lo que macOS recibe de verdad.

### `runAction(what, action)`: punto único de entrada

Todas las acciones del daemon pasan por aquí, tanto los atajos como los clics en el menú:

```
busy? ── sí ──► se ignora ("Ignored «…»: a confirmation is pending.")
  │ no
  ▼
lastTurnedOff = []; action(); turnedOff = lastTurnedOff
  │
  ├─ turnedOff vacío o confirmSeconds = 0 ──► fin
  │
  ▼  (1 s después, para que macOS recoloque escritorios)
confirmKeep(secs) ── Mantener ──► fin
        │
        └─ Deshacer / Esc / tiempo agotado ──► configure(turnedOff, true)
```

`turnedOff` sale de lo que `apply()` **ha pedido** apagar, no de comparar el estado de antes y de después: `CGCompleteDisplayConfiguration` vuelve antes de que el cambio se vea en `CGGetActiveDisplayList` (ver §10).

### Confirmación (`confirmKeep`)

- `NSAlert` modal con **Mantener** (Intro) y **Deshacer** (Esc), en el nivel `.statusBar`, para que quede por encima de las demás ventanas.
- La cuenta atrás es un `Timer` en modo **`.common`**, así que sigue funcionando dentro del bucle modal de `runModal()`. Al llegar a 0 llama a `NSApp.abortModal()`, que no es «Mantener», así que se deshace el cambio.
- Por el mismo motivo, todos los temporizadores del daemon pasan por `onMain(after:)`, que añade un `Timer` en `.common`, en lugar de `DispatchQueue.main.asyncAfter`. Los bloques de la cola principal no se ejecutan mientras otro bloque de esa cola está en un bucle modal.

### Menú

- `NSStatusItem` con el símbolo SF `display.2`, en modo plantilla para adaptarse al modo claro u oscuro.
- Contenido: las pantallas conectadas (✓ si están activas; un clic las enciende o apaga), los sets con su atajo como `keyEquivalent`, y **Editar sets…** y **Ver registro**.
- **El menú se reconstruye solo cuando está cerrado**: al arrancar, tras cada reconfiguración y cada 2 s, con la guarda `isOpen` (`menuWillOpen` / `menuDidClose`). Reconstruirlo en `menuNeedsUpdate` hacía que AppKit en macOS 26 lanzara `NSGenericException` («…more Layout Window passes than there are views…») y el proceso moría.

### Idioma

Los textos de la interfaz (menú, ventana y mensajes de la CLI) pasan por `L(en, es)`. El idioma sale de `language` en `sets.json` (`en`, `es`, o `auto` = el primer idioma de `Locale.preferredLanguages`). El registro siempre está en inglés.

---

## 6. LaunchAgent

`install.sh` escribe `~/Library/LaunchAgents/io.github.rubo88.screensets.plist`:

| Clave | Valor | Motivo |
|---|---|---|
| `ProgramArguments` | `~/.local/bin/screensets daemon` | |
| `RunAtLoad` | `true` | Arranca al iniciar sesión |
| `KeepAlive` | `true` | launchd lo relanza si muere. Por eso el menú no tiene «Salir». |
| `LimitLoadToSessionType` | `Aqua` | Solo en la sesión gráfica, porque necesita la barra de menús y WindowServer |
| `ProcessType` | `Interactive` | Prioridad de proceso interactivo |
| `StandardOutPath` / `StandardErrorPath` | `~/Library/Logs/screensets.log` | Registro |

---

## 7. Red de seguridad (`ensureSomeDisplay`)

Se ejecuta 1,5 s después de cada reconfiguración (callback) y además **cada 2 s**, por si el callback no llega.

### Qué cuenta como pantalla «utilizable»

```
utilizable = activa (CGGetActiveDisplayList)  Y  conectada (tiene EDID en el IORegistry)
```

No basta con «activa». Al desenchufar la **única** pantalla encendida, macOS 26 hace dos cosas, observadas en el registro:

1. **Crea una pantalla fantasma** con un ID nuevo (27 y 28 en nuestras pruebas) y la marca como **activa**. Llega como reconfiguración con flags `0x111e` (añadida + activada + principal + modo + forma del escritorio), mientras la desenchufada llega con `0x1220` (eliminada + desactivada). La fantasma no tiene EDID, así que `connected = false`.
2. **Quita de `CGSGetDisplayList` la interna, que estaba apagada.** El estado registrado fue `active=[27] connected=[] usable=[]`: no había ninguna pantalla con `builtin = true` en la lista.

Una primera versión solo comprobaba «¿hay alguna activa?» y no detectaba el problema por culpa de la fantasma. Una segunda lo detectaba, pero no encontraba la interna para encenderla.

### ID recordado de la interna

`knownBuiltinID()` guarda el ID de la interna en `~/.config/screensets/builtin-id` cada vez que la ve. Cuando la interna no aparece en la lista, usa el valor guardado, o `1` si no hay fichero, que es el ID de la interna en Apple Silicon. `CGSConfigureDisplayEnabled` acepta ese ID aunque la pantalla no esté listada.

### Rescate: tres métodos en bucle

Mientras no haya ninguna pantalla utilizable, en cada comprobación (cada 2 s) se prueba un método, rotando entre:

| Intento | Método |
|---|---|
| 0 | `configure([interna], true)` con `.forSession` |
| 1 | Lo mismo con `.permanently` |
| 2 | Encender todos los IDs candidatos no activos: la interna, del 1 al 8 y todos los listados |

Cada intento queda en el registro como `RESCUE #n (method m, …) -> ok|ERROR`. En las pruebas (interna apagada y el único monitor externo desenchufado), **el método 0 encendió la interna en menos de un segundo**:

```
Reconfiguration: display 28 flags=0x111e
Reconfiguration: display 3 flags=0x1220
State (timer): active=[28] connected=[] usable=[]
RESCUE #1 (method 0, built-in=1, candidates=[1, 2, …, 8]) -> ok
Reconfiguration: display 28 flags=0x1220
Reconfiguration: display 1 flags=0x111e
State (reconfig): active=[1] connected=[1] usable=[1]
```

Los métodos 1 y 2 son reservas que no han hecho falta hasta ahora.

### Todas las capas de seguridad

1. `apply()` nunca apaga la última pantalla activa.
2. Cuenta atrás de confirmación cuando el daemon apaga una pantalla.
3. Rescate automático (esta sección).
4. El selector `*` (set de emergencia), que incluye la interna aunque no esté listada.
5. `.forSession`: un reinicio lo restablece todo.
6. `KeepAlive`: launchd relanza el daemon si muere.

---

## 8. Registro

Cada línea empieza con una marca de tiempo ISO 8601 en UTC. Los mensajes están en inglés.

| Mensaje | Significado |
|---|---|
| `screensets X starting` / `Hotkeys registered (mods): [...]` | Daemon arrancado |
| `Could not register key X` | Otra app tiene ese atajo |
| `Set «…»: on=[…] off=[…] main=…` | Set aplicado, con las pantallas resueltas |
| `Refused: turning off […] would leave no display on.` | Capa de seguridad 1 |
| `Confirmation: keep/revert after N s` | Resultado de la ventana |
| `«…» not confirmed: turning […] back on.` | Cambio deshecho |
| `Ignored «…»: a confirmation is pending.` | Acción descartada porque había una ventana abierta |
| `Reconfiguration: display N flags=0x…` | Aviso de macOS (`CGDisplayChangeSummaryFlags`) |
| `State (…): active=… connected=… usable=…` | Solo cuando cambia |
| `RESCUE #n (method m, …) -> ok/ERROR` | Rescate en curso |
| `Error in …sets.json: …` | JSON mal formado |

Flags útiles: `0x10` añadida, `0x20` eliminada, `0x100` activada, `0x200` desactivada, `0x4` nueva principal, `0x1000` cambio de forma del escritorio.

---

## 9. Compilar e instalar

`install.sh` sigue estos pasos:

1. Comprueba que está en macOS y que existe `swiftc`.
2. Usa el código que está junto al script, o descarga el tarball de `main` si se ejecuta con `curl`.
3. Compila en un directorio temporal y comprueba que el binario arranca.
4. Hace `bootout` de la instancia en marcha.
5. **Hace `rm` del binario anterior y después `cp`** del nuevo a `~/.local/bin`.
6. Ejecuta `screensets init`, que nunca sobrescribe una configuración existente.
7. Escribe el plist y hace `bootstrap`.
8. Comprueba que el daemon está en marcha.

El equivalente manual:

```bash
swiftc -O screensets.swift -o screensets -F /System/Library/PrivateFrameworks -framework CoreDisplay
rm -f ~/.local/bin/screensets && cp screensets ~/.local/bin/screensets
launchctl kickstart -k gui/$(id -u)/io.github.rubo88.screensets
```

> **Por qué `rm` antes de `cp`:** si se sobrescribe el binario en el mismo sitio (mismo inodo), macOS conserva en caché la firma ad hoc anterior y mata el nuevo binario al arrancar (`last exit reason = OS_REASON_CODESIGNING`, `job state = spawn failed`). Borrarlo antes crea un inodo nuevo con su propia firma.

---

## 10. Lecciones aprendidas

| Síntoma | Causa | Solución |
|---|---|---|
| El daemon moría al abrir el menú | Reconstruir el `NSMenu` en `menuNeedsUpdate` → `NSGenericException` de AppKit en macOS 26 | Reconstruir solo con el menú cerrado (§5) |
| No aparecía la confirmación | Las pantallas apagadas se calculaban como antes − después con `CGGetActiveDisplayList` justo tras el cambio, y macOS aún no lo había aplicado | Usar la lista de lo que se pidió apagar (`lastTurnedOff`) |
| El daemon no arrancaba tras reinstalar | Caché de firma de código al sobrescribir el binario | `rm` antes de `cp` (§9) |
| Al desenchufar el único monitor con la interna apagada, ninguna pantalla | Pantalla fantasma «activa» + interna fuera de la lista | Regla «activa **y** conectada», ID recordado y rescate en bucle (§7) |
| Los atajos solo respondían con los modificadores «equivocados» | Teclado que intercambia ⌘/⌃ antes de macOS | `modifiers` configurable |

## 11. Migrar desde SwitchResX

SwitchResX guarda los «display sets» en `~/Library/Preferences/fr.madrau.switchresx.daemon.plist`:

- `displaySetsArray[]`: cada set tiene `name`, `keyCode` y `monitorArray[]`.
- En `monitorArray`, solo las entradas con `hasActivity = true` encienden o apagan pantallas (`isActive`). `isMainDisplay` marca la principal.
- `monitorResID` apunta a `allDisplays[id]`, donde están `sysMonitorName` y `edidSerialString`. Se corresponden directamente con los selectores `Nombre#SERIE` de screensets.
- `keyCode = (códigoVirtualDeTecla << 8) | (modificadores NSEvent >> 16)`. Por ejemplo, `0x151C` es la tecla 21 (`4`) con `0x1C`, que es ⌃ (0x4) + ⌥ (0x8) + ⌘ (0x10).

Volcado rápido:

```bash
plutil -p ~/Library/Preferences/fr.madrau.switchresx.daemon.plist | grep -E '"name"|keyCode|monitorResID|isActive|hasActivity'
```

## 12. Limitaciones conocidas

- Depende de APIs privadas (§2).
- `main` solo se aplica si la pantalla ya figura como activa en ese momento. Para una pantalla que enciende el mismo set, depende de lo rápido que macOS aplique el cambio. En las pruebas funcionó.
- La CLI no tiene cuenta atrás de confirmación. Sí se mantiene la protección de no apagar la última pantalla.
- Mientras hay una ventana de confirmación abierta, las demás acciones se ignoran.
- Solo probado en Apple Silicon con macOS 26.
