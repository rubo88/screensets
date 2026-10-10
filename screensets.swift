// screensets — turn Mac displays on/off with global hotkeys and a menu bar icon,
// with safety nets so you never end up without a working display.
//
//   screensets list                                  displays and their selectors
//   screensets on|off|toggle <selector>              builtin | external | * | "Name" | "Name#SERIAL" | ID
//   screensets set <key|name>                        apply a set from ~/.config/screensets/sets.json
//   screensets sets                                  list the configured sets
//   screensets init [--force]                        write a starter sets.json
//   screensets daemon                                menu bar + hotkeys + safety net (run by launchd)
//
// Uses the private CGSConfigureDisplayEnabled API (same mechanism as SwitchResX / BetterDisplay).
import Cocoa
import Carbon.HIToolbox

let version = "1.0.0"

@_silgen_name("CGSGetDisplayList")
func CGSGetDisplayList(_ max: UInt32, _ ids: UnsafeMutablePointer<CGDirectDisplayID>?, _ count: UnsafeMutablePointer<UInt32>) -> CGError
@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError
@_silgen_name("CoreDisplay_DisplayCreateInfoDictionary")
func CoreDisplay_DisplayCreateInfoDictionary(_ d: CGDirectDisplayID) -> Unmanaged<CFDictionary>?

let configDir = ProcessInfo.processInfo.environment["SCREENSETS_CONFIG_DIR"]
    ?? NSString(string: "~/.config/screensets").expandingTildeInPath
let configPath = configDir + "/sets.json"
let builtinIDPath = configDir + "/builtin-id"
let logPath = NSString(string: "~/Library/Logs/screensets.log").expandingTildeInPath

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(s)"); fflush(stdout)
}

// ---------- localization (UI only; the log stays in English) ----------

// "language" in sets.json: "en", "es" or "auto" (default: the Mac's first preferred language)
var uiSpanish = (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
func L(_ en: String, _ es: String) -> String { uiSpanish ? es : en }

// ---------- displays ----------

struct Display {
    let id: CGDirectDisplayID
    let builtin: Bool
    let name: String
    let serial: String      // alphanumeric EDID serial number ("" if none)
    let connected: Bool     // physically present (even if turned off)
    var active: Bool { activeIDs().contains(id) }
    var selector: String { builtin ? "builtin" : serial.isEmpty ? name : "\(name)#\(serial)" }
}

func activeIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32); var n: UInt32 = 0
    _ = CGGetActiveDisplayList(32, &ids, &n)
    return Array(ids[0..<Int(n)])
}

func displays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32); var n: UInt32 = 0
    _ = CGSGetDisplayList(32, &ids, &n)   // unlike CGGetOnlineDisplayList, includes displays that are off
    return ids[0..<Int(n)].map { id in
        let builtin = CGDisplayIsBuiltin(id) != 0
        var name = builtin ? "Built-in" : "Unknown", serial = "", connected = builtin
        // CoreDisplay gives the framebuffer's IORegistry path; the parsed EDID lives there
        if let info = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as? [String: Any],
           let loc = info["IODisplayLocation"] as? String {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, loc)
            defer { IOObjectRelease(entry) }
            if entry != 0,
               let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                   .takeRetainedValue() as? [String: Any],
               let prod = attrs["ProductAttributes"] as? [String: Any] {
                connected = true
                if !builtin { name = prod["ProductName"] as? String ?? name }
                serial = prod["AlphanumericSerialNumber"] as? String ?? ""
            }
        }
        return Display(id: id, builtin: builtin, name: name, serial: builtin ? "" : serial, connected: connected)
    }
}

// With the built-in display off and no external display left, macOS stops listing the
// built-in one, so its ID is remembered (on Apple Silicon it is 1) to be able to turn it on.
func knownBuiltinID() -> CGDirectDisplayID {
    if let b = displays().first(where: { $0.builtin }) {
        try? String(b.id).write(toFile: builtinIDPath, atomically: true, encoding: .utf8)
        return b.id
    }
    let saved = (try? String(contentsOfFile: builtinIDPath, encoding: .utf8))
        .flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return saved ?? 1
}

