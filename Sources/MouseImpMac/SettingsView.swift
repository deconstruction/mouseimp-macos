// SwiftUI settings window: the DirectScroll options of MouseImp's MIProCfg, split
// into three tabs.
//
// * General        - what starts a grab and how it behaves
// * Advanced       - the speed modes with all their coefficients, and inertia
// * Diagnostics    - live state and the tools for awkward mice or applications

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            AdvancedSettings()
                .tabItem { Label("Advanced settings", systemImage: "dial.medium") }
            DiagnosticsSettings()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
        .frame(minWidth: 600, minHeight: 680)
    }
}

// MARK: - Shared pieces

/// The one line of plain language every tab starts with.
struct TabIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }
}

/// A labelled slider with its value on the right and an optional explanation
/// underneath - every coefficient uses this so nothing needs guessing.
struct SliderRow: View {
    let title: String
    var hint: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var loginAtStart = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            TabIntro(text: "Choose which mouse button starts DirectScroll and when it stands aside. "
                + "Everything about scrolling speed lives in the Advanced settings tab.")

            Section {
                Toggle("DirectScroll enabled", isOn: binding(\.enabled))
                Picker("Control type:", selection: binding(\.triggerButton)) {
                    ForEach(TriggerButton.all) { button in
                        Text(button.title).tag(button)
                    }
                }
                Text("Hold this button and drag to scroll the window under the pointer. For an extra "
                    + "button (Button 4 and up) a short press does nothing, so the button keeps no other action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModifierRow(title: "Activate on:", mask: binding(\.requireModifiers))
                ModifierRow(title: "Disable on:", mask: binding(\.disableModifiers))
            } header: {
                Text("Trigger")
            }

            Section {
                Toggle("Inverted horizontal", isOn: binding(\.invertX))
                Toggle("Inverted vertical", isOn: binding(\.invertY))
                Toggle("Lock to one axis while dragging", isOn: binding(\.snapToAxis))
                Toggle("Send line based wheel events", isOn: binding(\.lineScroll))
            } header: {
                Text("Direction")
            } footer: {
                Text("By default the content follows the pointer: drag down to see earlier content.")
                    .font(.caption)
            }

            Section {
                Toggle("Change cursor (open hand)", isOn: binding(\.showHandCursor))
                Toggle("Do not move the pointer while dragging", isOn: binding(\.freezeCursor))
                Toggle("Ignore presses on scroll bars", isOn: binding(\.skipScrollbars))
                SliderRow(title: "Drag threshold", hint: "How far the pointer must move before a press becomes a scroll.",
                          value: binding(\.dragThreshold), range: 0...20, step: 1, format: "%.0f px")
            } header: {
                Text("Cursor")
            }

            Section {
                ForEach(store.value.disabledBundles, id: \.self) { bundle in
                    HStack {
                        Text(bundle).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") { store.toggleBundle(bundle, disabled: false) }
                            .buttonStyle(.link)
                    }
                }
                Button("Add application…") { addApplication() }
            } header: {
                Text("Applications without DirectScroll")
            }

            Section {
                Toggle("Launch at login", isOn: $loginAtStart)
                    .onChange(of: loginAtStart) { newValue in
                        do {
                            try LoginItem.set(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            loginAtStart = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
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

// MARK: - Advanced

struct AdvancedSettings: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var liveLine = "no data yet"
    private let liveTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private static let minSpeed = 0.2
    private static let maxSpeed = 10.0

    var body: some View {
        Form {
            TabIntro(text: "Scrolling can follow your hand instead of staying fixed. Pick a mode, then tune the "
                + "coefficients - they apply from the next drag, so you can try a value without restarting anything.")

            Section {
                Picker("Speed mode:", selection: binding(\.speedMode)) {
                    ForEach(SpeedMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(store.value.speedMode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.value.speedMode != .constant {
                    Text(modeDetail(store.value.speedMode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Speed mode")
            }

            Section {
                HStack {
                    Text("Base speed")
                    Slider(value: speedBinding, in: log10(Self.minSpeed)...log10(Self.maxSpeed))
                    Text(String(format: "%.2f×", store.value.speed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Text("The speed at a normal, unhurried drag. The dynamic modes multiply this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speed")
            }

            switch store.value.speedMode {
            case .constant:
                Section {
                    Text("Constant mode always uses the base speed; the coefficients below belong to the two "
                        + "dynamic modes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .velocity:
                Section {
                    SliderRow(title: "Response", hint: "How strongly the speed follows the hand (k_v). 0 keeps the base speed, 2 reacts twice as much.",
                              value: binding(\.velocityResponse), range: 0...5)
                    SliderRow(title: "Boost while accelerating", hint: "Extra speed while the hand speeds up (k_a), taken from the change of the pointer speed. Slowing down never reduces the scroll.",
                              value: binding(\.accelerationBoost), range: 0...5)
                    SliderRow(title: "Reference speed", hint: "The pointer speed treated as \"normal\", in pixels per second. Lower makes the mode react earlier.",
                              value: binding(\.velocityReference), range: 100...3000, step: 50, format: "%.0f px/s")
                    SliderRow(title: "Reference acceleration", hint: "The acceleration that earns the full boost, in pixels per second squared.",
                              value: binding(\.accelerationReference), range: 500...30000, step: 250, format: "%.0f px/s²")
                    SliderRow(title: "Curve exponent", hint: "1 is a straight line; below 1 reacts earlier, above 1 waits for faster movement.",
                              value: binding(\.velocityExponent), range: 0.2...2, step: 0.05)
                    SliderRow(title: "Smoothing", hint: "How quickly the multiplier follows changes. Low is calm, 1 follows every step.",
                              value: binding(\.dynamicSmoothing), range: 0.05...1, step: 0.05)
                    SliderRow(title: "Min multiplier", hint: "Never scroll slower than this, whatever the hand does.",
                              value: binding(\.minMultiplier), range: 0.05...1, step: 0.05)
                    SliderRow(title: "Max multiplier", hint: "The ceiling, so a fast flick cannot fly off.",
                              value: binding(\.maxMultiplier), range: 1...20, step: 0.5)
                } header: {
                    Text("Coefficients — Follow the hand")
                }

            case .distance:
                Section {
                    SliderRow(title: "Ramp", hint: "How much faster it gets on a long drag. 0 keeps the base speed.",
                              value: binding(\.distanceRamp), range: 0...10, step: 0.1)
                    SliderRow(title: "Ramp distance", hint: "The distance from where you pressed at which the ramp is at full strength.",
                              value: binding(\.distanceReference), range: 50...1500, step: 25, format: "%.0f px")
                    SliderRow(title: "Curve exponent", hint: "1 grows steadily; below 1 speeds up early, above 1 stays calm at first.",
                              value: binding(\.distanceExponent), range: 0.2...2, step: 0.05)
                    SliderRow(title: "Smoothing", hint: "How quickly the multiplier follows the distance.",
                              value: binding(\.dynamicSmoothing), range: 0.05...1, step: 0.05)
                    SliderRow(title: "Max multiplier", hint: "The ceiling for the ramp.",
                              value: binding(\.maxMultiplier), range: 1...20, step: 0.5)
                } header: {
                    Text("Coefficients — Progressive")
                }
            }

            Section {
                HStack {
                    Button("Gentle") { applyPreset(.gentle) }
                    Button("Balanced") { applyPreset(.balanced) }
                    Button("Aggressive") { applyPreset(.aggressive) }
                    Spacer()
                    Button("Defaults") { apply(defaults: Settings()) }
                }
                Text("Gentle reacts softly, Aggressive follows the hand much more. Defaults resets this tab "
                    + "(speed mode, coefficients and inertia) and leaves the General tab alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Presets")
            }

            Section {
                Text(liveLine)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Live")
            } footer: {
                Text("Pointer speed, its change and the multiplier that was actually used on the last scroll step - "
                    + "handy while tuning the coefficients.")
                    .font(.caption)
            }

            Section {
                Toggle("Keep scrolling after release", isOn: binding(\.coastEnabled))
                Text("Inertia is independent from the speed mode: it has its own strength and thresholds below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(title: "Friction", hint: "Lower makes the scroll settle sooner.",
                          value: binding(\.coastFactor), range: 0.2...0.95, step: 0.01)
                SliderRow(title: "Start threshold", hint: "The pointer speed at release that starts inertia.",
                          value: binding(\.coastStartVelocity), range: 10...2000, step: 10, format: "%.0f px/s")
                SliderRow(title: "Stop threshold", hint: "Inertia stops once it slows below this.",
                          value: binding(\.coastStopVelocity), range: 5...1000, step: 5, format: "%.0f px/s")
                SliderRow(title: "Velocity window", hint: "How far back the release speed is measured. Shorter feels more immediate.",
                          value: binding(\.coastVelocityWindow), range: 0.03...0.4, step: 0.01, format: "%.2f s")
                Toggle("Coast follows the speed mode", isOn: binding(\.coastFollowsSpeedMode))
                Text(store.value.coastFollowsSpeedMode
                     ? "Inertia starts from the speed you felt, including the dynamic boost."
                     : "Inertia starts from the base speed only, whatever mode is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Inertia")
            }
        }
        .formStyle(.grouped)
        .onReceive(liveTimer) { _ in
            liveLine = AppActions.shared.speedLine()
        }
    }

    private func modeDetail(_ mode: SpeedMode) -> String {
        switch mode {
        case .constant:
            return "Same multiplier for the whole drag - the behaviour of earlier versions."
        case .velocity:
            return "Response and Boost are the two knobs most people touch. Everything else refines how the "
                + "speed is measured and how far it is allowed to go."
        case .distance:
            return "Good when you want a steady, predictable feel: the scroll depends only on how far you dragged, "
                + "not on how fast your hand moved."
        }
    }

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

    private enum Preset { case gentle, balanced, aggressive }

    private func applyPreset(_ preset: Preset) {
        var settings = store.value
        switch preset {
        case .gentle:
            settings.velocityResponse = 0.5
            settings.accelerationBoost = 0.2
            settings.velocityExponent = 0.6
            settings.dynamicSmoothing = 0.35
            settings.maxMultiplier = 3
            settings.distanceRamp = 0.8
            settings.distanceExponent = 0.8
        case .balanced:
            let defaults = Settings()
            settings.velocityResponse = defaults.velocityResponse
            settings.accelerationBoost = defaults.accelerationBoost
            settings.velocityExponent = defaults.velocityExponent
            settings.dynamicSmoothing = defaults.dynamicSmoothing
            settings.maxMultiplier = defaults.maxMultiplier
            settings.distanceRamp = defaults.distanceRamp
            settings.distanceExponent = defaults.distanceExponent
        case .aggressive:
            settings.velocityResponse = 2.0
            settings.accelerationBoost = 1.5
            settings.velocityExponent = 0.9
            settings.dynamicSmoothing = 0.15
            settings.maxMultiplier = 12
            settings.distanceRamp = 3.0
            settings.distanceExponent = 1.2
        }
        store.value = settings
    }

    /// Resets everything this tab owns; the General tab is left untouched.
    private func apply(defaults: Settings) {
        var settings = store.value
        settings.speedMode = defaults.speedMode
        settings.speed = defaults.speed
        settings.velocityResponse = defaults.velocityResponse
        settings.accelerationBoost = defaults.accelerationBoost
        settings.velocityReference = defaults.velocityReference
        settings.accelerationReference = defaults.accelerationReference
        settings.velocityExponent = defaults.velocityExponent
        settings.distanceRamp = defaults.distanceRamp
        settings.distanceReference = defaults.distanceReference
        settings.distanceExponent = defaults.distanceExponent
        settings.dynamicSmoothing = defaults.dynamicSmoothing
        settings.minMultiplier = defaults.minMultiplier
        settings.maxMultiplier = defaults.maxMultiplier
        settings.coastEnabled = defaults.coastEnabled
        settings.coastFactor = defaults.coastFactor
        settings.coastStartVelocity = defaults.coastStartVelocity
        settings.coastStopVelocity = defaults.coastStopVelocity
        settings.coastVelocityWindow = defaults.coastVelocityWindow
        settings.coastFollowsSpeedMode = defaults.coastFollowsSpeedMode
        store.value = settings
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
}

// MARK: - Diagnostics

struct DiagnosticsSettings: View {
    @State private var statusText = ""
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            TabIntro(text: "Live state of the event tap and the numbers the app keeps, plus the tools to use when a "
                + "mouse button or an application does not do what you expect.")

            Section {
                Text(statusText.isEmpty ? "reading…" : statusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Status")
            } footer: {
                Text("The same text is written to the status file once a second.")
                    .font(.caption)
            }

            Section {
                Button("Trace events for 20 s") { AppActions.shared.traceEvents() }
                Button("Test scroll under pointer (3 s)") { AppActions.shared.testScroll() }
                Button("Reveal status file") {
                    let path = AppActions.shared.statusFilePath()
                    guard !path.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Restart event tap") { AppActions.shared.restartTap() }
            } header: {
                Text("Tools")
            } footer: {
                Text("The trace records every event type the system delivers, including the ones the app does not "
                    + "handle - that is how you find out what an unusual mouse button actually sends.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onReceive(refreshTimer) { _ in
            statusText = AppActions.shared.statusText()
        }
    }
}

// MARK: - Modifiers

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
