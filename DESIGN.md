# vk01d Phase 2 — customizable layers & actions

Design for turning the hardcoded 2-layer POC (`vk01d.swift`) into a config-driven,
user-customizable app. **Shipped as `v0.2`** — this document now describes the design
as built (milestones 1–3 plus the post-milestone iteration round).

## Where the POC stood

- `vk01d.swift` is a single-file AppKit menu bar app. The event tap matches the knob's
  five chords (⌃⌥ + F16–F20, keycodes 106 / 64 / 79 / 80 / 90) and swallows them.
- All behavior was hardcoded in two places: the constants block at the top and the
  `switch (layer, code)` in `handle()`. Layer switching = double-tap on press
  (0.25 s window). Everything else (tap lifecycle, synthetic output helpers
  `postScroll` / `postKey` / `postAuxKey`, menu bar UI, login item) is generic and stayed.

## Architecture: engine + config

Split into an **engine** (unchanged runtime machinery) and a **config** (data). The
`handle()` switch became a lookup: `run(config.layers[current].action(for: gesture))`.

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
      "holdTwistL": { "type": "keyChord", "key": 27, "mods": ["cmd"], "label": "-" },
      "holdTwistR": { "type": "keyChord", "key": 24, "mods": ["cmd"], "label": "=" },
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
  "doubleTapSwitch": true,
  "doubleTapWindow": 0.25,
  "layerHotkey":     { "key": 97, "mods": ["cmd", "opt"], "label": "F6" },
  "layerHotkeyBack": { "key": 96, "mods": ["cmd", "opt"], "label": "F5" },
  "scrollLinesPerDetent": 3
}
```

`label` fields are display-only (what the UI shows for a recorded key); the engine
matches and posts on `key` + `mods` alone. `layerHotkey` / `layerHotkeyBack` are
optional recorded chords for next / previous layer.

### Action vocabulary

| type           | params                                   | engine call                          |
|----------------|------------------------------------------|--------------------------------------|
| `scroll`       | `lines` (signed)                         | `postScroll`                         |
| `keyChord`     | `key` (CG keycode), `mods`, `label`      | `postKey`                            |
| `sequence`     | array of key steps / `delayMs` waits     | chained `postKey` via `asyncAfter`   |
| `aux`          | volumeUp/Down, mute, playPause, next, previous | `postAuxKey` (NX aux keys — system behavior + HUD) |
| `aux`          | brightnessUp/Down                        | `postKey(113/107, .maskSecondaryFn)` — fn-flagged F15/F14, routes to built-in and supported external displays (NX brightness only reached the built-in panel and was dropped; `brightnessUp/DownExternal` decode as aliases) |
| `launchApp`    | `bundleId`                               | `NSWorkspace.openApplication`        |
| `openURL`      | `url`                                    | `NSWorkspace.open` (scheme-guarded)  |
| `openPath`     | `path` (`~` expanded)                    | `NSWorkspace.open(fileURL)`          |
| `quitApp`      | `bundleId`, `force`                      | `NSRunningApplication.terminate()` / `forceTerminate()` on all instances |
| `hotkeySwitch` | `first`, `second` (recorded chords)      | alternates per trigger; state keyed per layer+gesture slot, reset on config change |
| `none`         | —                                        | no-op                                |

### Layers & switching

- `layers` is an array — 3+ layers fall out naturally. Menu bar icon shows the layer
  number; menu and settings tabs list layers by `name`; tabs drag to reorder.
- Switching: `doubleTapSwitch` (cycle; keeps the 0.25 s single-press delay — can be
  disabled, making press instant) plus the two optional recorded hotkeys (next /
  previous, cycling rolodex-style).
- *Dropped:* `longPress` and `hyperArrows` switch modes were built in milestone 2 and
  cut — double-tap + hotkeys covered every real use without the extra tap-state
  machinery. Don't re-add without a concrete need.

## Milestones (as shipped)

1. **Config-driven engine** — `a8afcae`. Codable types, defensive load/save, default
   config = POC behavior, menu items "Open Config File" / "Reload Config".
2. **Full vocabulary** — `6a0155d`. `sequence`, `launchApp`, media aux keys, N layers.
3. **Settings window** — `e392f8a`, then iterated to the shipped form (`004f2d8`…):
   horizontal tab strip (Switching ⋮ layer tabs ⋮ +) with drag-to-reorder, submenu
   action picker, key-chord recorders, sequence editor sheet (keystroke + wait rows),
   instant apply with a transient "Saved" badge, 720×680 window.
   Post-merge additions: fn-flagged brightness (`6e7835b`), open website/file/folder
   (`8386813`), quit app + hotkey switch (`61693fc`).
4. **Polish (open).** Per-app overrides (frontmost-app bundle id → layer/action
   overrides via `NSWorkspace` notifications), preset import/export, editable layer
   names in the UI.

## Settings UI design language

Target feel: indistinguishable from a pane Apple shipped in System Settings on
macOS 26 (Tahoe) — Liquid Glass, minimal, with one tasteful skeuomorphic touch.

- **Build against the macOS 26 SDK.** Standard SwiftUI controls adopt Liquid Glass
  automatically. Never hand-roll materials, colors, or fonts: system controls,
  system accent color, SF Symbols only. "Apple-built" comes from restraint.
- **Structure = System Settings idiom:** `Form` + `.formStyle(.grouped)`,
  `LabeledContent` rows, a horizontal tab strip as the layer picker (shipped form;
  the sidebar variant was tried first and replaced).
- **Glass is for the floating layer, not content** (Apple's own guidance): apply
  `.glassEffect()` / `GlassEffectContainer` sparingly — never slathered over whole panes.
- **Skeuomorphic centerpiece:** a rendered VK-01 knob as the pane header; click a
  gesture zone (twist arrows, crown press, hold+twist) to select and edit it —
  the way Apple's Trackpad pane illustrates each gesture. Selected zone glows
  with the accent color.
- **Chord recorder** styled after System Settings → Keyboard Shortcuts: a capsule
  showing glyphs (⌃⌥F16), click to arm, Esc to cancel.
- The menu bar menu carries **no key equivalents** — they'd only fire while the menu
  is open, which reads as false advertising.
- Free wins to preserve by using only system controls: dark/light appearance,
  vibrancy, Dynamic Type, VoiceOver, reduced-transparency mode.

## Gotchas the implementation must respect

- The five chords are ground truth: keycode ∈ {106, 64, 79, 80, 90} with ⌃⌥. They are
  bound in the knob's own flash; nothing on the host can change them (and nothing
  should — the vendor app is the only writer we use).
- **Synthetic brightness keys need the fn flag.** macOS registers the display-brightness
  symbolic hotkeys (AppleSymbolicHotKeys 53/54) as F14/F15 **+ 0x800000
  (`.maskSecondaryFn`)**; real F-key presses carry that flag implicitly, synthetic ones
  must set it or they silently never match. The held ⌃⌥ of the knob chord does not
  interfere once the event's flags are explicit.
- Autorepeat is already filtered in the tap callback; keep that.
- Double-tap mode inherently delays single-press actions by the tap window; surface
  that in the UI copy so it doesn't read as a bug.
- Rebuilds don't invalidate TCC grants (stable signing identity via build.sh), so
  iterate freely — but a bundle-id change WOULD reset permissions.
- Config load must be defensive: on parse failure keep the last good config in memory,
  show a menu bar warning state, never crash the tap.
- The config file is read at launch and written by the Settings window in-process
  (instant apply); external edits need menu → Reload Config.
- The sequence editor's row binding must preserve key-less, delay-less steps — they
  are the "unrecorded keystroke" rows; filtering them makes Add Keystroke a no-op.

## Git workflow

- `main` = always-working app. Tags: `v0.1-poc` (pre-config POC), `v0.2` (config
  engine + settings UI + full vocabulary).
- Phase 2 was implemented on `feature/config-ui` (merged `--no-ff` at `d474eff`),
  pushed to GitHub as backup; the same branch-per-phase pattern applies going forward.
