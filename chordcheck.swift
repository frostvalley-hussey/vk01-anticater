// chordcheck.swift — verify the VK-01's 5 hyper-chord bindings.
// Listen-only event tap; prints which knob slot fired. Exits after 45 s.
// Build & run:  swiftc chordcheck.swift -o chordcheck && ./chordcheck
// Needs Input Monitoring for your terminal (System Settings → Privacy & Security).

import CoreGraphics
import Foundation

let slots: [Int64: String] = [
    106: "twist-L       (F16)",   // kVK_F16
    64:  "press         (F17)",   // kVK_F17
    79:  "twist-R       (F18)",   // kVK_F18
    80:  "hold+twist-L  (F19)",   // kVK_F19
    90:  "hold+twist-R  (F20)",   // kVK_F20
]
var counts: [Int64: Int] = [:]

func mods(_ f: CGEventFlags) -> String {
    var s = ""
    if f.contains(.maskControl)   { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift)     { s += "⇧" }
    if f.contains(.maskCommand)   { s += "⌘" }
    return s.isEmpty ? "(none)" : s
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if let name = slots[code] {
            counts[code, default: 0] += 1
            print("\(name)  mods \(mods(event.flags))  #\(counts[code]!)\(isRepeat ? "  [AUTOREPEAT]" : "")")
        }
    }
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
    callback: callback, userInfo: nil
) else {
    print("Could not create event tap — grant Input Monitoring to your terminal")
    print("(System Settings → Privacy & Security → Input Monitoring), then re-run.")
    exit(1)
}
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("Listening 45 s — twist, press, and hold+twist the knob… (Ctrl+C to quit early)")
DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
    print("\n--- summary ---")
    for (code, name) in slots.sorted(by: { $0.key < $1.key }) {
        print("\(name): \(counts[code] ?? 0) events")
    }
    exit(0)
}
CFRunLoopRun()
