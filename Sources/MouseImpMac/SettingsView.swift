// SwiftUI settings window - the DirectScroll page of MouseImp's MIProCfg.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("DirectScroll enabled", isOn: binding(\.enabled))
                Picker("Control type:", selection: binding(\.triggerButton)) {
                    ForEach(TriggerButton.all) { button in
                        Text(button.title).tag(button)
                    }
                }
                ModifierRow(title: "Activate on:", mask: binding(\.requireModifiers))
                ModifierRow(title: "Disable on:", mask: binding(\.disableModifiers))
            } header: {
                Text("Trigger")
            }

            Section {
                HStack {
                    Text("Scrolling speed:")
                    // Logarithmic: 0.2x .. 10x, so the low end (the useful part)
                    // gets as much of the track as 4x..10x.
                    Slider(value: speedBinding,
                           in: log10(Self.minSpeed)...log10(Self.maxSpeed))
                    Text(String(format: "%.2f×", store.value.speed))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                ModifierRow(title: "Slow down on:", mask: binding(\.slowModifiers))
                HStack {
                    Text("Slow down factor:")
                    Slider(value: binding(\.slowFactor), in: 0.05...1.0, step: 0.05)
                    Text(String(format: "%.2f×", store.value.slowFactor))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            } header: {
                Text("Speed")
            }

            Section {
                Toggle("Inverted horizontal", isOn: binding(\.invertX))
                Toggle("Inverted vertical", isOn: binding(\.invertY))
                Toggle("Lock to one axis while dragging", isOn: binding(\.snapToAxis))
                Toggle("Send line based wheel events", isOn: binding(\.lineScroll))
            } header: {
                Text("Direction")
            }

            Section {
                Toggle("Change cursor (open hand)", isOn: binding(\.showHandCursor))
                Toggle("Do not move the pointer while dragging", isOn: binding(\.freezeCursor))
                Toggle("Ignore presses on scroll bars", isOn: binding(\.skipScrollbars))
                HStack {
                    Text("Drag threshold:")
                    Slider(value: binding(\.dragThreshold), in: 0...20, step: 1)
                    Text("\(Int(store.value.dragThreshold)) px")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            } header: {
                Text("Cursor")
            }

            Section {
                Toggle("Keep scrolling after release", isOn: binding(\.coastEnabled))
                HStack {
                    Text("Coast friction:")
                    Slider(value: binding(\.coastFactor), in: 0.2...0.95, step: 0.01)
                    Text(String(format: "%.2f", store.value.coastFactor))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                Text("Lower friction means the scroll stops sooner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Inertia")
            }

            Section {
                ForEach(store.value.disabledBundles, id: \.self) { bundle in
                    HStack {
                        Text(bundle)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") { store.toggleBundle(bundle, disabled: false) }
                            .buttonStyle(.link)
                    }
                }
                Button("Add application…") { addApplication() }
            } header: {
                Text("Applications without DirectScroll")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: - Helpers

    private static let minSpeed = 0.2
    private static let maxSpeed = 10.0

    /// The speed slider works on a log scale; the stored value stays a plain
    /// multiplier rounded to two decimals.
    private var speedBinding: Binding<Double> {
        Binding(
            get: { log10(min(max(store.value.speed, Self.minSpeed), Self.maxSpeed)) },
            set: { newValue in
                var settings = store.value
                let speed = pow(10, newValue)
                settings.speed = (speed * 100).rounded() / 100
                store.value = settings
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { store.value[keyPath: keyPath] },
            set: { newValue in
                var settings = store.value
                settings[keyPath: keyPath] = newValue
                store.value = settings
            }
        )
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier {
                store.toggleBundle(identifier, disabled: true)
            }
        }
    }
}

/// Four modifier toggles, mirroring MouseImp's combo boxes for
/// "Activate on / Slow down on / Disable on".
struct ModifierRow: View {
    let title: String
    @Binding var mask: ModifierMask

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(Self.keys, id: \.0) { entry in
                Toggle(entry.1, isOn: flag(entry.0))
                    .toggleStyle(.button)
                    .frame(width: 34)
            }
        }
    }

    private static let keys: [(ModifierMask, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    private func flag(_ key: ModifierMask) -> Binding<Bool> {
        Binding(
            get: { mask.contains(key) },
            set: { on in
                if on { mask.insert(key) } else { mask.remove(key) }
            }
        )
    }
}
