# VK-01 (Anticater) custom control

Host-side control for an **Anticater VK-01** desktop volume knob. Open/custom firmware is
not possible (MCU is a blind-marked **Jieli** part — no ZMK/QMK), so the knob is driven
with a **"bind once + translate"** architecture: the knob's five native slots are bound
once (via the vendor app) to fixed chords **⌃⌥ F16–F20**, and a macOS menu bar daemon
(`vk01d.app`) swallows those chords with a CGEventTap and runs configurable, layered
actions in their place. No firmware replacement.

## Device
- VID `0x514C` (LQKJ) / PID `0x8850`
- Config interface: vendor HID, **Usage Page `0xFF00`, Report ID `0x03`, 64-byte OUT/IN**
- Known opcodes: `0xFE 0xFD` sync/handshake · `0xEF 0x03`/`0xEF 0xEF` save/commit ·
  `0xFE 0xB0 …` RGB set
- The vendor protocol is only needed for the one-time slot binding; day-to-day behavior
  is entirely host-side.

## Contents
- `vk01d.swift` — the daemon: event tap, config engine, layer switching, synthetic output.
- `SettingsUI.swift` — native SwiftUI settings window (hosted by the daemon).
- `build.sh` — builds and signs `vk01d.app` (stable identity, so rebuilds keep TCC grants).
- `chordcheck.swift` — tiny tap logger used to verify what the knob actually sends.
- `probe.swift` — read-only IOKit probe for the vendor HID config interface.
  Build: `swiftc probe.swift -o probe`, run `./probe`.
- `mac.EN/` — vendor's macOS app + manual (config-protocol reference). Not included in this
  repo (proprietary, ours to use but not to redistribute) — get it from the vendor and drop
  it in `mac.EN/` locally if you want to re-extract with `pkgutil --expand`.
- `DESIGN.md` — design document (architecture, config schema, action vocabulary, UI language).

## How it works
- **Gestures:** twist L/R, hold+twist L/R, press — one action per gesture per layer.
- **Layers:** any number; each is a named tab in Settings. Switch by double-tapping the
  knob (cycles), via two recordable keyboard hotkeys (next/previous), or from the menu
  bar menu. The menu bar icon shows the current layer number.
- **Actions:** scroll · keystroke · keystroke sequence (with waits) · media keys
  (volume/mute/play/next/previous) · brightness up/down · open app / file / folder /
  website · quit app (optionally force) · hotkey switch (two chords, alternating).
- **Config:** `~/Library/Application Support/vk01d/config.json`, edited by the Settings
  window (instant apply, transient "Saved" badge) or by hand + menu → Reload Config.

## Build & run
```sh
./build.sh        # builds + signs vk01d.app
open vk01d.app
```
Grant **Accessibility** and **Input Monitoring** on first run. Rebuilds keep the grants
(stable signing identity); changing the bundle id would reset them.

**Brightness prerequisite:** the brightness actions synthesize F14/F15 keystrokes, so
System Settings → Keyboard → Keyboard Shortcuts… → **Display** must have
"Decrease/Increase display brightness" enabled and bound to F14/F15 (the default for
those legacy keys). This routes to built-in and supported external displays alike.

## Status
- **v0.2** — config engine + native settings window + full action vocabulary (current).
- `v0.1-poc` — hardcoded 2-layer proof of concept.
- Vendor-protocol notes: config **write** path confirmed by probe; read-back unverified
  (not needed for this architecture).
