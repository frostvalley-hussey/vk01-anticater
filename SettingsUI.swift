// SettingsUI.swift — the VK-01 settings window (SwiftUI, macOS 26 SDK).
// Tab strip across the top: Switching, then one tab per layer (drag a tab to
// reorder; right-click to move or delete it; + adds one). Grouped Form detail
// with a clickable knob header and chord-recorder capsules; sequences open an
// editor sheet; actions are picked from a categorized menu with submenus.
// Instant apply: every change goes through applyConfig() — config.json is
// written and the engine hot-reloads; there is no Save button.
// Only system controls, system accent, SF Symbols — no hand-rolled materials.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ---- window ------------------------------------------------------------------

enum SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        ConfigStore.shared.syncFromEngine()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "VK-01 Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsRoot())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// ---- store ---------------------------------------------------------------------
// Bridges the SwiftUI views to the engine's global config. Every mutation of
// `cfg` instantly applies + persists (except when syncing FROM the engine).

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    private var syncing = false

    @Published var cfg: Config = config {
        didSet {
            if !syncing {
                applyConfig(cfg)
                lastSaved = Date()
            }
        }
    }
    @Published var lastSaved: Date?   // drives the transient "Saved" badge

    func syncFromEngine() {
        syncing = true
        cfg = config
        syncing = false
    }
}

// UI conveniences over the engine's config types.
extension LayerConfig {
    subscript(g: Gesture) -> Action? {
        get { action(for: g) }
        set {
            switch g {
            case .twistL:     twistL = newValue
            case .twistR:     twistR = newValue
            case .holdTwistL: holdTwistL = newValue
            case .holdTwistR: holdTwistR = newValue
            case .press:      press = newValue
            }
        }
    }
}

extension KeyChordSpec {
    var display: String {
        var s = ""
        if mods.contains("ctrl")  { s += "⌃" }
        if mods.contains("opt")   { s += "⌥" }
        if mods.contains("shift") { s += "⇧" }
        if mods.contains("cmd")   { s += "⌘" }
        return s + (label ?? specialKeyNames[key] ?? fallbackKeyNames[key] ?? "key \(key)")
    }
}

extension Gesture: Identifiable {
    var id: String { rawValue }
}

let gestureTitles: [Gesture: String] = [
    .twistL: "Twist Left", .twistR: "Twist Right",
    .holdTwistL: "Hold + Twist Left", .holdTwistR: "Hold + Twist Right",
    .press: "Press",
]

let auxTitles: [AuxKey: String] = [
    .volumeUp: "Volume Up", .volumeDown: "Volume Down", .mute: "Mute",
    .playPause: "Play / Pause", .next: "Next Track", .previous: "Previous Track",
    .brightnessUp: "Brightness Up", .brightnessDown: "Brightness Down",
    .brightnessUpExternal: "Brightness Up", .brightnessDownExternal: "Brightness Down",
]

extension AuxKey {
    // fold the legacy External aliases onto the unified brightness cases so the
    // picker checkmark lands on the right entry for pre-unification configs
    var unified: AuxKey {
        switch self {
        case .brightnessUpExternal:   return .brightnessUp
        case .brightnessDownExternal: return .brightnessDown
        default:                      return self
        }
    }
}

// Human names for non-character keys the recorder may capture.
let specialKeyNames: [UInt16: String] = [
    36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
    115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
    100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
    107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
]

// Fallbacks for keycodes stored without a display label (hand-written configs) —
// only the digit row, which is stable across keyboard layouts.
let fallbackKeyNames: [UInt16: String] = [
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
    23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
]

func keyLabel(_ e: NSEvent) -> String {
    if let s = specialKeyNames[e.keyCode] { return s }
    if let c = e.charactersIgnoringModifiers, !c.isEmpty { return c.uppercased() }
    return "key \(e.keyCode)"
}

// ---- root: tab strip + detail ------------------------------------------------------

enum TabSel: Hashable {
    case general
    case layer(Int)
}

