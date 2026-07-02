// vk01d.swift — VK-01 knob daemon, menu bar edition.
// Translates the knob's ⌃⌥+F16–F20 chords into layered actions.
// Behavior is config-driven: ~/Library/Application Support/vk01d/config.json
// (written with defaults on first launch; schema in DESIGN.md). The defaults
// replicate the original POC — Layer 1 "Navigate": scroll / ⌘± zoom / ⌘↑→⌘0;
// Layer 2 "Media": volume / brightness / mute.
// Switch layers by double-tapping the knob, with recorded keyboard shortcuts,
// or from the menu; the menu bar icon (①/②) shows the current layer.
// Configure via the Settings… window (SettingsUI.swift, instant apply) or
// edit the JSON + menu → Reload Config.
// Build the app bundle with ./build.sh, launch with `open vk01d.app`.
// Needs Accessibility + Input Monitoring granted to vk01d (prompts on first run).

import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// ---- ground truth ----------------------------------------------------------
// The five chords the VK-01 sends, bound once into the knob's own flash via the
// vendor app. Nothing on the host can change them, so they are NOT in the config.

let requiredMods: CGEventFlags = [.maskControl, .maskAlternate]   // what the VK-01 sends
let kTwistL: Int64 = 106, kPress: Int64 = 64, kTwistR: Int64 = 79 // F16, F17, F18
let kHoldTwistL: Int64 = 80, kHoldTwistR: Int64 = 90              // F19, F20
let knobKeys: Set<Int64> = [kTwistL, kPress, kTwistR, kHoldTwistL, kHoldTwistR]

let verbose = CommandLine.arguments.contains("-v")

enum Gesture: String {
    case twistL, twistR, holdTwistL, holdTwistR, press
}

func gesture(for code: Int64) -> Gesture? {
    switch code {
    case kTwistL:     return .twistL
    case kTwistR:     return .twistR
    case kHoldTwistL: return .holdTwistL
    case kHoldTwistR: return .holdTwistR
    case kPress:      return .press
    default:          return nil
    }
}

// ---- config model ----------------------------------------------------------
// JSON: { layers: [ { name, twistL, twistR, holdTwistL, holdTwistR, press } ],
//         doubleTapSwitch, doubleTapWindow, layerHotkey, layerHotkeyBack,
//         scrollLinesPerDetent }
// Each gesture slot is an action: scroll / keyChord / sequence / aux /
// launchApp / openURL / openPath / quitApp / hotkeySwitch / none.

struct SeqStep: Codable {
    var key: CGKeyCode? = nil    // CG virtual keycode to press…
    var mods: [String]? = nil    // …with these modifiers ("cmd" "shift" "opt" "ctrl" "fn")
    var delayMs: Int? = nil      // pause after this step (a step can also be delay-only)
    var label: String? = nil     // display only (what the UI shows for the key)
}

enum AuxKey: String, Codable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    case brightnessUpExternal, brightnessDownExternal   // legacy aliases of the pair above
    case playPause, next, previous

    // Volume/media go out as NX aux events (system behavior + HUD). Brightness
    // goes out as the legacy F15/F14 brightness keys, which macOS routes to
    // built-in and supported external displays alike; the External cases only
    // remain so configs from before the unification still decode.
    // The symbolic hotkeys (AppleSymbolicHotKeys 53/54) are registered as
    // F14/F15 + 0x800000 — real F-key presses carry that fn flag implicitly,
    // so synthetic ones must set .maskSecondaryFn or they never match.
    func post() {
        switch self {
        case .volumeUp:       postAuxKey(NX_SOUND_UP)
        case .volumeDown:     postAuxKey(NX_SOUND_DOWN)
        case .mute:           postAuxKey(NX_MUTE)
        case .brightnessUp, .brightnessUpExternal:     postKey(113, flags: .maskSecondaryFn)   // F15
        case .brightnessDown, .brightnessDownExternal: postKey(107, flags: .maskSecondaryFn)   // F14
        case .playPause:      postAuxKey(NX_PLAY)
        case .next:           postAuxKey(NX_NEXT)
        case .previous:       postAuxKey(NX_PREVIOUS)
        }
    }
}

