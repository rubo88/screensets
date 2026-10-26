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
// Uses the private CGSConfigureDisplayEnabled API.
import Cocoa
import Carbon.HIToolbox

let version = "1.1.0"

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

// ---------- Universal Control (pointer and keyboard to a nearby Mac or iPad) ----------

// The same switch as System Settings > Displays > Advanced: the per-host "Disable" key, which
// the UniversalControl agent watches live (it drops or restores the link within a second).
let ucDomain = "com.apple.universalcontrol" as CFString

func universalControlEnabled() -> Bool {
    CFPreferencesCopyValue("Disable" as CFString, ucDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Bool != true
}

func setUniversalControl(_ on: Bool) {
    // removing the key restores the default (on) instead of pinning an explicit value
    CFPreferencesSetValue("Disable" as CFString, on ? nil : kCFBooleanTrue, ucDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    CFPreferencesSynchronize(ucDomain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    log("Universal Control \(on ? "on" : "off")")
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

func jsonString(_ v: String) -> String {
    String(data: (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(),
           encoding: .utf8) ?? "\"\""
}

func writeConfig(_ cfg: Config) throws {
    func list(_ a: [String]) -> String { "[" + a.map(jsonString).joined(separator: ", ") + "]" }
    let sets = cfg.sets.map { s -> String in
        var parts: [String] = []
        if let k = s.key { parts.append("\"key\": \(jsonString(k))") }
        parts.append("\"name\": \(jsonString(s.name))")
        if let on = s.on, !on.isEmpty { parts.append("\"on\": \(list(on))") }
        if let off = s.off, !off.isEmpty { parts.append("\"off\": \(list(off))") }
        if let m = s.main { parts.append("\"main\": \(jsonString(m))") }
        return "    { " + parts.joined(separator: ", ") + " }"
    }
    let text = """
    {
      "modifiers": \(jsonString(cfg.modifiers ?? "ctrl+alt+cmd")),
      "confirmSeconds": \(cfg.confirmSeconds ?? 15),
      "language": \(jsonString(cfg.language ?? "auto")),
      "sets": [
    \(sets.joined(separator: ",\n"))
      ]
    }

    """
    _ = try JSONDecoder().decode(Config.self, from: Data(text.utf8))   // never write something unreadable
    try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    try text.write(toFile: configPath, atomically: true, encoding: .utf8)
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
        add(L("Universal Control (pointer to other Mac)", "Control Universal (ratón al otro Mac)"),
            #selector(toggleUniversalControl), nil).state = universalControlEnabled() ? .on : .off
        menu.addItem(.separator())
        add(L("Edit sets…", "Editar sets…"), #selector(editSets), nil)
        add(L("Open sets.json", "Abrir sets.json"), #selector(openJSON), nil)
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
    @objc func toggleUniversalControl() {
        setUniversalControl(!universalControlEnabled())
        rebuild()
    }
    @objc func editSets() { SetEditor.show() }
    @objc func openJSON() { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) }
    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
}

// ---------- set editor window ----------

// A small window to edit sets.json with the mouse. The JSON stays the source of truth:
// the editor loads it, edits a copy and writes it back on Save.
final class SetEditor: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static var shared: SetEditor?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if FileManager.default.fileExists(atPath: configPath), loadConfig() == nil {
            let a = NSAlert()
            a.messageText = L("sets.json has an error", "sets.json tiene un error")
            a.informativeText = L("Fix it by hand before using the editor (the log says where the error is).",
                                  "Corrígelo a mano antes de usar el editor (el registro indica dónde está el error).")
            a.addButton(withTitle: L("Open sets.json", "Abrir sets.json"))
            a.addButton(withTitle: L("Cancel", "Cancelar"))
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) }
            return
        }
        if shared == nil || shared?.window.isVisible == false { shared = SetEditor() }
        shared!.window.makeKeyAndOrderFront(nil)
    }

    struct EditSet { var key: String?; var name: String; var on: [String]; var off: [String]; var main: String? }

    static let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="] + "abcdefghijklmnopqrstuvwxyz".map(String.init)
    static let modifierDefs = [("ctrl", "⌃ Control"), ("alt", "⌥ Option"), ("shift", "⇧ Shift"), ("cmd", "⌘ Command")]

    var sets: [EditSet] = []
    var rows: [(selector: String, label: String)] = []
    var dirty = false

    var window: NSWindow!
    let table = NSTableView()
    let nameField = NSTextField()
    let keyPopup = NSPopUpButton()
    let mainPopup = NSPopUpButton()
    let displaysStack = NSStackView()
    let confirmField = NSTextField()
    let confirmStepper = NSStepper()
    let langPopup = NSPopUpButton()
    var modBoxes: [(key: String, box: NSButton)] = []
    var removeButton: NSButton!, upButton: NSButton!, downButton: NSButton!, testButton: NSButton!

    var selected: Int? { let r = table.selectedRow; return r >= 0 && r < sets.count ? r : nil }

    override init() {
        super.init()
        buildWindow()
        load()
    }

    // MARK: layout

    func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("screensets — Edit sets", "screensets — Editar sets")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 460)

        // global settings
        modBoxes = Self.modifierDefs.map { ($0.0, NSButton(checkboxWithTitle: $0.1, target: self, action: #selector(globalsChanged))) }
        confirmField.formatter = { let f = NumberFormatter(); f.minimum = 0; f.maximum = 120; f.allowsFloats = false; return f }()
        confirmField.delegate = self
        confirmField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        confirmStepper.minValue = 0; confirmStepper.maxValue = 120; confirmStepper.increment = 5
        confirmStepper.target = self; confirmStepper.action = #selector(stepperChanged)
        for (code, title) in [("auto", "Auto"), ("en", "English"), ("es", "Español")] {
            langPopup.addItem(withTitle: title); langPopup.lastItem?.representedObject = code
        }
        langPopup.target = self; langPopup.action = #selector(globalsChanged)
        let globals = NSStackView(views: [label(L("Hotkeys:", "Atajos:"))] + modBoxes.map(\.box)
            + [label(L("+ key", "+ tecla")), spacer(),
               label(L("Confirm for", "Confirmar durante")), confirmField, confirmStepper, label("s"),
               label(L("   Language:", "   Idioma:")), langPopup])
        globals.spacing = 8

        // set list
        let col = NSTableColumn(identifier: .init("set"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let addButton = button("+", #selector(addSet))
        removeButton = button("−", #selector(removeSet))
        upButton = button("↑", #selector(moveUp))
        downButton = button("↓", #selector(moveDown))
        addButton.toolTip = L("New set", "Nuevo set"); removeButton.toolTip = L("Delete set", "Borrar set")
        upButton.toolTip = L("Move up", "Subir"); downButton.toolTip = L("Move down", "Bajar")
        let left = NSStackView(views: [scroll, NSStackView(views: [addButton, removeButton, upButton, downButton])])
        left.orientation = .vertical; left.alignment = .leading

        // set details
        nameField.delegate = self
        nameField.placeholderString = L("Set name", "Nombre del set")
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        keyPopup.target = self; keyPopup.action = #selector(keyChanged)
        mainPopup.target = self; mainPopup.action = #selector(mainChanged)
        let grid = NSGridView(views: [[label(L("Name:", "Nombre:")), nameField],
                                      [label(L("Hotkey:", "Atajo:")), keyPopup]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.setContentHuggingPriority(.required, for: .horizontal)
        let title = label(L("Displays", "Pantallas"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        displaysStack.orientation = .vertical; displaysStack.alignment = .leading; displaysStack.spacing = 6
        let hint = label(L("“Leave” keeps a display as it is. Displays that aren't connected are ignored.",
                           "«No tocar» deja la pantalla como esté. Las que no estén conectadas se ignoran."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize); hint.textColor = .secondaryLabelColor
        testButton = button(L("Try this set now", "Probar este set ahora"), #selector(testSet))
        let bottomFiller = NSView()
        bottomFiller.setContentHuggingPriority(.init(1), for: .vertical)
        let right = NSStackView(views: [grid, title, displaysStack, hint,
                                        NSStackView(views: [label(L("Main display:", "Pantalla principal:")), mainPopup]),
                                        testButton, bottomFiller])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 12
        right.setCustomSpacing(6, after: title)

        let middle = NSStackView(views: [left, right])
        middle.orientation = .horizontal; middle.alignment = .top; middle.spacing = 24
        middle.setContentHuggingPriority(.init(1), for: .vertical)

        // bottom bar
        let cancel = button(L("Cancel", "Cancelar"), #selector(cancelEditing))
        cancel.keyEquivalent = "\u{1b}"
        let save = button(L("Save", "Guardar"), #selector(save))
        save.keyEquivalent = "\r"
        let bottom = NSStackView(views: [button(L("Open sets.json…", "Abrir sets.json…"), #selector(openJSON)), spacer(), cancel, save])

        let root = NSStackView(views: [globals, middle, bottom])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [globals, middle, bottom] { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        window.contentView = root
        window.initialFirstResponder = table
        window.center()
    }

    // MARK: model ⇄ UI

    func load() {
        let cfg = loadConfig()
        sets = (cfg?.sets ?? []).map { EditSet(key: $0.key, name: $0.name, on: $0.on ?? [], off: $0.off ?? [], main: $0.main) }
        let mods = Set(modifierParts(cfg?.modifiers).map { p -> String in
            switch p { case "control": return "ctrl"; case "opt", "option": return "alt"; case "command": return "cmd"; default: return String(p) }
        })
        for m in modBoxes { m.box.state = mods.contains(m.key) ? .on : .off }
        confirmStepper.integerValue = cfg?.confirmSeconds ?? 15
        confirmField.integerValue = confirmStepper.integerValue
        let lang = cfg?.language?.lowercased() ?? "auto"
        langPopup.selectItem(at: max(0, langPopup.itemArray.firstIndex { ($0.representedObject as? String) == lang } ?? 0))
        table.reloadData()
        if !sets.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        refreshDetail()
        dirty = false
    }

    var modifiersString: String { modBoxes.filter { $0.box.state == .on }.map(\.key).joined(separator: "+") }

    var modifierSymbols: String {
        let on = Set(modBoxes.filter { $0.box.state == .on }.map(\.key))
        return [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")].filter { on.contains($0.0) }.map(\.1).joined()
    }

    func hotkeyTitle(_ key: String?) -> String { key.map { modifierSymbols + $0.uppercased() } ?? "—" }

    // Display rows: built-in, all externals, all, every selector used by some set and every
    // connected display that no named selector covers yet.
    func computeRows() -> [(selector: String, label: String)] {
        let all = displays()
        var out: [(selector: String, label: String)] = [
            ("builtin", L("Built-in display", "Pantalla del Mac")),
            ("external", L("All external displays", "Todas las externas")),
            ("*", L("All displays", "Todas las pantallas")),
        ]
        func describe(_ sel: String) -> String {
            let parts = sel.split(separator: "#", maxSplits: 1).map(String.init)
            var t = parts[0]
            if parts.count > 1 { t += " (…\(parts[1].suffix(4)))" }
            if resolve(sel, in: all).isEmpty { t += L(" — not connected", " — no conectada") }
            return t
        }
        for s in sets {
            for sel in s.on + s.off + [s.main].compactMap({ $0 }) where !out.contains(where: { $0.selector == sel }) {
                out.append((sel, describe(sel)))
            }
        }
        let special: Set<String> = ["builtin", "external", "*"]
        for d in all where d.connected && !d.builtin {
            let covered = out.contains { !special.contains($0.selector) && resolve($0.selector, in: all).contains { $0.id == d.id } }
            if !covered { out.append((d.selector, describe(d.selector))) }
        }
        return out
    }

    func refreshDetail() {
        let i = selected
        for c in [nameField, keyPopup, mainPopup, testButton, removeButton] as [NSControl] { c.isEnabled = i != nil }
        upButton.isEnabled = (i ?? 0) > 0
        downButton.isEnabled = i.map { $0 < sets.count - 1 } ?? false
        displaysStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        keyPopup.removeAllItems(); mainPopup.removeAllItems()
        guard let i else { nameField.stringValue = ""; return }
        let s = sets[i]
        if nameField.currentEditor() == nil { nameField.stringValue = s.name }

        keyPopup.addItem(withTitle: L("None (menu only)", "Ninguno (solo menú)"))
        for k in Self.keys {
            let other = sets.indices.first { $0 != i && sets[$0].key == k }.map { sets[$0].name }
            keyPopup.addItem(withTitle: hotkeyTitle(k) + (other.map { L("   (used by “\($0)”)", "   (lo usa «\($0)»)") } ?? ""))
            keyPopup.lastItem?.representedObject = k
        }
        keyPopup.selectItem(at: s.key.flatMap { Self.keys.firstIndex(of: $0.lowercased()) }.map { $0 + 1 } ?? 0)

        rows = computeRows()
        for (idx, r) in rows.enumerated() {
            let l = label(r.label)
            l.lineBreakMode = .byTruncatingTail
            l.widthAnchor.constraint(equalToConstant: 250).isActive = true
            let seg = NSSegmentedControl(labels: [L("Leave", "No tocar"), L("On", "Encender"), L("Off", "Apagar")],
                                         trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
            seg.tag = idx
            seg.selectedSegment = s.on.contains(r.selector) ? 1 : s.off.contains(r.selector) ? 2 : 0
            if r.selector == "*" { seg.setEnabled(false, forSegment: 2) }   // "turn everything off" makes no sense
            displaysStack.addArrangedSubview(NSStackView(views: [l, seg]))
        }

        mainPopup.addItem(withTitle: L("Don't change", "No cambiar"))
        for r in rows where r.selector != "external" && r.selector != "*" {
            mainPopup.addItem(withTitle: r.label); mainPopup.lastItem?.representedObject = r.selector
        }
        mainPopup.selectItem(at: max(0, mainPopup.itemArray.firstIndex { ($0.representedObject as? String) == s.main } ?? 0))
    }

    func markDirty() { dirty = true; window.isDocumentEdited = true }

    func reloadRow(_ i: Int) { table.reloadData(forRowIndexes: [i], columnIndexes: [0]) }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { sets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = sets[row]
        let key = label(hotkeyTitle(s.key))
        key.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        key.textColor = .secondaryLabelColor
        key.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let name = label(s.name)
        name.lineBreakMode = .byTruncatingTail
        let v = NSStackView(views: [key, name])
        v.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshDetail() }

    // MARK: actions

    func controlTextDidChange(_ n: Notification) {
        guard let field = n.object as? NSTextField else { return }
        if field === nameField, let i = selected {
            sets[i].name = nameField.stringValue
            reloadRow(i); markDirty()
        } else if field === confirmField {
            confirmStepper.integerValue = confirmField.integerValue
            markDirty()
        }
    }

    @objc func segmentChanged(_ seg: NSSegmentedControl) {
        guard let i = selected, seg.tag < rows.count else { return }
        let sel = rows[seg.tag].selector
        sets[i].on.removeAll { $0 == sel }
        sets[i].off.removeAll { $0 == sel }
        if seg.selectedSegment == 1 { sets[i].on.append(sel) }
        if seg.selectedSegment == 2 { sets[i].off.append(sel) }
        markDirty()
    }

    @objc func keyChanged() {
        guard let i = selected else { return }
        sets[i].key = keyPopup.selectedItem?.representedObject as? String
        reloadRow(i); markDirty(); refreshDetail()
    }

    @objc func mainChanged() {
        guard let i = selected else { return }
        sets[i].main = mainPopup.selectedItem?.representedObject as? String
        markDirty()
    }

    @objc func globalsChanged() {
        markDirty()
        let i = selected
        table.reloadData()
        if let i { table.selectRowIndexes([i], byExtendingSelection: false) }
        refreshDetail()
    }

    @objc func stepperChanged() { confirmField.integerValue = confirmStepper.integerValue; markDirty() }

    @objc func addSet() {
        sets.append(EditSet(key: nil, name: L("New set", "Nuevo set"), on: ["builtin"], off: [], main: nil))
        table.reloadData()
        table.selectRowIndexes([sets.count - 1], byExtendingSelection: false)
        table.scrollRowToVisible(sets.count - 1)
        markDirty()
        window.makeFirstResponder(nameField)
    }

    @objc func removeSet() {
        guard let i = selected else { return }
        sets.remove(at: i)
        table.reloadData()
        if !sets.isEmpty { table.selectRowIndexes([min(i, sets.count - 1)], byExtendingSelection: false) }
        refreshDetail(); markDirty()
    }

    func move(_ delta: Int) {
        guard let i = selected, sets.indices.contains(i + delta) else { return }
        sets.swapAt(i, i + delta)
        table.reloadData()
        table.selectRowIndexes([i + delta], byExtendingSelection: false)
        markDirty()
    }
    @objc func moveUp() { move(-1) }
    @objc func moveDown() { move(1) }

    func toDisplaySet(_ s: EditSet) -> DisplaySet {
        DisplaySet(key: s.key, name: s.name.trimmingCharacters(in: .whitespaces),
                   on: s.on.isEmpty ? nil : s.on, off: s.off.isEmpty ? nil : s.off, main: s.main)
    }

    @objc func testSet() {
        guard let i = selected else { return }
        let s = toDisplaySet(sets[i])
        runAction(s.name) { applySet(s) }
    }

    @objc func openJSON() { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) }

    func complain(_ message: String, _ info: String = "") {
        let a = NSAlert()
        a.messageText = message; a.informativeText = info
        a.beginSheetModal(for: window)
    }

    @discardableResult
    @objc func save() -> Bool {
        window.makeFirstResponder(nil)   // commit the field being edited
        if let i = sets.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            complain(L("Every set needs a name.", "Todos los sets necesitan un nombre.")); return false
        }
        let names = sets.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if let dup = names.first(where: { n in names.filter { $0 == n }.count > 1 }) {
            complain(L("Two sets are called “\(dup)”.", "Hay dos sets que se llaman «\(dup)»."),
                     L("Names must be unique.", "Los nombres no pueden repetirse.")); return false
        }
        let keys = sets.compactMap(\.key)
        if let dup = keys.first(where: { k in keys.filter { $0 == k }.count > 1 }) {
            complain(L("Two sets use the hotkey \(hotkeyTitle(dup)).", "Hay dos sets con el atajo \(hotkeyTitle(dup))."))
            return false
        }
        if modBoxes.filter({ $0.box.state == .on && $0.key != "shift" }).isEmpty {
            complain(L("Choose at least ⌃, ⌥ or ⌘ for the hotkeys.", "Elige al menos ⌃, ⌥ o ⌘ para los atajos."),
                     L("Otherwise the hotkeys would capture normal typing.", "Si no, los atajos capturarían lo que escribes."))
            return false
        }
        let code = langPopup.selectedItem?.representedObject as? String ?? "auto"
        let cfg = Config(modifiers: modifiersString, confirmSeconds: max(0, confirmField.integerValue),
                         language: code, sets: sets.map(toDisplaySet))
        do { try writeConfig(cfg) } catch {
            complain(L("Could not save sets.json", "No se pudo guardar sets.json"), "\(error)"); return false
        }
        log("Sets saved from the editor (\(sets.count) sets)")
        registerHotkeys()
        menuController?.rebuild()
        dirty = false; window.isDocumentEdited = false
        window.orderOut(nil)
        return true
    }

    @objc func cancelEditing() {
        dirty = false; window.isDocumentEdited = false
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let a = NSAlert()
        a.messageText = L("Save your changes?", "¿Guardar los cambios?")
        a.addButton(withTitle: L("Save", "Guardar"))
        a.addButton(withTitle: L("Don't save", "No guardar"))
        a.addButton(withTitle: L("Cancel", "Cancelar"))
        switch a.runModal() {
        case .alertFirstButtonReturn: save(); return false   // save() hides the window itself
        case .alertSecondButtonReturn: dirty = false; return true
        default: return false
        }
    }
}

var hotkeySetKeys: [UInt32: String] = [:]
var hotkeyRefs: [EventHotKeyRef] = []
var hotkeysConfigMTime: Date?
var menuController: MenuController?

func configMTime() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
}

// (Re)registers every hotkey from sets.json; called at launch and whenever the file changes
func registerHotkeys() {
    hotkeyRefs.forEach { UnregisterEventHotKey($0) }
    hotkeyRefs = []; hotkeySetKeys = [:]
    hotkeysConfigMTime = configMTime()
    guard let cfg = loadConfig() else { return }
    let mods = carbonModifiers(cfg.modifiers)
    var n: UInt32 = 0
    for key in Set(cfg.sets.compactMap(\.key)) {
        guard let vk = keyCodes[key.lowercased()] else { log("Unsupported key: \(key)"); continue }
        n += 1
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(UInt32(vk), mods, EventHotKeyID(signature: OSType(0x4453504C), id: n),
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref { hotkeySetKeys[n] = key; hotkeyRefs.append(ref) }
        else { log("Could not register key \(key) (used by another app?)") }
    }
    log("Hotkeys registered (\(cfg.modifiers ?? "ctrl+alt+cmd")): \(hotkeySetKeys.values.sorted())")
}

// An accessory app has no visible menu bar, but text fields still need ⌘C/⌘V/⌘X/⌘A/⌘Z
func installEditMenu() {
    let main = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
}
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

    registerHotkeys()
    installEditMenu()

    CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
        if flags.contains(.beginConfigurationFlag) { return }
        log("Reconfiguration: display \(id) flags=0x\(String(flags.rawValue, radix: 16))")
        onMain(after: 1.5) {
            ensureSomeDisplay("reconfig")
            menuController?.rebuild()
            if SetEditor.shared?.window.isVisible == true { SetEditor.shared?.refreshDetail() }   // new displays show up live
        }
    }, nil)
    // in case the reconfiguration callback never arrives
    RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { _ in
        ensureSomeDisplay()
        if configMTime() != hotkeysConfigMTime { registerHotkeys() }   // sets.json edited by hand
        menuController?.rebuild()
    }, forMode: .common)
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