struct SettingsRoot: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var sel: TabSel = .general

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(store: store, sel: $sel)
            Divider()
            Group {
                switch sel {
                case .layer(let i) where i < store.cfg.layers.count:
                    LayerDetail(store: store, idx: i).id(i)
                default:
                    GeneralPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 560)
        .onChange(of: store.cfg.layers.count) { _, n in
            // clamp after an external reload shrinks the layer list
            if case .layer(let i) = sel, i >= n { sel = n > 0 ? .layer(n - 1) : .general }
        }
    }
}

// The horizontal layer bar: the Switching tab, a divider, a tab per layer, +.
// Drag a layer tab to reorder; right-click for Move Left / Move Right / Delete.
struct TabStrip: View {
    @ObservedObject var store: ConfigStore
    @Binding var sel: TabSel
    @State private var dragging: Int?

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            chip(.general) {
                Label("Switching", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)
            ForEach(Array(store.cfg.layers.enumerated()), id: \.offset) { i, l in
                chip(.layer(i)) {
                    Text(l.name.isEmpty ? "Layer \(i + 1)" : l.name)
                }
                .onDrag {
                    dragging = i
                    return NSItemProvider(object: "vk01-layer-\(i)" as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(target: i, dragging: $dragging,
                                                               store: store, sel: $sel))
                .contextMenu {
                    Button("Move Left") { move(i, by: -1) }
                        .disabled(i == 0)
                    Button("Move Right") { move(i, by: 1) }
                        .disabled(i == store.cfg.layers.count - 1)
                    Divider()
                    Button("Delete Layer", role: .destructive) { remove(i) }
                        .disabled(store.cfg.layers.count == 1)
                }
            }
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add a layer")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .trailing) {
            SavedBadge(store: store)
                .padding(.trailing, 12)
        }
    }

    private func chip(_ tag: TabSel, @ViewBuilder label: () -> some View) -> some View {
        Button { sel = tag } label: {
            label()
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(.quaternary).opacity(sel == tag ? 1 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sel == tag ? .primary : .secondary)
    }

    private func add() {
        withAnimation {
            store.cfg.layers.append(LayerConfig(name: "Layer \(store.cfg.layers.count + 1)",
                                                twistL: nil, twistR: nil,
                                                holdTwistL: nil, holdTwistR: nil, press: nil))
            sel = .layer(store.cfg.layers.count - 1)
        }
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard store.cfg.layers.indices.contains(j) else { return }
        withAnimation {
            store.cfg.layers.swapAt(i, j)
            if sel == .layer(i) { sel = .layer(j) }
            else if sel == .layer(j) { sel = .layer(i) }
        }
    }

    private func remove(_ i: Int) {
        guard store.cfg.layers.count > 1 else { return }
        withAnimation {
            store.cfg.layers.remove(at: i)
            if case .layer(let s) = sel {
                if s == i { sel = .layer(min(i, store.cfg.layers.count - 1)) }
                else if s > i { sel = .layer(s - 1) }
            }
        }
    }
}

// Reorder-on-hover drop delegate for the layer tabs — the standard SwiftUI
// horizontal-reorder pattern (the move happens as the drag passes over each
// tab; the drop itself is a no-op).
struct TabDropDelegate: DropDelegate {
    let target: Int
    @Binding var dragging: Int?
    let store: ConfigStore
    @Binding var sel: TabSel

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
              store.cfg.layers.indices.contains(from),
              store.cfg.layers.indices.contains(target) else { return }
        withAnimation {
            store.cfg.layers.move(fromOffsets: IndexSet(integer: from),
                                  toOffset: target > from ? target + 1 : target)
            if case .layer(let s) = sel {                  // selection follows the layers
                if s == from { sel = .layer(target) }
                else if from < target, s > from, s <= target { sel = .layer(s - 1) }
                else if target < from, s >= target, s < from { sel = .layer(s + 1) }
            }
        }
        dragging = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// Transient autosave indicator: fades in whenever an edit is written to
// config.json and fades back out — feedback without a Save button.
struct SavedBadge: View {
    @ObservedObject var store: ConfigStore
    @State private var visible = false
    @State private var hide: DispatchWorkItem?