enum Action: Codable {
    case scroll(lines: Int32?)                    // nil → scrollLinesPerDetent
    case keyChord(key: CGKeyCode, mods: [String], label: String?) // label = display only
    case sequence(steps: [SeqStep])
    case aux(key: AuxKey)
    case launchApp(bundleId: String)
    case openURL(url: String)
    case openPath(path: String)
    case quitApp(bundleId: String, force: Bool?)
    case hotkeySwitch(first: KeyChordSpec?, second: KeyChordSpec?) // alternates per trigger
    case none

    private enum CodingKeys: String, CodingKey { case type, lines, key, mods, steps, bundleId, label, url, path, force, first, second }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "scroll":
            self = .scroll(lines: try c.decodeIfPresent(Int32.self, forKey: .lines))
        case "keyChord":
            self = .keyChord(key: try c.decode(CGKeyCode.self, forKey: .key),
                             mods: try c.decodeIfPresent([String].self, forKey: .mods) ?? [],
                             label: try c.decodeIfPresent(String.self, forKey: .label))
        case "sequence":
            self = .sequence(steps: try c.decode([SeqStep].self, forKey: .steps))
        case "aux":
            self = .aux(key: try c.decode(AuxKey.self, forKey: .key))
        case "launchApp":
            self = .launchApp(bundleId: try c.decode(String.self, forKey: .bundleId))
        case "openURL":
            self = .openURL(url: try c.decode(String.self, forKey: .url))
        case "openPath":
            self = .openPath(path: try c.decode(String.self, forKey: .path))
        case "quitApp":
            self = .quitApp(bundleId: try c.decode(String.self, forKey: .bundleId),
                            force: try c.decodeIfPresent(Bool.self, forKey: .force))
        case "hotkeySwitch":
            self = .hotkeySwitch(first: try c.decodeIfPresent(KeyChordSpec.self, forKey: .first),
                                 second: try c.decodeIfPresent(KeyChordSpec.self, forKey: .second))
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "unknown action type \"\(type)\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scroll(let lines):
            try c.encode("scroll", forKey: .type)
            try c.encodeIfPresent(lines, forKey: .lines)
        case .keyChord(let key, let mods, let label):
            try c.encode("keyChord", forKey: .type)
            try c.encode(key, forKey: .key)
            try c.encode(mods, forKey: .mods)
            try c.encodeIfPresent(label, forKey: .label)
        case .sequence(let steps):
            try c.encode("sequence", forKey: .type)
            try c.encode(steps, forKey: .steps)
        case .aux(let key):
            try c.encode("aux", forKey: .type)
            try c.encode(key, forKey: .key)
        case .launchApp(let bundleId):
            try c.encode("launchApp", forKey: .type)
            try c.encode(bundleId, forKey: .bundleId)
        case .openURL(let url):
            try c.encode("openURL", forKey: .type)
            try c.encode(url, forKey: .url)
        case .openPath(let path):
            try c.encode("openPath", forKey: .type)
            try c.encode(path, forKey: .path)
        case .quitApp(let bundleId, let force):
            try c.encode("quitApp", forKey: .type)
            try c.encode(bundleId, forKey: .bundleId)
            try c.encodeIfPresent(force, forKey: .force)
        case .hotkeySwitch(let first, let second):
            try c.encode("hotkeySwitch", forKey: .type)
            try c.encodeIfPresent(first, forKey: .first)
            try c.encodeIfPresent(second, forKey: .second)
        case .none:
            try c.encode("none", forKey: .type)
        }
    }
}

struct LayerConfig: Codable {
    var name: String
    var twistL: Action?
    var twistR: Action?
    var holdTwistL: Action?
    var holdTwistR: Action?
    var press: Action?

    func action(for g: Gesture) -> Action? {
        switch g {
        case .twistL:     return twistL
        case .twistR:     return twistR
        case .holdTwistL: return holdTwistL
        case .holdTwistR: return holdTwistR
        case .press:      return press
        }
    }
}

// A recorded keyboard chord (the optional layer-switch hotkeys). The label is
// what the UI shows (e.g. "F6"); the engine matches on key + mods only.
struct KeyChordSpec: Codable, Equatable {
    var key: CGKeyCode
    var mods: [String]
    var label: String?
}

struct Config: Codable {
    var layers: [LayerConfig]
    var doubleTapSwitch: Bool?         // default true; off → press acts instantly
    var doubleTapWindow: TimeInterval?
    var layerHotkey: KeyChordSpec?     // optional keyboard chord → next layer
    var layerHotkeyBack: KeyChordSpec? // optional keyboard chord → previous layer
    var scrollLinesPerDetent: Int32?

