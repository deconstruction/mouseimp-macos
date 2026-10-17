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
                .tabItem { Label("tab.general", systemImage: "slider.horizontal.3") }
            AdvancedSettings()
                .tabItem { Label("tab.advanced", systemImage: "dial.medium") }
            DiagnosticsSettings()
                .tabItem { Label("tab.diagnostics", systemImage: "waveform.path.ecg") }
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
            TabIntro(text: NSLocalizedString("general.intro", comment: ""))

            Section {
                Toggle("general.enabled", isOn: binding(\.enabled))
                Picker("general.controlType", selection: binding(\.triggerButton)) {
                    ForEach(TriggerButton.all) { button in
                        Text(button.localizedTitle).tag(button)
                    }
                }
                Text("general.controlTypeHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModifierRow(title: NSLocalizedString("general.activateOn", comment: ""), mask: binding(\.requireModifiers))
                ModifierRow(title: NSLocalizedString("general.disableOn", comment: ""), mask: binding(\.disableModifiers))
            } header: {
                Text("general.trigger")
            }

            Section {
                Toggle("direction.invertX", isOn: binding(\.invertX))
                Toggle("direction.invertY", isOn: binding(\.invertY))
                Toggle("direction.snapToAxis", isOn: binding(\.snapToAxis))
                Toggle("direction.lineScroll", isOn: binding(\.lineScroll))
            } header: {
                Text("direction.title")
            } footer: {
                Text("direction.footer")
                    .font(.caption)
            }

            Section {
                Toggle("cursor.hand", isOn: binding(\.showHandCursor))
                Toggle("cursor.freeze", isOn: binding(\.freezeCursor))
                Toggle("cursor.skipScrollbars", isOn: binding(\.skipScrollbars))
                SliderRow(title: NSLocalizedString("cursor.dragThreshold", comment: ""),
                          hint: NSLocalizedString("cursor.dragThresholdHint", comment: ""),
                          value: binding(\.dragThreshold), range: 0...20, step: 1, format: "%.0f px")
            } header: {
                Text("cursor.title")
            }

            Section {
                ForEach(store.value.disabledBundles, id: \.self) { bundle in
                    HStack {
                        Text(bundle).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("apps.remove") { store.toggleBundle(bundle, disabled: false) }
                            .buttonStyle(.link)
                    }
                }
                Button("apps.add") { addApplication() }
            } header: {
                Text("apps.title")
            }

            Section {
                Toggle("startup.launchAtLogin", isOn: $loginAtStart)
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
                Text("startup.title")
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
    @State private var liveLine = NSLocalizedString("live.placeholder", comment: "")
    private let liveTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private static let minSpeed = 0.2
    private static let maxSpeed = 10.0

    var body: some View {
        Form {
            TabIntro(text: NSLocalizedString("advanced.intro", comment: ""))

            Section {
                Picker("advanced.speedMode", selection: binding(\.speedMode)) {
                    ForEach(SpeedMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(store.value.speedMode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.value.speedMode != .constant {
                    Text(store.value.speedMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("advanced.speedMode.title")
            }

            Section {
                HStack {
                    Text("speed.base")
                    Slider(value: speedBinding, in: log10(Self.minSpeed)...log10(Self.maxSpeed))
                    Text(String(format: "%.2f×", store.value.speed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Text("speed.baseHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("speed.title")
            }

            switch store.value.speedMode {
            case .constant:
                Section {
                    Text("speed.constantNote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .velocity:
                Section {
                    SliderRow(title: NSLocalizedString("coef.response", comment: ""),
                              hint: NSLocalizedString("coef.response.hint", comment: ""),
                              value: binding(\.velocityResponse), range: 0...5)
                    SliderRow(title: NSLocalizedString("coef.boost", comment: ""),
                              hint: NSLocalizedString("coef.boost.hint", comment: ""),
                              value: binding(\.accelerationBoost), range: 0...5)
                    SliderRow(title: NSLocalizedString("coef.vref", comment: ""),
                              hint: NSLocalizedString("coef.vref.hint", comment: ""),
                              value: binding(\.velocityReference), range: 100...3000, step: 50, format: "%.0f px/s")
                    SliderRow(title: NSLocalizedString("coef.aref", comment: ""),
                              hint: NSLocalizedString("coef.aref.hint", comment: ""),
                              value: binding(\.accelerationReference), range: 500...30000, step: 250, format: "%.0f px/s²")
                    SliderRow(title: NSLocalizedString("coef.vexp", comment: ""),
                              hint: NSLocalizedString("coef.vexp.hint", comment: ""),
                              value: binding(\.velocityExponent), range: 0.2...2, step: 0.05)
                    SliderRow(title: NSLocalizedString("coef.smooth", comment: ""),
                              hint: NSLocalizedString("coef.smooth.hint", comment: ""),
                              value: binding(\.dynamicSmoothing), range: 0.05...1, step: 0.05)
                    SliderRow(title: NSLocalizedString("coef.min", comment: ""),
                              hint: NSLocalizedString("coef.min.hint", comment: ""),
                              value: binding(\.minMultiplier), range: 0.05...1, step: 0.05)
                    SliderRow(title: NSLocalizedString("coef.max", comment: ""),
                              hint: NSLocalizedString("coef.max.hint", comment: ""),
                              value: binding(\.maxMultiplier), range: 1...20, step: 0.5)
                } header: {
                    Text("coef.velocity.title")
                }

            case .distance:
                Section {
                    SliderRow(title: NSLocalizedString("coef.ramp", comment: ""),
                              hint: NSLocalizedString("coef.ramp.hint", comment: ""),
                              value: binding(\.distanceRamp), range: 0...10, step: 0.1)
                    SliderRow(title: NSLocalizedString("coef.dref", comment: ""),
                              hint: NSLocalizedString("coef.dref.hint", comment: ""),
                              value: binding(\.distanceReference), range: 50...1500, step: 25, format: "%.0f px")
                    SliderRow(title: NSLocalizedString("coef.dexp", comment: ""),
                              hint: NSLocalizedString("coef.dexp.hint", comment: ""),
                              value: binding(\.distanceExponent), range: 0.2...2, step: 0.05)
                    SliderRow(title: NSLocalizedString("coef.smooth", comment: ""),
                              hint: NSLocalizedString("coef.dsmooth.hint", comment: ""),
                              value: binding(\.dynamicSmoothing), range: 0.05...1, step: 0.05)
                    SliderRow(title: NSLocalizedString("coef.max", comment: ""),
                              hint: NSLocalizedString("coef.dmax.hint", comment: ""),
                              value: binding(\.maxMultiplier), range: 1...20, step: 0.5)
                } header: {
                    Text("coef.distance.title")
                }
            }

            Section {
                HStack {
                    Button("presets.gentle") { applyPreset(.gentle) }
                    Button("presets.balanced") { applyPreset(.balanced) }
                    Button("presets.aggressive") { applyPreset(.aggressive) }
                    Spacer()
                    Button("presets.defaults") { apply(defaults: Settings()) }
                }
                Text("presets.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("presets.title")
            }

            Section {
                Text(liveLine)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            } header: {
                Text("live.title")
            } footer: {
                Text("live.footer")
                    .font(.caption)
            }

            Section {
                Toggle("inertia.enabled", isOn: binding(\.coastEnabled))
                Text("inertia.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(title: NSLocalizedString("inertia.friction", comment: ""),
                          hint: NSLocalizedString("inertia.friction.hint", comment: ""),
                          value: binding(\.coastFactor), range: 0.2...0.95, step: 0.01)
                SliderRow(title: NSLocalizedString("inertia.start", comment: ""),
                          hint: NSLocalizedString("inertia.start.hint", comment: ""),
                          value: binding(\.coastStartVelocity), range: 10...2000, step: 10, format: "%.0f px/s")
                SliderRow(title: NSLocalizedString("inertia.stop", comment: ""),
                          hint: NSLocalizedString("inertia.stop.hint", comment: ""),
                          value: binding(\.coastStopVelocity), range: 5...1000, step: 5, format: "%.0f px/s")
                SliderRow(title: NSLocalizedString("inertia.window", comment: ""),
                          hint: NSLocalizedString("inertia.window.hint", comment: ""),
                          value: binding(\.coastVelocityWindow), range: 0.03...0.4, step: 0.01, format: "%.2f s")
                Toggle("inertia.follows", isOn: binding(\.coastFollowsSpeedMode))
                Text(NSLocalizedString(store.value.coastFollowsSpeedMode
                     ? "inertia.follows.on"
                     : "inertia.follows.off", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("inertia.title")
            }
        }
        .formStyle(.grouped)
        .onReceive(liveTimer) { _ in
            liveLine = AppActions.shared.speedLine()
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
            TabIntro(text: NSLocalizedString("diag.intro", comment: ""))

            Section {
                Text(statusText.isEmpty ? NSLocalizedString("diag.reading", comment: "") : statusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("diag.status.title")
            } footer: {
                Text("diag.status.footer")
                    .font(.caption)
            }

            Section {
                Button("diag.trace") { AppActions.shared.traceEvents() }
                Button("diag.testScroll") { AppActions.shared.testScroll() }
                Button("diag.reveal") {
                    let path = AppActions.shared.statusFilePath()
                    guard !path.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("diag.restart") { AppActions.shared.restartTap() }
            } header: {
                Text("diag.tools.title")
            } footer: {
                Text("diag.tools.footer")
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