    var body: some View {
        Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .onChange(of: store.lastSaved) { _, saved in
                guard saved != nil else { return }
                withAnimation(.easeIn(duration: 0.12)) { visible = true }
                hide?.cancel()
                let task = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.5)) { visible = false }
                }
                hide = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: task)
            }
    }
}

// ---- Layer Switching pane ---------------------------------------------------------

struct GeneralPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                Toggle("Double-tap the knob to switch layers", isOn: Binding(
                    get: { store.cfg.doubleTapEnabled },
                    set: { store.cfg.doubleTapSwitch = $0 }))
                LabeledContent("Next layer") {
                    ChordRecorder(chord: $store.cfg.layerHotkey,
                                  requireModifiers: true, clearable: true)
                }
                LabeledContent("Previous layer") {
                    ChordRecorder(chord: $store.cfg.layerHotkeyBack,
                                  requireModifiers: true, clearable: true)
                }
            } header: {
                Text("Layer Switching")
            } footer: {
                Text("Double-tap waits \(Int(store.cfg.tapWindow * 1000)) ms before a single "
                   + "press acts. Turn it off for instant presses and switch layers with the "
                   + "shortcuts or the menu bar instead. The shortcuts cycle through the "
                   + "layers in a loop — with two layers either one toggles between them — "
                   + "and need at least one modifier key.")
            }
        }
        .formStyle(.grouped)
    }
}

// ---- per-layer pane ----------------------------------------------------------------

struct LayerDetail: View {
    @ObservedObject var store: ConfigStore
    let idx: Int
    @State private var selected: Gesture?
    @State private var pendingKeystroke: Set<Gesture> = []
    @State private var editingSequence: Gesture?