    var doubleTapEnabled: Bool { doubleTapSwitch ?? true }
    var tapWindow: TimeInterval { doubleTapWindow ?? 0.25 }
    var defaultScrollLines: Int32 { scrollLinesPerDetent ?? 3 }
}

// The default config replicates the POC behavior exactly.
let defaultConfig = Config(
    layers: [
        LayerConfig(name: "Navigate",
                    twistL: .scroll(lines: 3),                        // scroll up
                    twistR: .scroll(lines: -3),                       // scroll down
                    holdTwistL: .keyChord(key: 27, mods: ["cmd"], label: "−"), // ⌘− zoom out
                    holdTwistR: .keyChord(key: 24, mods: ["cmd"], label: "="), // ⌘= zoom in
                    press: .sequence(steps: [
                        SeqStep(key: 126, mods: ["cmd"], delayMs: 50), // ⌘↑ (top), wait
                        SeqStep(key: 29, mods: ["cmd"]),               // ⌘0 (reset zoom)
                    ])),
        LayerConfig(name: "Media",
                    twistL: .aux(key: .volumeDown),
                    twistR: .aux(key: .volumeUp),
                    holdTwistL: .aux(key: .brightnessDown),
                    holdTwistR: .aux(key: .brightnessUp),
                    press: .aux(key: .mute)),
    ],
    doubleTapSwitch: true, doubleTapWindow: 0.25,
    layerHotkey: nil, layerHotkeyBack: nil,
    scrollLinesPerDetent: 3)

// ---- config load/save ------------------------------------------------------

let configURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("vk01d/config.json")

var config = defaultConfig
var configError: String?     // non-nil → ⚠ in the menu; last good config stays live

struct ConfigError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

func writeDefaultConfig() {
    do {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(defaultConfig).write(to: configURL)
        log("wrote default config → \(configURL.path)")
    } catch {
        NSLog("vk01d: couldn't write default config: \(error)")
    }
}

// Defensive by design: any failure keeps the last good config in memory and
// surfaces a warning — the tap must never die over a bad edit.
func loadConfig() {
    do {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            writeDefaultConfig()                       // first launch
            config = defaultConfig
            configError = nil
            return
        }
        let parsed = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        guard !parsed.layers.isEmpty else { throw ConfigError(msg: "config has no layers") }
        config = parsed
        configError = nil
    } catch {
        configError = String(describing: error)
        NSLog("vk01d: config load failed — keeping last good config: \(error)")
    }
    if layer > config.layers.count { layer = 1 }       // clamp after a reload
}

// Instant-apply path for the settings UI: swap the live config, persist it to
// disk, and refresh the menu bar. Called on every edit in the Settings window.
func applyConfig(_ newConfig: Config) {
    config = newConfig
    hotkeyToggleState.removeAll()
    if layer > config.layers.count { layer = 1 }
    do {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: configURL)
        configError = nil
    } catch {
        NSLog("vk01d: config save failed: \(error)")
    }
    delegate.rebuildMenu()
    updateUI()
}

// ---- state -----------------------------------------------------------------

var layer = 1
var pendingPress: DispatchWorkItem?   // armed single press (double-tap window)
var tapPort: CFMachPort?

func log(_ s: String) { if verbose { print(s) } }

// ---- menu bar UI -------------------------------------------------------------

var statusItem: NSStatusItem!
var layerMenuItems: [NSMenuItem] = []
var loginItem: NSMenuItem?
var retryItem: NSMenuItem?
var configWarnItem: NSMenuItem?

func setLayer(_ n: Int) {
    layer = max(1, min(n, config.layers.count))
    log("→ Layer \(layer) (\(config.layers[layer - 1].name))")
    updateUI()
}

// Cycle the layer by ±1 with wraparound — the rolodex.
func cycleLayer(_ delta: Int) {
    let n = config.layers.count
    setLayer(((layer - 1 + delta) % n + n) % n + 1)
}

func updateUI() {
    let symbol = tapPort == nil ? "exclamationmark.triangle.fill"
               : configError != nil ? "exclamationmark.circle"
               : "\(layer).circle.fill"
    statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                       accessibilityDescription: "VK-01 layer \(layer)")
    retryItem?.isHidden = (tapPort != nil)
    configWarnItem?.isHidden = (configError == nil)
    configWarnItem?.toolTip = configError
    for (i, item) in layerMenuItems.enumerated() { item.state = (i + 1 == layer) ? .on : .off }
}

