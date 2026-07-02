// probe.swift — read-only VK-01 config-interface probe.
// Opens the vendor HID interface (VID 0x514C / PID 0x8850, usage page 0xFF00),
// sends the 0xFE 0xFD handshake, and prints any reply. No settings writes.
// Build: swiftc probe.swift -o probe   Run: ./probe

import Foundation
import IOKit
import IOKit.hid

let VID = 0x514C, PID = 0x8850          // this VK-01
let REPORT_ID: CFIndex = 0x03           // vendor config report id
let LEN = 64                            // 64-byte OUT/IN

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

// passively print any input reports the device sends back
let onInput: IOHIDReportCallback = { _, _, _, _, reportID, report, len in
    let arr = Array(UnsafeBufferPointer(start: report, count: len))
    print("IN  id=\(reportID) len=\(len): \(hex(arr))")
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
let match: [String: Any] = [
    kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID,
    kIOHIDDeviceUsagePageKey: 0xFF00,   // vendor page, not the keyboard interface
]
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

guard IOHIDManagerOpen(mgr, 0) == kIOReturnSuccess else { print("open failed"); exit(1) }
guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = devs.first
else { print("no device matched VID 0x514C / PID 0x8850 / usage 0xFF00"); exit(2) }

let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: LEN)
IOHIDDeviceRegisterInputReportCallback(dev, buf, LEN, onInput, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

var out = [UInt8](repeating: 0, count: LEN)   // 64B payload, report id passed separately
out[0] = 0xFE; out[1] = 0xFD                   // handshake / sync
let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, REPORT_ID, out, LEN)
print("handshake SetReport(id 3, 0xFE 0xFD): " + (r == kIOReturnSuccess ? "OK" : String(format: "FAIL 0x%08x", r)))

print("listening 4s — twist/press the knob now if you want to catch input reports…")
let end = Date().addingTimeInterval(4)
while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.2, false) }
print("done (read-only; no config/settings writes)")