    var body: some View {
        if idx < store.cfg.layers.count {
            Form {
                Section {
                    KnobHeader(selected: $selected)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section("Layer") {
                    TextField("Name", text: $store.cfg.layers[idx].name)
                }
                Section("Gestures") {
                    ForEach([Gesture.twistL, .twistR, .holdTwistL, .holdTwistR, .press]) { g in
                        row(g)
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(item: $editingSequence) { g in
                SequenceEditor(title: "\(gestureTitles[g] ?? g.rawValue) Sequence",
                               steps: stepsBinding(g))
            }
        }
    }

    private func row(_ g: Gesture) -> some View {
        LabeledContent(gestureTitles[g] ?? g.rawValue) {
            HStack(spacing: 10) {
                params(g)
                picker(g)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = g }
        .listRowBackground(selected == g ? Color.accentColor.opacity(0.10) : nil)
    }

    // Categorized action menu: None · Scroll ▸ · Media ▸ · Display ▸ · Web ▸ ·
    // Open ▸ · Custom ▸. The Pickers share one selection binding so the current
    // choice keeps its checkmark; Web shortcut entries are conveniences that
    // write a plain keystroke action (shown as such once picked).
    private func picker(_ g: Gesture) -> some View {
        Menu {
            Picker("", selection: preset(g)) {
                Text("None").tag(Preset.none)
            }
            .pickerStyle(.inline).labelsHidden()
            Menu("Scroll") {
                Picker("", selection: preset(g)) {
                    Text("Scroll Up").tag(Preset.scrollUp)
                    Text("Scroll Down").tag(Preset.scrollDown)
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Menu("Media") {
                Picker("", selection: preset(g)) {
                    Text("Volume Up").tag(Preset.aux(.volumeUp))
                    Text("Volume Down").tag(Preset.aux(.volumeDown))
                    Text("Mute").tag(Preset.aux(.mute))
                    Text("Play / Pause").tag(Preset.aux(.playPause))
                    Text("Next Track").tag(Preset.aux(.next))
                    Text("Previous Track").tag(Preset.aux(.previous))
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Menu("Display") {
                Picker("", selection: preset(g)) {
                    Text("Brightness Up").tag(Preset.aux(.brightnessUp))
                    Text("Brightness Down").tag(Preset.aux(.brightnessDown))
                }
                .pickerStyle(.inline).labelsHidden()
            }
            Menu("Web") {
                Button("Back  ⌘[") { setChord(g, key: 33, label: "[") }
                Button("Forward  ⌘]") { setChord(g, key: 30, label: "]") }
                Button("Refresh  ⌘R") { setChord(g, key: 15, label: "R") }
                Divider()
                Button("Open Website…") { setAction(g, .openURL(url: "https://")) }
            }
            Menu("Open") {
                Button("Calculator") { setLaunch(g, "com.apple.calculator") }
                Button("Mail") { setLaunch(g, "com.apple.mail") }
                Button("Finder") { setLaunch(g, "com.apple.finder") }
                Divider()
                Button("Other App…") { chooseApp(g) }
                Button("File or Folder…") { choosePath(g) }
                Divider()
                Button("Quit App…") { chooseApp(g) { .quitApp(bundleId: $0, force: nil) } }
            }
            Menu("Custom") {
                Picker("", selection: preset(g)) {
                    Text("Keystroke…").tag(Preset.keystroke)
                    Text("Hotkey Switch…").tag(Preset.hotkeySwitch)
                    Text("Sequence…").tag(Preset.sequence)
                }
                .pickerStyle(.inline).labelsHidden()
            }
        } label: {
            Text(currentTitle(g))
        }
        .fixedSize()
    }

    // Parameter controls for the selected action type.
    @ViewBuilder
    private func params(_ g: Gesture) -> some View {
        switch store.cfg.layers[idx][g] {
        case .scroll?:
            Stepper("\(Int(abs(currentLines(g)))) lines", value: linesBinding(g), in: 1...30)
                .fixedSize()
        case .keyChord?:
            ChordRecorder(chord: chordBinding(g))
        case .launchApp(let bundleId)?:
            Text(appName(bundleId)).foregroundStyle(.secondary)
        case .openURL?:
            TextField("https://…", text: urlBinding(g))
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
        case .openPath(let path)?:
            Text(pathName(path)).foregroundStyle(.secondary).help(path)
        case .quitApp(let bundleId, _)?:
            Text(appName(bundleId)).foregroundStyle(.secondary)
            Toggle("Force", isOn: forceBinding(g))
                .toggleStyle(.checkbox)
                .help("Force quit — unsaved changes are lost")
        case .hotkeySwitch?:
            ChordRecorder(chord: switchChordBinding(g, second: false))
            Text("⇄").foregroundStyle(.secondary)
            ChordRecorder(chord: switchChordBinding(g, second: true))
        case .sequence(let steps)?:
            Button("\(steps.count) step\(steps.count == 1 ? "" : "s")…") { editingSequence = g }
                .buttonStyle(.link)
                .help("Edit the sequence")
        default:
            if pendingKeystroke.contains(g) {
                ChordRecorder(chord: chordBinding(g))
            }
        }
    }

    // ---- bindings ----

    private func currentTitle(_ g: Gesture) -> String {
        switch store.cfg.layers[idx][g] {
        case nil, .some(.none):
            return pendingKeystroke.contains(g) ? "Keystroke" : "None"
        case .some(.scroll(let lines)):
            return (lines ?? store.cfg.defaultScrollLines) >= 0 ? "Scroll Up" : "Scroll Down"
        case .some(.keyChord):       return "Keystroke"
        case .some(.sequence):       return "Sequence"
        case .some(.aux(let k)):     return auxTitles[k] ?? "Media"
        case .some(.launchApp):      return "Open App"
        case .some(.openURL):        return "Website"
        case .some(.openPath):       return "Open File"
        case .some(.quitApp):        return "Quit App"
        case .some(.hotkeySwitch):   return "Hotkey Switch"
        }
    }

    private func preset(_ g: Gesture) -> Binding<Preset> {
        Binding(
            get: {
                switch store.cfg.layers[idx][g] {
                case nil, .some(.none):
                    return pendingKeystroke.contains(g) ? .keystroke : Preset.none
                case .some(.scroll(let lines)):
                    return (lines ?? store.cfg.defaultScrollLines) >= 0 ? .scrollUp : .scrollDown
                case .some(.keyChord):  return .keystroke
                case .some(.sequence):  return .sequence
                case .some(.aux(let k)): return .aux(k.unified)
                case .some(.launchApp): return .openApp
                case .some(.openURL):   return .openURL
                case .some(.openPath):  return .openPath
                case .some(.quitApp):   return .quitApp
                case .some(.hotkeySwitch): return .hotkeySwitch
                }
            },
            set: { p in
                pendingKeystroke.remove(g)
                switch p {
                case .none:
                    store.cfg.layers[idx][g] = nil
                case .scrollUp:
                    store.cfg.layers[idx][g] = .scroll(lines: abs(currentLines(g)))
                case .scrollDown:
                    store.cfg.layers[idx][g] = .scroll(lines: -abs(currentLines(g)))
                case .aux(let k):
                    store.cfg.layers[idx][g] = .aux(key: k)
                case .keystroke:
                    if case .keyChord? = store.cfg.layers[idx][g] { break }
                    store.cfg.layers[idx][g] = nil        // armed; written once recorded
                    pendingKeystroke.insert(g)
                case .openApp:
                    chooseApp(g)
                case .openURL:
                    if case .openURL? = store.cfg.layers[idx][g] { break }
                    store.cfg.layers[idx][g] = .openURL(url: "https://")
                case .openPath:
                    choosePath(g)
                case .quitApp:
                    chooseApp(g) { .quitApp(bundleId: $0, force: nil) }
                case .hotkeySwitch:
                    if case .hotkeySwitch? = store.cfg.layers[idx][g] { break }
                    store.cfg.layers[idx][g] = .hotkeySwitch(first: nil, second: nil)
                case .sequence:
                    if case .sequence? = store.cfg.layers[idx][g] {} else {
                        store.cfg.layers[idx][g] = .sequence(steps: [])
                    }
                    editingSequence = g
                }
            })
    }

    private func setChord(_ g: Gesture, key: CGKeyCode, label: String) {
        pendingKeystroke.remove(g)
        store.cfg.layers[idx][g] = .keyChord(key: key, mods: ["cmd"], label: label)
    }

    private func setLaunch(_ g: Gesture, _ bundleId: String) {
        pendingKeystroke.remove(g)
        store.cfg.layers[idx][g] = .launchApp(bundleId: bundleId)
    }

    private func setAction(_ g: Gesture, _ a: Action) {
        pendingKeystroke.remove(g)
        store.cfg.layers[idx][g] = a
    }

    private func urlBinding(_ g: Gesture) -> Binding<String> {
        Binding(
            get: {
                if case .openURL(let u)? = store.cfg.layers[idx][g] { return u }
                return ""
            },
            set: { store.cfg.layers[idx][g] = .openURL(url: $0) })
    }

    private func currentLines(_ g: Gesture) -> Int32 {
        if case .scroll(let l)? = store.cfg.layers[idx][g] {
            return l ?? store.cfg.defaultScrollLines
        }
        return store.cfg.defaultScrollLines
    }

    private func linesBinding(_ g: Gesture) -> Binding<Int> {
        Binding(
            get: { Int(abs(currentLines(g))) },
            set: { v in
                let sign: Int32 = currentLines(g) >= 0 ? 1 : -1
                store.cfg.layers[idx][g] = .scroll(lines: sign * Int32(v))
            })
    }

    private func chordBinding(_ g: Gesture) -> Binding<KeyChordSpec?> {
        Binding(
            get: {
                if case .keyChord(let k, let m, let l)? = store.cfg.layers[idx][g] {
                    return KeyChordSpec(key: k, mods: m, label: l)
                }
                return nil
            },
            set: { new in
                guard let n = new else { return }
                store.cfg.layers[idx][g] = .keyChord(key: n.key, mods: n.mods, label: n.label)
                pendingKeystroke.remove(g)
            })
    }

    // The editor sees atomic rows: combined key+delay steps are split into a
    // keystroke row and a wait row (the engine treats both forms identically).
    private func stepsBinding(_ g: Gesture) -> Binding<[SeqStep]> {
        Binding(
            get: {
                guard case .sequence(let s)? = store.cfg.layers[idx][g] else { return [] }
                var rows: [SeqStep] = []
                for st in s {
                    // key-less, delay-less steps are unrecorded keystroke rows — keep them
                    if st.key != nil || st.delayMs == nil {
                        rows.append(SeqStep(key: st.key, mods: st.mods, label: st.label))
                    }
                    if let ms = st.delayMs {
                        rows.append(SeqStep(delayMs: ms))
                    }
                }
                return rows
            },
            set: { store.cfg.layers[idx][g] = .sequence(steps: $0) })
    }

    private func chooseApp(_ g: Gesture,
                           make: (String) -> Action = { .launchApp(bundleId: $0) }) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundleId = Bundle(url: url)?.bundleIdentifier {
            pendingKeystroke.remove(g)
            store.cfg.layers[idx][g] = make(bundleId)
        }
    }

    private func forceBinding(_ g: Gesture) -> Binding<Bool> {
        Binding(
            get: {
                if case .quitApp(_, let f)? = store.cfg.layers[idx][g] { return f ?? false }
                return false
            },
            set: { v in
                if case .quitApp(let b, _)? = store.cfg.layers[idx][g] {
                    store.cfg.layers[idx][g] = .quitApp(bundleId: b, force: v)
                }
            })
    }

    private func switchChordBinding(_ g: Gesture, second: Bool) -> Binding<KeyChordSpec?> {
        Binding(
            get: {
                if case .hotkeySwitch(let f, let s)? = store.cfg.layers[idx][g] {
                    return second ? s : f
                }
                return nil
            },
            set: { new in
                guard let n = new,
                      case .hotkeySwitch(let f, let s)? = store.cfg.layers[idx][g] else { return }
                store.cfg.layers[idx][g] = .hotkeySwitch(first: second ? f : n,
                                                         second: second ? n : s)
            })
    }

    private func appName(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }

    private func choosePath(_ g: Gesture) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            pendingKeystroke.remove(g)
            store.cfg.layers[idx][g] = .openPath(path: url.path)
        }
    }

    private func pathName(_ path: String) -> String {
        FileManager.default.displayName(atPath: (path as NSString).expandingTildeInPath)
    }
}

enum Preset: Hashable {
    case none, scrollUp, scrollDown, aux(AuxKey), keystroke, openApp, sequence, openURL, openPath,
         quitApp, hotkeySwitch
}

// ---- sequence editor -------------------------------------------------------------
// Sheet listing a sequence's steps: keystroke rows (chord recorder) and wait
// rows (milliseconds). Steps run top to bottom; drag rows to reorder.

struct SequenceEditor: View {
    let title: String
    @Binding var steps: [SeqStep]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 16)
            Text("Steps run top to bottom — drag to reorder.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            List {
                ForEach(steps.indices, id: \.self) { i in
                    stepRow(i)
                }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .overlay {
                if steps.isEmpty {
                    Text("No steps yet — add a keystroke below.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button { steps.append(SeqStep()) } label: {
                    Label("Add Keystroke", systemImage: "keyboard")
                }
                Button { steps.append(SeqStep(delayMs: 100)) } label: {
                    Label("Add Wait", systemImage: "clock")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 340)
    }

    @ViewBuilder
    private func stepRow(_ i: Int) -> some View {
        HStack(spacing: 8) {
            if steps[i].key == nil, steps[i].delayMs != nil {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Wait")
                TextField("ms", value: delayBinding(i), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text("ms").foregroundStyle(.secondary)
            } else {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                ChordRecorder(chord: chordBinding(i))
            }
            Spacer()
            Button { steps.remove(at: i) } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Remove this step")
        }
        .padding(.vertical, 2)
    }

    private func chordBinding(_ i: Int) -> Binding<KeyChordSpec?> {
        Binding(
            get: {
                guard steps.indices.contains(i), let k = steps[i].key else { return nil }
                return KeyChordSpec(key: k, mods: steps[i].mods ?? [], label: steps[i].label)
            },
            set: { new in
                guard steps.indices.contains(i), let n = new else { return }
                steps[i].key = n.key
                steps[i].mods = n.mods
                steps[i].label = n.label
            })
    }

    private func delayBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { steps.indices.contains(i) ? steps[i].delayMs ?? 0 : 0 },
            set: { if steps.indices.contains(i) { steps[i].delayMs = max(0, $0) } })
    }
}

// ---- knob header ---------------------------------------------------------------
// The one skeuomorphic touch: a rendered knob whose gesture zones are clickable
// (the way the Trackpad pane illustrates gestures). Selection highlights the
// matching row below with the accent color.

struct KnobHeader: View {
    @Binding var selected: Gesture?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 10) {
                zone(.twistL, "arrow.counterclockwise", "Twist")
                zone(.holdTwistL, "arrow.counterclockwise.circle", "Hold + Twist")
            }
            knob
            VStack(spacing: 10) {
                zone(.twistR, "arrow.clockwise", "Twist")
                zone(.holdTwistR, "arrow.clockwise.circle", "Hold + Twist")
            }
        }
        .padding(.vertical, 6)
    }

    private var knob: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(nsColor: .controlBackgroundColor),
                                                  Color(nsColor: .windowBackgroundColor)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                Capsule().fill(.tertiary).frame(width: 4, height: 13).offset(y: -26)
            }
            .frame(width: 82, height: 82)
            .overlay(Circle().strokeBorder(Color.accentColor,
                                           lineWidth: selected == .press ? 2 : 0))
            .contentShape(Circle())
            .onTapGesture { toggle(.press) }
            Text("Press").font(.caption2)
                .foregroundStyle(selected == .press ? Color.accentColor : Color.secondary)
        }
    }

