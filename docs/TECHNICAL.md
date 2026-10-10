# screensets — Technical documentation

How screensets is built, which macOS APIs it uses, why it is designed the way it is, and what we learned about macOS display behavior along the way. For usage, see the [README](../README.md).

Developed and tested on a MacBook Pro (M3 Pro) running macOS 26.6 (Tahoe), built with the system Swift compiler.

---

## 1. Overview

screensets is **a single Swift file** (`screensets.swift`, about 500 lines, no dependencies) compiled into one binary with two modes:

- **CLI** (`list`, `on`, `off`, `toggle`, `set`, `sets`, `init`, `version`): runs the command and exits.
- **Daemon** (`screensets daemon`): a long-running process started by `launchd` that provides:
  - global hotkeys;
  - the menu bar icon and menu;
  - the confirmation countdown;
  - the safety net (automatic rescue).

```
          launchd (LaunchAgent: at login, KeepAlive)
                        │
                        ▼
              screensets daemon ──────────────► ~/Library/Logs/screensets.log
       ┌────────────────┼──────────────────────────┐
       │                │                          │
 Carbon hotkeys    NSStatusItem menu       Display watch
 (modifiers+key)  (displays + sets)       (reconfiguration callback
       │                │                  + 2 s timer)
       └──────┬─────────┘                          │
              ▼                                    ▼
       runAction(): apply                   ensureSomeDisplay():
       the set; if anything                 no usable display left
       was turned off, confirm              → rescue
              │                                    │
              └──────────────┬─────────────────────┘
                             ▼
         configure(): CGBeginDisplayConfiguration
                      + CGSConfigureDisplayEnabled (private)
                      + CGCompleteDisplayConfiguration(.forSession)
                             ▲
                             │
          ~/.config/screensets/sets.json   (re-read on every action)
          ~/.config/screensets/builtin-id  (remembered built-in display ID)
```

### Files

| File | Role |
|---|---|
| `screensets.swift` | All the code |
| `install.sh` / `uninstall.sh` | Build + install + LaunchAgent / removal |
| `examples/sets.example.json` | Example configuration |
| `~/.local/bin/screensets` | Installed binary |
| `~/.config/screensets/sets.json` | Configuration. The directory can be overridden with the `SCREENSETS_CONFIG_DIR` environment variable. |
| `~/.config/screensets/builtin-id` | Built-in display ID (written automatically) |
| `~/Library/LaunchAgents/io.github.rubo88.screensets.plist` | LaunchAgent |
| `~/Library/Logs/screensets.log` | Daemon stdout and stderr |

---

## 2. APIs

| API | Kind | Used for |
|---|---|---|
| `CGSConfigureDisplayEnabled` | **Private** (SkyLight/CoreGraphics) | Turning a display on or off inside a configuration transaction |
| `CGSGetDisplayList` | **Private** | Listing displays **including the ones that are off**. `CGGetOnlineDisplayList` omits them. |
| `CoreDisplay_DisplayCreateInfoDictionary` | **Private** (CoreDisplay.framework) | Getting `IODisplayLocation`, the framebuffer's IORegistry path |
| `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` | Public | Display configuration transactions |
| `CGConfigureDisplayOrigin` | Public | Moving displays to choose the main one |
| `CGGetActiveDisplayList`, `CGDisplayIsBuiltin`, `CGDisplayBounds` | Public | Display state |
| `CGDisplayRegisterReconfigurationCallback` | Public | Notification of every display change |
| `IORegistryEntryFromPath` / `IORegistryEntryCreateCFProperty` | Public (IOKit) | Reading the parsed EDID (`DisplayAttributes`) |
| `RegisterEventHotKey` / `InstallEventHandler` | Public (Carbon) | Global hotkeys **without Accessibility permission** |
| `NSStatusItem`, `NSMenu`, `NSAlert` | Public (AppKit) | Icon, menu and confirmation dialog |
| `ProcessInfo.beginActivity` | Public | Opting out of App Nap |