// ---- synthetic output ------------------------------------------------------

let src = CGEventSource(stateID: .hidSystemState)

func postScroll(_ lines: Int32) {
    CGEvent(scrollWheelEvent2Source: src, units: .line,
            wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
}

func postKey(_ keycode: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: keycode, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}

// NX_KEYTYPE_* aux keys (volume/mute/media) — systemDefined subtype-8 events;
// these drive the real system behavior including the on-screen HUD.
let NX_SOUND_UP = 0, NX_SOUND_DOWN = 1, NX_MUTE = 7
let NX_PLAY = 16, NX_NEXT = 17, NX_PREVIOUS = 18

func postAuxKey(_ key: Int) {
    for down in [true, false] {
        let d1 = (key << 16) | ((down ? 0x0A : 0x0B) << 8)
        NSEvent.otherEvent(with: .systemDefined, location: .zero,
                           modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                           timestamp: 0, windowNumber: 0, context: nil,
                           subtype: 8, data1: d1, data2: -1)?
            .cgEvent?.post(tap: .cghidEventTap)
    }
}

// ---- engine ------------------------------------------------------------------
// Runs one configured action. The machinery below (postScroll/postKey/postAuxKey)
// is the POC's, unchanged; only the dispatch is config-driven now.

func modFlags(_ mods: [String]?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in mods ?? [] {
        switch m.lowercased() {
        case "cmd", "command":       f.insert(.maskCommand)
        case "shift":                f.insert(.maskShift)
        case "opt", "option", "alt": f.insert(.maskAlternate)
        case "ctrl", "control":      f.insert(.maskControl)
        case "fn", "function":       f.insert(.maskSecondaryFn)
        default: NSLog("vk01d: unknown modifier \"\(m)\" ignored")
        }
    }
    return f
}

// hotkeySwitch remembers which of its two chords fires next, per layer+gesture
// slot. Reset whenever the config changes (bindings may have moved around).
var hotkeyToggleState: [String: Bool] = [:]

func run(_ action: Action?, stateKey: String = "") {
    guard let action else { return }
    switch action {
    case .scroll(let lines):
        postScroll(lines ?? config.defaultScrollLines)
    case .keyChord(let key, let mods, _):
        postKey(key, flags: modFlags(mods))
    case .sequence(let steps):
        var delay: TimeInterval = 0
        for step in steps {
            if let key = step.key {
                let f = modFlags(step.mods)
                if delay <= 0 { postKey(key, flags: f) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { postKey(key, flags: f) } }
            }
            if let ms = step.delayMs { delay += TimeInterval(ms) / 1000 }
        }
    case .aux(let key):
        key.post()
    case .launchApp(let bundleId):
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSLog("vk01d: no app installed for bundle id \"\(bundleId)\"")
        }
    case .openURL(let s):
        if let url = URL(string: s), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSLog("vk01d: openURL: \"\(s)\" is not a loadable URL")
        }
    case .openPath(let path):
        NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    case .quitApp(let bundleId, let force):
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if apps.isEmpty { NSLog("vk01d: quitApp: \"\(bundleId)\" is not running") }
        for app in apps { _ = (force ?? false) ? app.forceTerminate() : app.terminate() }
    case .hotkeySwitch(let first, let second):
        let useSecond = hotkeyToggleState[stateKey] ?? false
        hotkeyToggleState[stateKey] = !useSecond
        // fall back to whichever chord is recorded so a half-configured
        // switch still does something sensible
        if let chord = (useSecond ? second : first) ?? (useSecond ? first : second) {
            postKey(chord.key, flags: modFlags(chord.mods))
        } else {
            NSLog("vk01d: hotkeySwitch: no hotkeys recorded")
        }
    case .none:
        break
    }
}

func runPress() {
    log("L\(layer) press")
    run(config.layers[layer - 1].press, stateKey: "L\(layer).press")
}

