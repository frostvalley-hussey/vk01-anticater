// vk01d.swift — VK-01 knob daemon, menu bar edition.
// Translates the knob's ⌃⌥+F16–F20 chords into layered actions.
// Layer 1: scroll / ⌘± zoom / ⌘↑→⌘0. Layer 2: volume / brightness / mute.
// Double-tap the knob button (or use the menu) to switch layers; the menu bar
// icon (①/②) shows the current layer.
// Build the app bundle with ./build.sh, launch with `open vk01d.app`.
// Needs Accessibility + Input Monitoring granted to vk01d (prompts on first run).

import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// ---- configuration ---------------------------------------------------------

let requiredMods: CGEventFlags = [.maskControl, .maskAlternate]   // what the VK-01 sends
let kTwistL: Int64 = 106, kPress: Int64 = 64, kTwistR: Int64 = 79 // F16, F17, F18
let kHoldTwistL: Int64 = 80, kHoldTwistR: Int64 = 90              // F19, F20
let knobKeys: Set<Int64> = [kTwistL, kPress, kTwistR, kHoldTwistL, kHoldTwistR]

let scrollLinesPerDetent: Int32 = 3
let doubleTapWindow: TimeInterval = 0.25
let verbose = CommandLine.arguments.contains("-v")

// ---- state -----------------------------------------------------------------

var layer = 1
var pendingPress: DispatchWorkItem?
var tapPort: CFMachPort?

func log(_ s: String) { if verbose { print(s) } }

// ---- menu bar UI -------------------------------------------------------------

var statusItem: NSStatusItem!
var layerMenuItems: [NSMenuItem] = []
var loginItem: NSMenuItem?
var retryItem: NSMenuItem?

func setLayer(_ n: Int) {
    layer = n
    log("→ Layer \(n)")
    updateUI()
}

func updateUI() {
    let symbol = tapPort == nil ? "exclamationmark.triangle.fill"
               : (layer == 1 ? "1.circle.fill" : "2.circle.fill")
    statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                       accessibilityDescription: "VK-01 layer \(layer)")
    retryItem?.isHidden = (tapPort != nil)
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

// NX_KEYTYPE_* aux keys (volume/brightness/mute) — systemDefined subtype-8 events;
// these drive the real system behavior including the on-screen HUD.
let NX_SOUND_UP = 0, NX_SOUND_DOWN = 1, NX_MUTE = 7
let NX_BRIGHT_UP = 2, NX_BRIGHT_DOWN = 3

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

// ---- actions -----------------------------------------------------------------

func singlePress() {
    if layer == 1 {
        log("press L1: ⌘↑ then ⌘0")
        postKey(126, flags: .maskCommand)                      // ⌘↑ (go to top)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postKey(29, flags: .maskCommand)                   // ⌘0 (reset zoom)
        }
    } else {
        log("press L2: mute")
        postAuxKey(NX_MUTE)
    }
}

func handle(_ code: Int64) {
    switch (layer, code) {
    case (1, kTwistL):     log("L1 scroll up");      postScroll(+scrollLinesPerDetent)
    case (1, kTwistR):     log("L1 scroll down");    postScroll(-scrollLinesPerDetent)
    case (1, kHoldTwistL): log("L1 zoom out ⌘−");    postKey(27, flags: .maskCommand)  // ⌘-
    case (1, kHoldTwistR): log("L1 zoom in ⌘+");     postKey(24, flags: .maskCommand)  // ⌘=
    case (2, kTwistL):     log("L2 volume down");    postAuxKey(NX_SOUND_DOWN)
    case (2, kTwistR):     log("L2 volume up");      postAuxKey(NX_SOUND_UP)
    case (2, kHoldTwistL): log("L2 brightness down"); postAuxKey(NX_BRIGHT_DOWN)
    case (2, kHoldTwistR): log("L2 brightness up");  postAuxKey(NX_BRIGHT_UP)
    case (_, kPress):
        if pendingPress != nil {                               // 2nd tap in window → toggle layer
            pendingPress?.cancel(); pendingPress = nil
            setLayer(layer == 1 ? 2 : 1)
        } else {
            let work = DispatchWorkItem { pendingPress = nil; singlePress() }
            pendingPress = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        }
    default: break
    }
}

// ---- event tap -----------------------------------------------------------------

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    guard knobKeys.contains(code), event.flags.contains(requiredMods) else {
        return Unmanaged.passUnretained(event)                 // not the knob — pass through
    }
    if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        DispatchQueue.main.async { handle(code) }
    }
    return nil                                                 // swallow chord (down AND up)
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
    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (tag, title) in [(1, "Layer 1 — scroll / zoom"), (2, "Layer 2 — volume / brightness")] {
            let item = NSMenuItem(title: title, action: #selector(pickLayer(_:)), keyEquivalent: "")
            item.tag = tag; item.target = self
            layerMenuItems.append(item); menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; loginItem = login; menu.addItem(login)
        let retry = NSMenuItem(title: "Permissions missing — grant both, then click to retry",
                               action: #selector(retryTap(_:)), keyEquivalent: "")
        retry.target = self; retryItem = retry; menu.addItem(retry)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit vk01d", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        updateLoginState(); updateUI(); startTap()
    }

    @objc func pickLayer(_ sender: NSMenuItem) { setLayer(sender.tag) }

    @objc func retryTap(_ sender: NSMenuItem) { startTap() }

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
