# screensets

**Turn your Mac's displays on and off with a hotkey — and never get stuck with a black screen.**

[Español](README.es.md) · [Technical documentation](docs/TECHNICAL.md)

screensets is a tiny macOS menu bar app (one Swift file, no dependencies) that switches between *sets* of displays: "laptop only", "external only", "laptop + external", and so on. A display that is turned off really disappears: windows, the Dock and the menu bar move to the displays that stay on.

It is built around one priority above everything else: **you must never end up without a working display.** That includes the classic trap where the built-in display is off and you unplug the external monitor.

## Features

- **Display sets with global hotkeys**: ⌃⌥⌘ + key by default, configurable.
- **Menu bar icon** that shows each display with a checkmark (click to toggle) and lists your sets.
- **Set editor window**: create, edit, reorder and test sets with the mouse. A plain JSON file stays underneath for those who prefer it.
- **Identifies monitors by EDID serial number**, so two identical monitors can be controlled separately.
- **Optional main display per set** (the one with the menu bar).
- **Safety nets**:
  - it never turns off the last display that is on;
  - a "Keep this configuration?" countdown reverts the change if you don't answer;
  - it automatically turns the built-in display back on if no usable display is left, for example after unplugging the only monitor;
  - an emergency hotkey turns every display on;
  - changes only last for the current session, so a restart brings everything back.
- **No Accessibility permission needed.**
- English or Spanish interface.

## Requirements

- macOS on Apple Silicon. Developed and tested on macOS 26 (Tahoe). Older versions and Intel Macs may work but are untested.
- Apple's Command Line Tools, to compile the app: `xcode-select --install`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/rubo88/screensets/main/install.sh | bash
```

Or from a clone:

```bash
git clone https://github.com/rubo88/screensets.git
cd screensets
./install.sh
```

The installer:

1. compiles the app;
2. installs it to `~/.local/bin/screensets`;
3. creates a starter configuration in `~/.config/screensets/sets.json` (an existing one is never overwritten);
4. registers a LaunchAgent so screensets starts at login and is restarted if it ever crashes.

Run it again at any time to update.

> If another app already uses the same hotkeys, quit it or change its hotkeys to avoid conflicts.

## Using it

### Hotkeys

The starter configuration includes:

| Hotkey | Set |
|---|---|
| ⌃⌥⌘ 1 | Built-in display only (all external displays off) |
| ⌃⌥⌘ 2 | External displays only (built-in display off) |
| ⌃⌥⌘ 0 | All displays on (**emergency**) |

### Menu bar

Click the two-displays icon to see:

- **Displays**: every connected display, with a ✓ on the ones that are on. Click one to toggle it.
- **Sets**: your sets with their hotkeys. Click one to apply it.
- **Edit sets…** (the editor window), **Open sets.json** and **Show log**.

If you can't see the icon, a menu bar manager such as Bartender may be hiding it.

### The confirmation countdown

Whenever a hotkey or a menu click **turns a display off**, a dialog asks:

> **Keep this display configuration?** Reverting in 15 s if you don't answer.

- Press **Return** to keep the change.
- Press **Esc** to revert it.
- If you do nothing, it reverts on its own. This covers the case where the display that stays on is actually dark, for example because the monitor is off or on another input.

Turning displays on never asks for confirmation.

## Configuration

### With the mouse: the set editor

Choose **Edit sets…** in the menu bar icon.

- **Left**: your sets. Use **+** / **−** to add or delete a set and **↑** / **↓** to reorder.
- **Right**: the selected set:
  - its **name** and **hotkey**;
  - one row per display with three options, **Leave** / **On** / **Off**. The rows are the built-in display, all external displays, all displays, the displays your sets mention (shown as *not connected* when they are absent) and any other connected display;
  - the optional **main display**;
  - **Try this set now**, which applies it straight away, with the usual confirmation.
- **Top**: the modifier keys shared by all hotkeys, the confirmation countdown and the interface language.
- **Save** writes `sets.json` and applies the new hotkeys immediately. **Cancel** discards your changes.

The editor refuses to save sets without a name, duplicated names, duplicated hotkeys, or hotkeys without ⌃, ⌥ or ⌘ (those would capture normal typing).

### By hand: sets.json

Everything lives in `~/.config/screensets/sets.json` (**Open sets.json** in the menu):

```json
{
  "modifiers": "ctrl+alt+cmd",
  "confirmSeconds": 15,
  "language": "auto",
  "sets": [
    { "key": "1", "name": "Laptop only",      "on": ["builtin"], "off": ["external"] },
    { "key": "2", "name": "Desk",             "on": ["DELL U2720Q"], "off": ["builtin"] },
    { "key": "3", "name": "Laptop + monitor", "on": ["builtin", "DELL U2720Q"], "main": "DELL U2720Q" },
    { "key": "0", "name": "All on",           "on": ["*"] }
  ]
}
```

| Field | Meaning |
|---|---|
| `modifiers` | Modifiers for **all** hotkeys: any of `ctrl`, `alt`/`opt`, `cmd`, `shift`, joined with `+`. |
| `confirmSeconds` | Countdown length. `0` disables the confirmation (not recommended). |
| `language` | `auto` (follow macOS), `en` or `es`. |
| `key` | Hotkey key: `0`–`9`, `a`–`z`, `-` or `=`. Optional: a set without a key is only available from the menu. Keys are physical positions, so they work the same with any keyboard layout. |
| `name` | Name shown in the menu. |
| `on` / `off` | Displays to turn on or off. Displays not listed in either are left alone. Displays that aren't connected are ignored. |
| `main` | Optional: the display that becomes the main display. |

### Display selectors

| Selector | Matches |
|---|---|
| `builtin` | The built-in display |
| `external` | Every connected external display |
| `*` | Every display, including a built-in display that macOS has stopped listing |
| `DELL U2720Q` | Displays with that name |
| `DELL U2720Q#ABC123` | That exact monitor (name + EDID serial). Use this when you have two identical monitors. |
| `3` | A CoreGraphics display ID. Not stable across reconnections; avoid it. |