func handle(_ code: Int64) {
    guard let g = gesture(for: code) else { return }
    guard g == .press else {
        log("L\(layer) \(g.rawValue)")
        run(config.layers[layer - 1].action(for: g), stateKey: "L\(layer).\(g.rawValue)")
        return
    }
    guard config.doubleTapEnabled else { runPress(); return }  // double-tap off → act instantly
    if pendingPress != nil {                                   // 2nd tap in window → next layer
        pendingPress?.cancel(); pendingPress = nil
        cycleLayer(1)                                          // cycle (= toggle with 2 layers)
    } else {
        let work = DispatchWorkItem { pendingPress = nil; runPress() }
        pendingPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.tapWindow, execute: work)
    }
}

// ---- event tap -----------------------------------------------------------------

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if knobKeys.contains(code), event.flags.contains(requiredMods) {
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { handle(code) }
        }
        return nil                                             // swallow chord (down AND up)
    }
    // optional layer-switch hotkeys (recorded in Settings; must carry modifiers)
    for (hk, delta) in [(config.layerHotkey, 1), (config.layerHotkeyBack, -1)] {
        guard let hk, !hk.mods.isEmpty, code == Int64(hk.key),
              event.flags.contains(modFlags(hk.mods)) else { continue }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { cycleLayer(delta) }
        }
        return nil                                             // swallow (down AND up)
    }
    return Unmanaged.passUnretained(event)                     // not ours — pass through
}

func startTap() {
    // Trigger the Accessibility prompt if not yet trusted (needed to post/modify events).
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

    let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
             | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: callback, userInfo: nil) else {
        NSLog("vk01d: event tap creation failed — permissions missing; showing ⚠️ + Retry")
        updateUI()             // ⚠️ icon + Retry menu item; app keeps running
        return
    }
    tapPort = tap
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    updateUI()                 // back to the ①/② layer icon
    log("vk01d running — Layer \(layer)")
}

// ---- app ------------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        loadConfig()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        updateUI(); startTap()
    }

    // Rebuilt from the config (layer names/count) on launch and on every reload.
    // No key equivalents anywhere: in a menu-bar-only app they only fire while
    // the menu is open, so showing them would advertise shortcuts that don't exist.
    func rebuildMenu() {
        menu.removeAllItems()
        layerMenuItems = []
        for (i, l) in config.layers.enumerated() {
            let item = NSMenuItem(title: "Layer \(i + 1) — \(l.name)",
                                  action: #selector(pickLayer(_:)), keyEquivalent: "")
            item.tag = i + 1; item.target = self
            layerMenuItems.append(item); menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)),
                                  keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        let warn = NSMenuItem(title: "Config error — using last good config",
                              action: nil, keyEquivalent: "")
        warn.isEnabled = false             // info only; details in tooltip + Console
        configWarnItem = warn; menu.addItem(warn)
        let openCfg = NSMenuItem(title: "Open Config File", action: #selector(openConfig(_:)),
                                 keyEquivalent: "")
        openCfg.target = self; menu.addItem(openCfg)
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig(_:)),
                                keyEquivalent: "")
        reload.target = self; menu.addItem(reload)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin(_:)),
                               keyEquivalent: "")
        login.target = self; loginItem = login; menu.addItem(login)
        let retry = NSMenuItem(title: "Permissions missing — grant both, then click to retry",
                               action: #selector(retryTap(_:)), keyEquivalent: "")
        retry.target = self; retryItem = retry; menu.addItem(retry)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit vk01d",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        updateLoginState()
    }

    @objc func pickLayer(_ sender: NSMenuItem) { setLayer(sender.tag) }

    @objc func retryTap(_ sender: NSMenuItem) { startTap() }

    @objc func openSettings(_ sender: NSMenuItem) { SettingsWindowController.show() }

    @objc func openConfig(_ sender: NSMenuItem) {
        if !FileManager.default.fileExists(atPath: configURL.path) { writeDefaultConfig() }
        NSWorkspace.shared.open(configURL)
    }

    @objc func reloadConfig(_ sender: NSMenuItem) {
        loadConfig()
        rebuildMenu()
        updateUI()
        log(configError == nil ? "config reloaded — \(config.layers.count) layer(s)"
                               : "config reload FAILED — kept last good config")
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item toggle failed: \(error)") }
        updateLoginState()
    }

    func updateLoginState() {
        loginItem?.isEnabled = Bundle.main.bundleIdentifier != nil   // needs the .app bundle
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let delegate = AppDelegate()

// @main (not top-level statements) because the app is now two source files —
// SettingsUI.swift holds the settings window.
@main
struct VK01D {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
        app.delegate = delegate
        app.run()
    }
}