func resolve(_ sel: String, in all: [Display]) -> [Display] {
    let conn = all.filter { $0.connected }
    switch sel {
    case "*", "all":
        if conn.contains(where: \.builtin) { return conn }
        return conn + [Display(id: knownBuiltinID(), builtin: true, name: "Built-in", serial: "", connected: true)]
    case "builtin": return conn.filter { $0.builtin }
    case "external": return conn.filter { !$0.builtin }
    default:
        if let id = UInt32(sel) { return conn.filter { $0.id == id } }
        let parts = sel.split(separator: "#", maxSplits: 1).map(String.init)
        return conn.filter {
            $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame
                && (parts.count == 1 || $0.serial.caseInsensitiveCompare(parts[1]) == .orderedSame)
        }
    }
}

var lastTurnedOff: [CGDirectDisplayID] = []

// Turn `on` on first, then `off` off (never leaving zero displays), then set the main display.
@discardableResult
func apply(on: [Display], off: [Display], main: Display? = nil) -> Bool {
    var ok = true
    let toOn = on.filter { !$0.active }
    if !toOn.isEmpty { ok = configure(toOn.map(\.id), true) && ok }

    var toOff = off.filter { $0.active }.map(\.id)
    if !toOff.isEmpty && activeIDs().allSatisfy({ toOff.contains($0) }) {
        log("Refused: turning off \(toOff) would leave no display on.")
        toOff = []; ok = false
    }
    if !toOff.isEmpty { ok = configure(toOff, false) && ok }
    lastTurnedOff = toOff

    if let m = main, m.active { setMain(m.id) }
    return ok
}

// .forSession: changes are undone on logout/restart, so a reboot always brings every display back
func configure(_ ids: [CGDirectDisplayID], _ enabled: Bool, _ option: CGConfigureOption = .forSession) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
    for d in ids { _ = CGSConfigureDisplayEnabled(cfg, d, enabled) }
    return CGCompleteDisplayConfiguration(cfg, option) == .success
}

// The main display is the one at (0,0): shift every display so that `id` is there.
func setMain(_ id: CGDirectDisplayID) {
    let o = CGDisplayBounds(id).origin
    if o == .zero { return }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
    for d in activeIDs() {
        let b = CGDisplayBounds(d).origin
        CGConfigureDisplayOrigin(cfg, d, Int32(b.x - o.x), Int32(b.y - o.y))
    }
    CGCompleteDisplayConfiguration(cfg, .forSession)
}

// ---------- sets ----------

struct DisplaySet: Codable {
    let key: String?
    let name: String
    let on: [String]?
    let off: [String]?
    let main: String?
}
struct Config: Codable {
    let modifiers: String?
    let confirmSeconds: Int?   // countdown to confirm after turning displays off (0 = don't ask)
    let language: String?      // "en" | "es" | "auto"
    let sets: [DisplaySet]
}