Private functions are declared with `@_silgen_name`, and the binary links with `-F /System/Library/PrivateFrameworks -framework CoreDisplay`.

**Risk:** a macOS update can change or remove these private functions. SwitchResX and BetterDisplay rely on the same mechanism, so they would break too. After a major update, the first thing to check is that `screensets off builtin` and `screensets on builtin` still work while an external display is on.

---

## 3. Identifying displays

`displays()` returns a list of:

```swift
struct Display {
    let id: CGDirectDisplayID   // CoreGraphics ID (stable while the display stays connected)
    let builtin: Bool
    let name: String            // EDID ProductName
    let serial: String          // EDID AlphanumericSerialNumber
    let connected: Bool         // physically present (even if turned off)
    var active: Bool            // currently in CGGetActiveDisplayList
}
```

How each entry is built:

1. `CGSGetDisplayList` returns every ID. That includes displays that are off, and sometimes stale IDs of displays that no longer exist.
2. For each ID, `CoreDisplay_DisplayCreateInfoDictionary(id)["IODisplayLocation"]` gives a path such as
   `IOService:/AppleARMPE/arm-io@10F00000/AppleH15IO/dispext0@C0000000/IOMobileFramebufferShim`.
3. At that IORegistry node, `DisplayAttributes → ProductAttributes` holds the parsed EDID: `ProductName`, `AlphanumericSerialNumber`, `ManufacturerID`, and so on.
4. **`connected = true`** if that node has `ProductAttributes`, or if the display is the built-in one. Stale IDs show up as `Unknown` / `--` in `screensets list` and are ignored.

**Why the alphanumeric serial?** Two identical monitors have the same name, and `CGDisplaySerialNumber` returns the *numeric* EDID serial, which many monitors leave at 0. The alphanumeric serial string distinguishes them. SwitchResX uses the same data (`edidSerialString`). The CoreDisplay dictionary does not include it, which is why screensets reads the IORegistry.

A display that is **off** still reports its `IODisplayLocation`, so it can be identified and turned back on.

### Selectors

`resolve(selector, in:)` maps a string from `sets.json` to displays, **among connected displays only**:

| Selector | Result |
|---|---|
| `*` / `all` | Every connected display, plus the built-in display even if it is not listed (see §7) |
| `builtin` | The built-in display |
| `external` | Every connected display that is not built-in |
| a number | That CoreGraphics ID |
| `Name` | Case-insensitive match on `name` |
| `Name#SERIAL` | Match on `name` and `serial` |

---

## 4. Turning displays on and off

### `configure(ids, enabled, option = .forSession)`

```swift
CGBeginDisplayConfiguration(&cfg)
for d in ids { CGSConfigureDisplayEnabled(cfg, d, enabled) }
CGCompleteDisplayConfiguration(cfg, option)
```

The option is **`.forSession`**: changes last until logout or restart. This is a deliberate safety measure, because a reboot always brings every display back.

### `apply(on:off:main:)`

The steps always run in this order, so the system never passes through a state with no display:

1. **Turn on** the displays in `on` that are not active.
2. **Check** that turning off the displays in `off` leaves at least one active display. If not, turn nothing off, log `Refused: …` and return `false`.
3. **Turn off** the displays in `off` that are active, and record their IDs in `lastTurnedOff`.
4. **Set the main display**, if the set has `main` and that display is active.

### Main display

In macOS, the main display is the one whose origin is (0, 0). `setMain(id)` shifts every active display by `id`'s current origin, in a single transaction, so the relative arrangement is preserved.

### Out of scope

screensets does not change resolutions, refresh rates, rotation or color profiles, and does not store display arrangements. macOS already remembers resolution and arrangement for each combination of connected displays.

---

## 5. The daemon

### Startup (`runDaemon`)

