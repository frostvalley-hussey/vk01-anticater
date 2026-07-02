// SettingsUI.swift — the VK-01 settings window (SwiftUI, macOS 26 SDK).
// System Settings idiom: sidebar (Layer Switching + layers, drag to reorder),
// grouped Form detail with a clickable knob header, chord-recorder capsules.
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
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
        didSet { if !syncing { applyConfig(cfg) } }
    }

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
        return s + (label ?? "key \(key)")
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

func keyLabel(_ e: NSEvent) -> String {
    if let s = specialKeyNames[e.keyCode] { return s }
    if let c = e.charactersIgnoringModifiers, !c.isEmpty { return c.uppercased() }
    return "key \(e.keyCode)"
}

// ---- root: sidebar + detail ------------------------------------------------------

enum SidebarSel: Hashable {
    case general
    case layer(Int)
}

struct SettingsRoot: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var sel: SidebarSel? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $sel) {
                Label("Layer Switching", systemImage: "arrow.triangle.2.circlepath")
                    .tag(SidebarSel.general)
                Section("Layers") {
                    ForEach(Array(store.cfg.layers.enumerated()), id: \.offset) { i, l in
                        Label(l.name, systemImage: "\(i + 1).circle")
                            .tag(SidebarSel.layer(i))
                    }
                    .onMove { from, to in
                        store.cfg.layers.move(fromOffsets: from, toOffset: to)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { addRemoveBar }
        } detail: {
            switch sel {
            case .layer(let i) where i < store.cfg.layers.count:
                LayerDetail(store: store, idx: i).id(i)
            default:
                GeneralPane(store: store)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private var addRemoveBar: some View {
        HStack(spacing: 14) {
            Button(action: addLayer) { Image(systemName: "plus") }
                .help("Add a layer")
            Button(action: removeLayer) { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove the selected layer")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.bar)
    }

    private var canRemove: Bool {
        if case .layer = sel { return store.cfg.layers.count > 1 }
        return false
    }

    private func addLayer() {
        withAnimation {
            store.cfg.layers.append(LayerConfig(name: "Layer \(store.cfg.layers.count + 1)",
                                                twistL: nil, twistR: nil,
                                                holdTwistL: nil, holdTwistR: nil, press: nil))
            sel = .layer(store.cfg.layers.count - 1)
        }
    }

    private func removeLayer() {
        guard case .layer(let i) = sel, store.cfg.layers.count > 1,
              i < store.cfg.layers.count else { return }
        withAnimation {
            store.cfg.layers.remove(at: i)
            sel = .general
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
                LabeledContent("Keyboard shortcut") {
                    ChordRecorder(chord: $store.cfg.layerHotkey,
                                  requireModifiers: true, clearable: true)
                }
            } header: {
                Text("Layer Switching")
            } footer: {
                Text("Double-tap waits \(Int(store.cfg.tapWindow * 1000)) ms before a single "
                   + "press acts. Turn it off for instant presses and switch layers with the "
                   + "keyboard shortcut or the menu bar instead. The shortcut cycles "
                   + "Layer 1 → 2 → … and needs at least one modifier key.")
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
                    row(.twistL, "Twist Left")
                    row(.twistR, "Twist Right")
                    row(.holdTwistL, "Hold + Twist Left")
                    row(.holdTwistR, "Hold + Twist Right")
                    row(.press, "Press")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ g: Gesture, _ title: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                params(g)
                picker(g)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = g }
        .listRowBackground(selected == g ? Color.accentColor.opacity(0.10) : nil)
    }

    // MECE action list: None · Scroll · Media · Display · Keystroke · App.
    private func picker(_ g: Gesture) -> some View {
        Picker("", selection: preset(g)) {
            Text("None").tag(Preset.none)
            Section("Scroll") {
                Text("Scroll Up").tag(Preset.scrollUp)
                Text("Scroll Down").tag(Preset.scrollDown)
            }
            Section("Media") {
                Text("Volume Up").tag(Preset.aux(.volumeUp))
                Text("Volume Down").tag(Preset.aux(.volumeDown))
                Text("Mute").tag(Preset.aux(.mute))
                Text("Play / Pause").tag(Preset.aux(.playPause))
                Text("Next Track").tag(Preset.aux(.next))
                Text("Previous Track").tag(Preset.aux(.previous))
            }
            Section("Display") {
                Text("Brightness Up").tag(Preset.aux(.brightnessUp))
                Text("Brightness Down").tag(Preset.aux(.brightnessDown))
            }
            Section("Custom") {
                Text("Keystroke…").tag(Preset.keystroke)
                Text("Open App…").tag(Preset.openApp)
                if case .sequence? = store.cfg.layers[idx][g] {
                    Text("Sequence").tag(Preset.sequence)
                }
            }
        }
        .labelsHidden()
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
        case .sequence(let steps)?:
            Text("\(steps.count) steps").foregroundStyle(.secondary)
        default:
            if pendingKeystroke.contains(g) {
                ChordRecorder(chord: chordBinding(g))
            }
        }
    }

    // ---- bindings ----

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
                case .some(.aux(let k)): return .aux(k)
                case .some(.launchApp): return .openApp
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
                case .sequence:
                    break                                  // preserved as-is
                }
            })
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

    private func chooseApp(_ g: Gesture) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundleId = Bundle(url: url)?.bundleIdentifier {
            store.cfg.layers[idx][g] = .launchApp(bundleId: bundleId)
        }
    }

    private func appName(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }
}

enum Preset: Hashable {
    case none, scrollUp, scrollDown, aux(AuxKey), keystroke, openApp, sequence
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