func loadConfig() -> Config? {
    guard let data = FileManager.default.contents(atPath: configPath) else { log("Missing \(configPath)"); return nil }
    do {
        let cfg = try JSONDecoder().decode(Config.self, from: data)
        switch cfg.language?.lowercased() {
        case "es": uiSpanish = true
        case "en": uiSpanish = false
        default: uiSpanish = (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
        }
        return cfg
    } catch { log("Error in \(configPath): \(error)"); return nil }
}

@discardableResult
func applySet(_ s: DisplaySet) -> Bool {
    let all = displays()
    let on = (s.on ?? []).flatMap { resolve($0, in: all) }
    let off = (s.off ?? []).flatMap { resolve($0, in: all) }.filter { d in !on.contains { $0.id == d.id } }
    let main = s.main.flatMap { resolve($0, in: all).first }
    log("Set «\(s.name)»: on=\(on.map(\.selector)) off=\(off.map(\.selector)) main=\(main?.selector ?? "-")")
    return apply(on: on, off: off, main: main)
}

func findSet(_ q: String) -> DisplaySet? {
    loadConfig()?.sets.first { $0.key == q || $0.name.caseInsensitiveCompare(q) == .orderedSame }
}

func starterConfig() -> String {
    let (only, ext, all) = uiSpanish
        ? ("Solo el Mac", "Solo externas", "Todas encendidas")
        : ("Built-in only", "External only", "All displays on")
    return """
    {
      "modifiers": "ctrl+alt+cmd",
      "confirmSeconds": 15,
      "language": "auto",
      "sets": [
        { "key": "1", "name": "\(only)", "on": ["builtin"],  "off": ["external"] },
        { "key": "2", "name": "\(ext)",  "on": ["external"], "off": ["builtin"] },
        { "key": "0", "name": "\(all)",  "on": ["*"] }
      ]
    }

    """
}

// ---------- hotkeys (Carbon: no Accessibility permission needed) ----------

let keyCodes: [String: Int] = [
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
    "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
    "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
    "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
]

func modifierParts(_ s: String?) -> [Substring] { (s ?? "ctrl+alt+cmd").lowercased().split(separator: "+") }

func carbonModifiers(_ s: String?) -> UInt32 {
    var m = 0
    for p in modifierParts(s) {
        switch p {
        case "ctrl", "control": m |= controlKey
        case "alt", "opt", "option": m |= optionKey
        case "cmd", "command": m |= cmdKey
        case "shift": m |= shiftKey
        default: log("Unknown modifier: \(p)")
        }
    }
    return UInt32(m)
}

func menuModifiers(_ s: String?) -> NSEvent.ModifierFlags {
    var m: NSEvent.ModifierFlags = []
    for p in modifierParts(s) {
        switch p {
        case "ctrl", "control": m.insert(.control)
        case "alt", "opt", "option": m.insert(.option)
        case "cmd", "command": m.insert(.command)
        case "shift": m.insert(.shift)
        default: break
        }
    }
    return m
}

// ---------- daemon: menu bar + hotkeys + safety net ----------

// Runs on the main run loop, also while a modal window is open
func onMain(after secs: TimeInterval, _ block: @escaping () -> Void) {
    RunLoop.main.add(Timer(timeInterval: secs, repeats: false) { _ in block() }, forMode: .common)
}

var busy = false

// Every daemon action goes through here: if it turned a display off, ask for confirmation with
// a countdown and, if nobody answers (e.g. because nothing is visible), turn it back on.
func runAction(_ what: String, _ action: () -> Void) {
    guard !busy else { log("Ignored «\(what)»: a confirmation is pending."); return }
    busy = true
    // (no before/after comparison: macOS applies the change asynchronously)
    lastTurnedOff = []
    action()
    let turnedOff = lastTurnedOff
    let secs = loadConfig()?.confirmSeconds ?? 15
    guard !turnedOff.isEmpty, secs > 0 else { busy = false; return }
    onMain(after: 1.0) {   // let macOS rearrange desktops and windows first
        if !confirmKeep(secs) {
            log("«\(what)» not confirmed: turning \(turnedOff) back on.")
            _ = configure(turnedOff, true)
        }
        busy = false
    }
}

func confirmKeep(_ seconds: Int) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L("Keep this display configuration?", "¿Mantener esta configuración de pantallas?")
    alert.addButton(withTitle: L("Keep", "Mantener"))                         // Return
    alert.addButton(withTitle: L("Revert", "Deshacer")).keyEquivalent = "\u{1b}" // Esc
    var left = seconds
    let text = { L("Reverting in \(left) s if you don't answer.", "Si no respondes, se deshará en \(left) s.") }
    alert.informativeText = text()
    alert.window.level = .statusBar
    let t = Timer(timeInterval: 1, repeats: true) { t in
        left -= 1
        alert.informativeText = text()
        if left <= 0 { t.invalidate(); NSApp.abortModal() }
    }
    RunLoop.main.add(t, forMode: .common)
    let t0 = Date()
    let r = alert.runModal()
    t.invalidate()
    log("Confirmation: \(r == .alertFirstButtonReturn ? "keep" : "revert") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    return r == .alertFirstButtonReturn
}

// Safety net: if no usable display is left, turn the built-in one on.
// "Usable" = active AND physically connected. When the only display that is on gets unplugged,
// macOS creates a phantom "active" display that doesn't exist and stops listing the built-in one.
var lastState = ""
var rescueAttempt = 0
func ensureSomeDisplay(_ why: String = "timer") {
    let all = displays(), active = activeIDs()
    let usable = all.filter { $0.connected && active.contains($0.id) }
    let state = "active=\(active) connected=\(all.filter(\.connected).map(\.id)) usable=\(usable.map(\.id))"
    if state != lastState { log("State (\(why)): \(state)"); lastState = state }
    guard usable.isEmpty else {
        rescueAttempt = 0
        if all.contains(where: \.builtin) { _ = knownBuiltinID() }   // remember it while it is visible
        return
    }

    // One method per attempt, cycling until a usable display shows up
    let b = knownBuiltinID()
    let candidates = Array(Set([b] + Array(1...8) + all.map(\.id)).subtracting(active)).sorted()
    let attempt = rescueAttempt % 3
    rescueAttempt += 1
    let ok: Bool
    switch attempt {
    case 0: ok = configure([b], true)
    case 1: ok = configure([b], true, .permanently)
    default: ok = configure(candidates, true)
    }
    log("RESCUE #\(rescueAttempt) (method \(attempt), built-in=\(b), candidates=\(candidates)) -> \(ok ? "ok" : "ERROR")")
}

final class MenuController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    override init() {
        super.init()
        let img = NSImage(systemSymbolName: "display.2", accessibilityDescription: "screensets")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = "screensets"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuild()
    }

    // Rebuilding the menu while it is open makes AppKit throw (macOS 26), so it is rebuilt
    // only while closed: at launch, after every display change and every couple of seconds.
    var isOpen = false
    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    func rebuild() {
        if isOpen { return }
        menu.removeAllItems()
        let cfg = loadConfig()
        let conn = displays().filter(\.connected)
        header(L("Displays", "Pantallas"))
        for d in conn {
            let twins = conn.filter { $0.name == d.name }.count > 1
            let title = d.builtin ? L("Built-in display", "Pantalla del Mac") : twins ? "\(d.name) (…\(d.serial.suffix(3)))" : d.name
            add(title, #selector(toggleDisplay(_:)), d.id).state = d.active ? .on : .off
        }
        menu.addItem(.separator())
        header("Sets")
        for s in cfg?.sets ?? [] {
            let mi = add(s.name, #selector(applySetItem(_:)), s.name)
            if let k = s.key { mi.keyEquivalent = k; mi.keyEquivalentModifierMask = menuModifiers(cfg?.modifiers) }
        }
        menu.addItem(.separator())
        add(L("Edit sets…", "Editar sets…"), #selector(editSets), nil)
        add(L("Show log", "Ver registro"), #selector(showLog), nil)
    }

    func header(_ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    @discardableResult
    func add(_ title: String, _ sel: Selector, _ obj: Any?) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self; mi.representedObject = obj
        menu.addItem(mi)
        return mi
    }

    @objc func toggleDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CGDirectDisplayID,
              let d = displays().first(where: { $0.id == id }) else { return }
        runAction(d.active ? "turn off \(d.selector)" : "turn on \(d.selector)") {
            if d.active { apply(on: [], off: [d]) } else { apply(on: [d], off: []) }
        }
    }
    @objc func applySetItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let s = findSet(name) else { return }
        runAction(s.name) { applySet(s) }
    }
    @objc func editSets() { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) }
    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
}

var hotkeySetKeys: [UInt32: String] = [:]
var menuController: MenuController?
var napActivity: NSObjectProtocol?

func runDaemon() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no Dock icon
    // no App Nap: the safety net must react even while the process is "in the background"
    napActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Watch displays")
    log("screensets \(version) starting")
    menuController = MenuController()

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        // the file is re-read on every key press: editing a set needs no restart
        if let key = hotkeySetKeys[hk.id], let s = findSet(key) { runAction(s.name) { applySet(s) } }
        return noErr
    }, 1, &spec, nil, nil)

    if let cfg = loadConfig() {
        let mods = carbonModifiers(cfg.modifiers)
        var n: UInt32 = 0
        for key in Set(cfg.sets.compactMap(\.key)) {
            guard let vk = keyCodes[key.lowercased()] else { log("Unsupported key: \(key)"); continue }
            n += 1
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(vk), mods, EventHotKeyID(signature: OSType(0x4453504C), id: n),
                                          GetApplicationEventTarget(), 0, &ref)
            if err == noErr { hotkeySetKeys[n] = key } else { log("Could not register key \(key) (used by another app?)") }
        }
        log("Hotkeys registered (\(cfg.modifiers ?? "ctrl+alt+cmd")): \(hotkeySetKeys.values.sorted())")
    }

    CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
        if flags.contains(.beginConfigurationFlag) { return }
        log("Reconfiguration: display \(id) flags=0x\(String(flags.rawValue, radix: 16))")
        onMain(after: 1.5) { ensureSomeDisplay("reconfig"); menuController?.rebuild() }
    }, nil)
    // in case the reconfiguration callback never arrives
    RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { _ in ensureSomeDisplay(); menuController?.rebuild() }, forMode: .common)
    ensureSomeDisplay()
    app.run()
}