1. `NSApplication` with `activationPolicy = .accessory`: no Dock icon, but the app can still own an `NSStatusItem` and show alerts.
2. `ProcessInfo.beginActivity([.userInitiatedAllowingIdleSystemSleep, .latencyCritical])` keeps **App Nap** from delaying the timers. A process without visible windows is an App Nap candidate.
3. Build the menu.
4. Register the hotkeys.
5. Register the display reconfiguration callback and a 2-second timer.
6. Run `ensureSomeDisplay()` once, then `app.run()`.

### Hotkeys

- Carbon's **`RegisterEventHotKey`** needs no Accessibility permission. A `CGEventTap` would.
- Keys are mapped with the `keyCodes` table (`kVK_ANSI_*`). These are **physical key positions**, independent of the keyboard layout.
- Modifiers come from `modifiers` in `sets.json` (default `ctrl+alt+cmd`).
- Hotkey signature `'DSPL'` (`0x4453504C`). Each key gets an `id`, stored in `hotkeySetKeys`.
- **Registered at startup, resolved at press time:** keys are registered once, but each press re-reads `sets.json` and looks the set up by its key. Editing what a set does therefore needs no restart; adding keys or changing modifiers does.

Some keyboards, or their vendor utilities, swap ⌘ and ⌃ before macOS sees them. In that case `hidutil property --get UserKeyMapping` is empty and nothing shows in System Settings, but the hotkeys only fire with the "wrong" modifiers. The fix is to set `modifiers` to whatever macOS actually receives.

### `runAction(what, action)`: the single entry point

Every daemon action goes through this function, whether it comes from a hotkey or a menu click:

```
busy? ── yes ──► ignored ("Ignored «…»: a confirmation is pending.")
  │ no
  ▼
lastTurnedOff = []; action(); turnedOff = lastTurnedOff
  │
  ├─ turnedOff empty, or confirmSeconds = 0 ──► done
  │
  ▼  (1 s later, so macOS can rearrange desktops first)
confirmKeep(secs) ── Keep ──► done
        │
        └─ Revert / Esc / timeout ──► configure(turnedOff, true)
```

`turnedOff` comes from what `apply()` **asked** to turn off, not from comparing the display state before and after: `CGCompleteDisplayConfiguration` returns before the change is visible in `CGGetActiveDisplayList` (see §10).

### Confirmation (`confirmKeep`)

- A modal `NSAlert` with **Keep** (Return) and **Revert** (Esc), raised to the `.statusBar` window level so it stays above other windows.
- The countdown is a `Timer` added to the run loop in **`.common`** mode, so it keeps firing inside `runModal()`'s modal loop. At 0 it calls `NSApp.abortModal()`. That result is not "Keep", so the change is reverted.
- For the same reason, every daemon timer goes through `onMain(after:)`, which adds a `Timer` in `.common` mode, rather than `DispatchQueue.main.asyncAfter`. Main-queue blocks do not run while another main-queue block is inside a modal loop.

### Menu

- An `NSStatusItem` with the SF Symbol `display.2`, as a template image so it adapts to light and dark mode.
- Contents: the connected displays (✓ if active, click to toggle), the sets with their hotkey as `keyEquivalent`, then **Edit sets…** and **Show log**.
- **The menu is rebuilt only while it is closed**: at launch, after every reconfiguration and every 2 s, guarded by `isOpen` (`menuWillOpen` / `menuDidClose`). Rebuilding it inside `menuNeedsUpdate` made AppKit on macOS 26 throw `NSGenericException` ("…more Layout Window passes than there are views…"), which killed the process.

### Localization

Interface strings (menu, dialog, CLI messages) go through `L(en, es)`. The language comes from `language` in `sets.json` (`en`, `es`, or `auto` = the first entry of `Locale.preferredLanguages`). Log messages are always in English.

---

## 6. LaunchAgent

`install.sh` writes `~/Library/LaunchAgents/io.github.rubo88.screensets.plist`:

| Key | Value | Why |
|---|---|---|
| `ProgramArguments` | `~/.local/bin/screensets daemon` | |
| `RunAtLoad` | `true` | Start at login |
| `KeepAlive` | `true` | launchd restarts it if it dies. This is why the menu has no Quit item. |
| `LimitLoadToSessionType` | `Aqua` | Only in the graphical session, since it needs the menu bar and WindowServer |
| `ProcessType` | `Interactive` | Interactive scheduling priority |
| `StandardOutPath` / `StandardErrorPath` | `~/Library/Logs/screensets.log` | Log |

---

## 7. Safety net (`ensureSomeDisplay`)

It runs 1.5 s after every display reconfiguration (callback) and also **every 2 s**, in case the callback does not arrive.

### What counts as a "usable" display

```
usable = active (CGGetActiveDisplayList)  AND  connected (has an EDID in the IORegistry)
```

"Active" alone is not enough. When the **only** display that is on gets unplugged, macOS 26 does two things, both observed in the log:

1. **It creates a phantom display** with a new ID (27 and 28 in our tests) and marks it **active**. It arrives as a reconfiguration with flags `0x111e` (added + enabled + main + mode + desktop shape), while the unplugged display arrives with `0x1220` (removed + disabled). The phantom display has no EDID, so `connected = false`.
2. **It drops the built-in display, which is off, from `CGSGetDisplayList`.** The logged state was `active=[27] connected=[] usable=[]`: no display with `builtin = true` was listed at all.

A first version only checked "is anything active?" and missed the problem because of the phantom display. A second version detected it but could not find the built-in display to turn it on.

### Remembered built-in ID

`knownBuiltinID()` writes the built-in display's ID to `~/.config/screensets/builtin-id` whenever it sees it. When the built-in display is not listed, it uses the saved value, or `1` if there is no file, which is the built-in display's ID on Apple Silicon. `CGSConfigureDisplayEnabled` accepts that ID even though the display is not listed.

### Rescue: three methods, cycled

While no display is usable, each check (every 2 s) tries one method, rotating through:

| Attempt | Method |
|---|---|
| 0 | `configure([built-in], true)` with `.forSession` |
| 1 | The same with `.permanently` |
| 2 | Turn on every candidate ID that is not active: the built-in display, 1–8, and everything listed |

Each attempt is logged as `RESCUE #n (method m, …) -> ok|ERROR`. In testing (built-in display off, only external monitor unplugged), **method 0 brought the built-in display back in under a second**:

```
Reconfiguration: display 28 flags=0x111e
Reconfiguration: display 3 flags=0x1220
State (timer): active=[28] connected=[] usable=[]
RESCUE #1 (method 0, built-in=1, candidates=[1, 2, …, 8]) -> ok
Reconfiguration: display 28 flags=0x1220
Reconfiguration: display 1 flags=0x111e
State (reconfig): active=[1] connected=[1] usable=[1]
```

Methods 1 and 2 are fallbacks that have not been needed so far.

### All safety layers

1. `apply()` never turns off the last active display.
2. Confirmation countdown when the daemon turns a display off.
3. Automatic rescue (this section).
4. The `*` selector (emergency set), which includes the built-in display even when it is not listed.
5. `.forSession`: a restart resets everything.
6. `KeepAlive`: launchd restarts the daemon if it dies.

---

## 8. Log

Every line starts with an ISO 8601 UTC timestamp.

| Message | Meaning |
|---|---|
| `screensets X starting` / `Hotkeys registered (mods): [...]` | Daemon started |
| `Could not register key X` | Another app owns that hotkey |
| `Set «…»: on=[…] off=[…] main=…` | Set applied, with the displays it resolved to |
| `Refused: turning off […] would leave no display on.` | Safety layer 1 |
| `Confirmation: keep/revert after N s` | Dialog result |
| `«…» not confirmed: turning […] back on.` | Change reverted |
| `Ignored «…»: a confirmation is pending.` | Action dropped while a dialog was open |
| `Reconfiguration: display N flags=0x…` | macOS notification (`CGDisplayChangeSummaryFlags`) |
| `State (…): active=… connected=… usable=…` | Logged only when the state changes |
| `RESCUE #n (method m, …) -> ok/ERROR` | Rescue in progress |
| `Error in …sets.json: …` | Malformed JSON |

