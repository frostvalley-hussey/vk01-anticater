# vk01d Phase 2 — customizable layers & actions

Design for turning the hardcoded 2-layer POC (`vk01d.swift`) into a config-driven,
user-customizable app. Written so implementation can start cold from this document.

## Where the POC stands

- `vk01d.swift` is a single-file AppKit menu bar app. The event tap matches the knob's
  five chords (⌃⌥ + F16–F20, keycodes 106 / 64 / 79 / 80 / 90) and swallows them.
- All behavior is hardcoded in two places: the constants block at the top and the
  `switch (layer, code)` in `handle()`. Layer switching = double-tap on press
  (0.25 s window). Everything else (tap lifecycle, synthetic output helpers
  `postScroll` / `postKey` / `postAuxKey`, menu bar UI, login item) is generic and stays.

## Architecture: engine + config

Split into an **engine** (unchanged runtime machinery) and a **config** (data). The
`handle()` switch becomes a lookup: `config.layers[current].action(for: gesture).run()`.

### Config model

Stored as JSON at `~/Library/Application Support/vk01d/config.json`. `Codable` structs;
on first launch (or if the file is missing/corrupt) write a default config that
replicates the POC behavior exactly.

```json
{
  "layers": [
    { "name": "Navigate",
      "twistL":     { "type": "scroll", "lines": 3 },
      "twistR":     { "type": "scroll", "lines": -3 },
      "holdTwistL": { "type": "keyChord", "key": 27, "mods": ["cmd"] },
      "holdTwistR": { "type": "keyChord", "key": 24, "mods": ["cmd"] },
      "press":      { "type": "sequence", "steps": [
                      { "key": 126, "mods": ["cmd"] },
                      { "delayMs": 50 },
                      { "key": 29,  "mods": ["cmd"] } ] } },
    { "name": "Media",
      "twistL":     { "type": "aux", "key": "volumeDown" },
      "twistR":     { "type": "aux", "key": "volumeUp" },
      "holdTwistL": { "type": "aux", "key": "brightnessDown" },
      "holdTwistR": { "type": "aux", "key": "brightnessUp" },
      "press":      { "type": "aux", "key": "mute" } }
  ],
  "layerSwitch": "doubleTap",
  "doubleTapWindow": 0.25,
  "scrollLinesPerDetent": 3
}
```

### Action vocabulary

| type       | params                              | engine call                          |
|------------|-------------------------------------|--------------------------------------|
| `scroll`   | `lines` (signed)                    | `postScroll`                         |
| `keyChord` | `key` (CG keycode), `mods`          | `postKey`                            |
| `sequence` | array of key steps / `delayMs`      | chained `postKey` via `asyncAfter`   |
| `aux`      | volumeUp/Down, mute, brightnessUp/Down, playPause, next, previous | `postAuxKey` (NX aux keys; play/pause=16, next=17, prev=18 come free with the same mechanism) |
| `launchApp`| `bundleId`                          | `NSWorkspace.openApplication`        |
| `none`     | —                                   | no-op                                |

### Layers & switching

- `layers` is an array — 3+ layers fall out naturally. Menu bar icon shows the layer
  number; menu lists layers by `name`.
- `layerSwitch` modes: `doubleTap` (cycle; keeps the 0.25 s single-press delay),
  `longPress` (no delay tax on single press), `hyperArrows` (⌃⌥⇧⌘ + ←/→ from the
  keyboard as direct select — the tap must swallow those chords too).

## Milestones (each sized to one session)

1. **Config-driven engine.** Extract `Config`/`Layer`/`Action` Codable types; load/save
   JSON; default config = POC behavior; menu items "Open Config File" and "Reload
   Config"; layer menu generated from config. No visible behavior change. TextEdit is
   the UI for this milestone.
2. **Full vocabulary.** `sequence`, `launchApp`, media aux keys, N layers, the three
   `layerSwitch` modes.
3. **Settings window.** SwiftUI window hosted by the existing app (an `LSUIElement`
   app can present windows; activate the app when opening it). One tab per layer;
   five rows (twist L/R, hold+twist L/R, press); each row = action-type popup +
   parameter fields. The main build item is a **key-chord recorder** field ("click,
   then press a shortcut") for `keyChord`/`sequence` — capture the next keyDown via a
   local NSEvent monitor. Writes to the same config.json, engine reloads on save.
   Must follow the "Settings UI design language" section below.
4. **Polish (optional).** Per-app overrides (frontmost-app bundle id → layer/action
   overrides via `NSWorkspace` notifications), preset import/export, editable layer
   names in the UI.

## Settings UI design language

Target feel: indistinguishable from a pane Apple shipped in System Settings on
macOS 26 (Tahoe) — Liquid Glass, minimal, with one tasteful skeuomorphic touch.

- **Build against the macOS 26 SDK.** Standard SwiftUI controls adopt Liquid Glass
  automatically. Never hand-roll materials, colors, or fonts: system controls,
  system accent color, SF Symbols only. "Apple-built" comes from restraint.
- **Structure = System Settings idiom:** `Form` + `.formStyle(.grouped)`,
  `LabeledContent` rows, a segmented or sidebar layer picker.
- **Glass is for the floating layer, not content** (Apple's own guidance): apply
  `.glassEffect()` / `GlassEffectContainer` sparingly — the gesture-picker overlay,
  the chord-recorder capsule — never slathered over whole panes.
- **Skeuomorphic centerpiece:** a rendered VK-01 knob as the pane header; click a
  gesture zone (twist arrows, crown press, hold+twist) to select and edit it —
  the way Apple's Trackpad pane illustrates each gesture. Selected zone glows
  with the accent color; the action editor appears beneath.
- **Chord recorder** styled after System Settings → Keyboard Shortcuts: a capsule
  showing glyphs (⌃⌥F16), click to arm, Esc to cancel.
- Free wins to preserve by using only system controls: dark/light appearance,
  vibrancy, Dynamic Type, VoiceOver, reduced-transparency mode.

## Gotchas the implementation must respect

- The five chords are ground truth: keycode ∈ {106, 64, 79, 80, 90} with ⌃⌥. They are
  bound in the knob's own flash; nothing on the host can change them (and nothing
  should — the vendor app is the only writer we use).
- Autorepeat is already filtered in the tap callback; keep that.
- `doubleTap` mode inherently delays single-press actions by the tap window; surface
  that in the UI copy so it doesn't read as a bug.
- Rebuilds don't invalidate TCC grants (stable signing identity via build.sh), so
  iterate freely — but a bundle-id change WOULD reset permissions.
- Config load must be defensive: on parse failure keep the last good config in memory,
  show a menu bar warning state, never crash the tap.

## Git workflow

- `main` = always-working app. Tag `v0.1-poc` marks the pre-config POC.
- Implementation happens on the `feature/config-ui` branch
  (`git switch feature/config-ui`), pushed to GitHub as backup; merge into `main`
  when a milestone leaves the app working end-to-end.
