# VK-01 (Anticater) custom control

Host-side control for an **Anticater VK-01** desktop volume knob. Open/custom firmware is
not possible (MCU is a blind-marked **Jieli** part — no ZMK/QMK), so the approach is to drive
the knob through its **vendor HID config protocol** plus a macOS host daemon for app-aware,
layered behavior. No firmware replacement.

## Device
- VID `0x514C` (LQKJ) / PID `0x8850`
- Config interface: vendor HID, **Usage Page `0xFF00`, Report ID `0x03`, 64-byte OUT/IN**
- Known opcodes: `0xFE 0xFD` sync/handshake · `0xEF 0x03`/`0xEF 0xEF` save/commit ·
  `0xFE 0xB0 …` RGB set

## Contents
- `probe.swift` — read-only IOKit probe: opens the config interface, sends the handshake,
  prints any reply. No settings writes. Build: `swiftc probe.swift -o probe`, run `./probe`.
- `mac.EN/Mac.pkg` — vendor macOS app (reference / config-protocol source; re-extract with
  `pkgutil --expand`).
- `mac.EN/User Manual.pdf` — vendor manual.

## Design (2-layer knob)
- **Switch layers:** double-tap (provisional; long-press is the lower-latency alternative)
- **Layer 1:** twist = scroll · hold+twist = zoom · press = ⌘↑ → ⌘0 (top, then reset zoom)
- **Layer 2:** twist = volume · hold+twist = brightness (F14/F15) · press = mute
- No LED indicator.

## Status
Teardown + protocol decode done. Probe confirms the config **write** path works; config
**read-back** is still unverified. Next: decode the `Set_Keyboard_*` remap payload, then the
config tool + host daemon.