Useful flags: `0x10` added, `0x20` removed, `0x100` enabled, `0x200` disabled, `0x4` new main display, `0x1000` desktop shape changed.

---

## 9. Building and installing

`install.sh` performs these steps:

1. Check for macOS and `swiftc`.
2. Use the source next to the script, or download the `main` tarball when piped from `curl`.
3. Build into a temporary directory and check that the binary runs.
4. `bootout` the running instance.
5. **`rm` the old binary, then `cp`** the new one to `~/.local/bin`.
6. Run `screensets init`, which never overwrites an existing config.
7. Write the plist and `bootstrap` it.
8. Check that the daemon is running.

The manual equivalent:

```bash
swiftc -O screensets.swift -o screensets -F /System/Library/PrivateFrameworks -framework CoreDisplay
rm -f ~/.local/bin/screensets && cp screensets ~/.local/bin/screensets
launchctl kickstart -k gui/$(id -u)/io.github.rubo88.screensets
```

> **Why `rm` before `cp`:** overwriting the binary in place (same inode) leaves macOS with a cached copy of the previous ad hoc code signature, and the new binary is killed at launch (`last exit reason = OS_REASON_CODESIGNING`, `job state = spawn failed`). Removing the file first creates a new inode with its own signature.

---

## 10. Lessons learned

| Symptom | Cause | Fix |
|---|---|---|
| Daemon died when opening the menu | Rebuilding the `NSMenu` in `menuNeedsUpdate` → AppKit `NSGenericException` on macOS 26 | Rebuild only while closed (§5) |
| Confirmation dialog never appeared | Turned-off displays were computed as before − after with `CGGetActiveDisplayList` right after the change, which macOS had not applied yet | Use the list that was requested (`lastTurnedOff`) |
| Daemon would not start after reinstalling | Cached code signature after overwriting the binary | `rm` before `cp` (§9) |
| Unplugging the only monitor with the built-in display off left no display | Phantom "active" display + built-in display missing from the list | "Active **and** connected" rule, remembered ID, cycling rescue (§7) |
| Hotkeys only fired with the "wrong" modifiers | Keyboard swapping ⌘/⌃ before macOS | Configurable `modifiers` |

## 11. Migrating from SwitchResX

SwitchResX stores display sets in `~/Library/Preferences/fr.madrau.switchresx.daemon.plist`:

- `displaySetsArray[]`: each set has `name`, `keyCode` and `monitorArray[]`.
- In `monitorArray`, only entries with `hasActivity = true` turn displays on or off (`isActive`). `isMainDisplay` marks the main display.
- `monitorResID` points into `allDisplays[id]`, which holds `sysMonitorName` and `edidSerialString`. These map directly to screensets' `Name#SERIAL` selectors.
- `keyCode = (virtualKeyCode << 8) | (NSEvent modifier flags >> 16)`. For example, `0x151C` is key 21 (`4`) with `0x1C`, which is ⌃ (0x4) + ⌥ (0x8) + ⌘ (0x10).

Quick dump:

```bash
plutil -p ~/Library/Preferences/fr.madrau.switchresx.daemon.plist | grep -E '"name"|keyCode|monitorResID|isActive|hasActivity'
```

## 12. Known limitations

- Depends on private APIs (§2).
- `main` is only applied if the display is already reported as active at that moment. For a display turned on by the same set, this depends on how fast macOS applies the change. It worked in testing.
- The CLI has no confirmation countdown. It still refuses to turn off the last display.
- While a confirmation dialog is open, other actions are ignored.
- Tested on Apple Silicon with macOS 26 only.