    private func zone(_ g: Gesture, _ symbol: String, _ label: String) -> some View {
        Button { toggle(g) } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(width: 84, height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected == g ? Color.accentColor : Color.secondary)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(selected == g ? Color.accentColor.opacity(0.12) : Color.clear))
    }

    private func toggle(_ g: Gesture) { selected = (selected == g ? nil : g) }
}

// ---- chord recorder --------------------------------------------------------------
// System Settings → Keyboard Shortcuts style capsule: click to arm, type the
// shortcut, Esc cancels. Rejects the knob's own ⌃⌥F16–F20 chords.

struct ChordRecorder: View {
    @Binding var chord: KeyChordSpec?
    var requireModifiers = false
    var clearable = false

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut…"
                               : (chord.map { $0.display } ?? "Record Shortcut"))
                    .frame(minWidth: 104)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(recording ? Color.accentColor : nil)
            if clearable, chord != nil, !recording {
                Button { chord = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove the shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }          // Esc cancels
            var mods: [String] = []
            if e.modifierFlags.contains(.control) { mods.append("ctrl") }
            if e.modifierFlags.contains(.option)  { mods.append("opt") }
            if e.modifierFlags.contains(.shift)   { mods.append("shift") }
            if e.modifierFlags.contains(.command) { mods.append("cmd") }
            if requireModifiers && mods.isEmpty { NSSound.beep(); return nil }
            // the knob's own chords are ground truth — never recordable
            if knobKeys.contains(Int64(e.keyCode)),
               mods.contains("ctrl"), mods.contains("opt") {
                NSSound.beep(); return nil
            }
            chord = KeyChordSpec(key: e.keyCode, mods: mods, label: keyLabel(e))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