// ---------- CLI ----------

_ = FileManager.default.fileExists(atPath: configPath) ? loadConfig() : nil   // sets the UI language

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list":
    for d in displays() {
        print("\(d.id)\t\(d.active ? "ON " : d.connected ? "off" : "--")\t\(d.selector)")
    }
case "on", "off", "toggle":
    guard args.count > 1 else { print(L("Which display? builtin | external | * | Name[#SERIAL] | ID",
                                        "¿Qué pantalla? builtin | external | * | Nombre[#SERIE] | ID")); exit(1) }
    let targets = resolve(args[1], in: displays())
    guard !targets.isEmpty else { print(L("No connected display matches «\(args[1])»",
                                          "Ninguna pantalla conectada coincide con «\(args[1])»")); exit(1) }
    let turnOn = args[0] == "on" || (args[0] == "toggle" && !targets.contains { $0.active })
    exit(apply(on: turnOn ? targets : [], off: turnOn ? [] : targets) ? 0 : 1)
case "set":
    guard args.count > 1, let s = findSet(args[1]) else { print(L("Set not found", "Set no encontrado")); exit(1) }
    exit(applySet(s) ? 0 : 1)
case "sets":
    let cfg = loadConfig()
    for s in cfg?.sets ?? [] {
        print("\(cfg?.modifiers ?? "ctrl+alt+cmd")+\(s.key ?? "?")\t\(s.name)\ton=\(s.on ?? []) off=\(s.off ?? [])\(s.main.map { " main=\($0)" } ?? "")")
    }
case "init":
    if FileManager.default.fileExists(atPath: configPath) && !args.contains("--force") {
        print(L("\(configPath) already exists (use --force to overwrite)", "\(configPath) ya existe (usa --force para sobrescribirlo)"))
        exit(0)
    }
    try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    do { try starterConfig().write(toFile: configPath, atomically: true, encoding: .utf8) }
    catch { print("Error: \(error)"); exit(1) }
    print(L("Wrote \(configPath)", "Creado \(configPath)"))
case "daemon":
    runDaemon()
case "version", "--version", "-v":
    print("screensets \(version)")
default:
    print(L("""
    screensets \(version) — turn displays on/off with hotkeys

    Usage: screensets list
           screensets on|off|toggle <builtin|external|*|Name[#SERIAL]|ID>
           screensets set <key|name>     screensets sets
           screensets init [--force]     screensets daemon
    """, """
    screensets \(version) — enciende y apaga pantallas con atajos

    Uso: screensets list
         screensets on|off|toggle <builtin|external|*|Nombre[#SERIE]|ID>
         screensets set <tecla|nombre>   screensets sets
         screensets init [--force]       screensets daemon
    """))
}