To see the selector of every connected display, run `screensets list`:

```
1	ON 	builtin
3	ON 	DELL U2720Q#ABC123
4	off	DELL U2720Q#XYZ789
```

Changes are picked up automatically within a couple of seconds, hotkeys included. There is no need to restart anything.

See [examples/sets.example.json](examples/sets.example.json) for a fuller example with two identical monitors.

## Command line

| Command | Effect |
|---|---|
| `screensets list` | Displays, their state and their selectors |
| `screensets sets` | Configured sets |
| `screensets set 1` / `screensets set "Laptop only"` | Apply a set, by key or by name |
| `screensets on builtin` / `off external` / `toggle builtin` | Turn displays on or off directly |
| `screensets init [--force]` | Write the starter configuration |
| `screensets version` | Show the version |

The command line has no confirmation countdown. It still refuses to turn off the last display.

## If something goes wrong

| Problem | What to do |
|---|---|
| No screen at all | Wait a couple of seconds for the automatic rescue. If nothing comes back, press the emergency hotkey (⌃⌥⌘ 0 by default) or plug the external monitor back in. Logging out or restarting always restores every display. |
| Hotkeys do nothing | Check `~/Library/Logs/screensets.log`. It should contain `Hotkeys registered`. `Could not register key X` means another app owns that hotkey. `Error in …sets.json` means the JSON is malformed. |
| A set does nothing | The log line `Set «…»: on=[] off=[]` means none of its displays matched. Compare the selectors with `screensets list`. |
| The modifier keys feel wrong | Some keyboards (or their utilities) swap ⌘ and ⌃. Set `modifiers` to whatever macOS actually receives. |

## Uninstall

```bash
./uninstall.sh            # keeps your sets
./uninstall.sh --purge    # also removes ~/.config/screensets and the log
```

## How it works

screensets turns displays on and off with `CGSConfigureDisplayEnabled`, a **private** CoreGraphics API. It reads monitor names and serial numbers from the IORegistry, and registers hotkeys with Carbon's `RegisterEventHotKey`, which is why it needs no Accessibility permission.

The trickiest part is the rescue. When the only display that is on gets unplugged, macOS creates a phantom "active" display and stops listing the built-in display that is off. screensets therefore only counts displays that are active **and** physically connected, and it remembers the built-in display's ID so it can turn it back on.

Details in [docs/TECHNICAL.md](docs/TECHNICAL.md).

**Caveat:** because it relies on private APIs, a future macOS update could break it. After a major update, check that `screensets off builtin` and `screensets on builtin` still work while an external display is on.

## License

[MIT](LICENSE)
