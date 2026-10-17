// Menu bar application: the counterpart of the MouseImp tray icon, plus the
// settings window (MIProCfg's DirectScroll page).

import AppKit
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = SettingsStore.shared
    private let engine = ScrollEngine()
    private let cursorTip = CursorTip()
    private lazy var tap = EventTapController(engine: engine)

    /// Set by `main` when the app is launched with `--show-settings`.
    var openSettingsOnLaunch = false

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var subscription: AnyCancellable?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.update(settings: store.value)
        engine.onGrabChanged = { [weak self] active, point in
            guard let self else { return }
            DispatchQueue.main.async {
                if active, self.store.value.showHandCursor {
                    self.cursorTip.show(at: point)
                } else {
                    self.cursorTip.hide()
                }
            }
        }
        tap.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        subscription = store.$value.sink { [weak self] settings in
            self?.engine.update(settings: settings)
            TargetCache.shared.setLookForScrollbars(settings.skipScrollbars)
            self?.refresh()
        }

        buildStatusItem()
        refresh()

        // Bridge for the settings window: actions and live numbers.
        AppActions.shared.restartTap = { [weak self] in self?.ensureTapRunning() }
        AppActions.shared.traceEvents = { [weak self] in self?.traceEvents() }
        AppActions.shared.testScroll = { [weak self] in self?.testScroll() }
        AppActions.shared.statusFilePath = { Diagnostics.shared.path }
        AppActions.shared.statusText = { [weak self] in self?.statusText() ?? "" }
        AppActions.shared.speedLine = { [weak self] in
            guard let self else { return NSLocalizedString("live.placeholder", comment: "") }
            let stats = self.engine.stats
            return String(format: NSLocalizedString("live.format", comment: ""),
                          stats.lastVelocity, stats.lastAcceleration, stats.lastMultiplier)
        }

        // Window/scroll bar lookups happen on a background queue, never in the tap.
        TargetCache.shared.setLookForScrollbars(store.value.skipScrollbars)
        TargetCache.shared.start()

        Diagnostics.shared.start { [weak self] in self?.statusText() ?? "" }

        if Probes.isTrusted {
            tap.start()
        } else {
            Probes.requestTrust()
            startPermissionWatch()
        }
        if !Probes.canPostEvents {
            Probes.requestPostAccess()
        }

        if openSettingsOnLaunch {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        TargetCache.shared.stop()
        Diagnostics.shared.stop()
    }

    // MARK: - Event tap

    private func startPermissionWatch() {
        // macOS does not tell an application when the Accessibility permission is
        // granted, and the user may well grant it while we run, so poll for it
        // (cheap, local call) and install the tap as soon as it appears.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            guard Probes.isTrusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.tap.restart()
            self.refresh()
        }
    }

    private func ensureTapRunning() {
        if !Probes.isTrusted {
            Probes.requestTrust()
            startPermissionWatch()
            return
        }
        if !tap.status.isRunning {
            tap.restart()
        }
        refresh()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MouseImp") {
                image.isTemplate = true
                button.image = image
            } else if let fallback = NSImage(systemSymbolName: "arrow.up.and.down.circle", accessibilityDescription: "MouseImp") {
                fallback.isTemplate = true
                button.image = fallback
            } else {
                button.title = "MI"
            }
            button.toolTip = "MouseImp - DirectScroll"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: NSLocalizedString("menu.enabled", comment: ""),
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = store.value.enabled ? .on : .off
        toggle.tag = 1
        menu.addItem(toggle)

        let settings = NSMenuItem(title: NSLocalizedString("menu.settings", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.tag = 2
        menu.addItem(status)

        let diagnostics = NSMenuItem(title: NSLocalizedString("menu.diagnostics", comment: ""), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let info = NSMenuItem(title: diagnosticsLine(), action: nil, keyEquivalent: "")
        info.tag = 3
        submenu.addItem(info)
        let test = NSMenuItem(title: NSLocalizedString("menu.testScroll", comment: ""), action: #selector(testScroll), keyEquivalent: "")
        test.target = self
        submenu.addItem(test)
        let trace = NSMenuItem(title: NSLocalizedString("menu.trace", comment: ""), action: #selector(traceEvents), keyEquivalent: "")
        trace.target = self
        submenu.addItem(trace)
        let refreshItem = NSMenuItem(title: NSLocalizedString("menu.recheck", comment: ""), action: #selector(restartTap), keyEquivalent: "")
        refreshItem.target = self
        submenu.addItem(refreshItem)
        let openPane = NSMenuItem(title: NSLocalizedString("menu.openAccessibility", comment: ""), action: #selector(openAccessibilityPane), keyEquivalent: "")
        openPane.target = self
        submenu.addItem(openPane)
        diagnostics.submenu = submenu
        menu.addItem(diagnostics)

        menu.addItem(.separator())

        let login = NSMenuItem(title: NSLocalizedString("menu.launchAtLogin", comment: ""), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        login.tag = 4
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func refresh() {
        guard let menu = statusItem?.menu else { return }
        menu.item(withTag: 1)?.state = store.value.enabled ? .on : .off
        menu.item(withTag: 2)?.title = statusLine()
        menu.item(withTag: 3)?.title = diagnosticsLine()
        menu.item(withTag: 4)?.state = LoginItem.isEnabled ? .on : .off
        statusItem?.button?.appearsDisabled = !store.value.enabled || !tap.status.isRunning
    }

    private func statusLine() -> String {
        if !Probes.isTrusted { return NSLocalizedString("menu.permissionRequired", comment: "") }
        // Note: CGPreflightPostEventAccess() can stay false while Accessibility is
        // granted (the grant covers posting), so it is reported in the status file
        // but must not gate the running state here - it misled us once.
        return tap.status.isRunning
            ? NSLocalizedString("menu.tapRunning", comment: "")
            : String(format: NSLocalizedString("menu.tap", comment: ""), tap.status.description)
    }

    private func diagnosticsLine() -> String {
        let d = tap.diagnostics
        return String(format: NSLocalizedString("menu.eventsSeen", comment: ""),
                      Int32(truncatingIfNeeded: d.events), eventName(d.lastType))
    }

    private func eventName(_ type: CGEventType) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .keyDown: return "keyDown"
        case .scrollWheel: return "scrollWheel"
        case .null: return "none"
        default: return "type \(type.rawValue)"
        }
    }

    // MARK: - Status file

    private func statusText() -> String {
        let s = store.value
        let d = tap.diagnostics
        let counts = tap.eventCounts
        let stats = engine.stats

        func count(_ types: [CGEventType]) -> UInt64 {
            types.reduce(0) { $0 + (counts[$1] ?? 0) }
        }

        let down = count([.leftMouseDown, .rightMouseDown, .otherMouseDown])
        let up = count([.leftMouseUp, .rightMouseUp, .otherMouseUp])
        let drag = count([.leftMouseDragged, .rightMouseDragged, .otherMouseDragged])

        var lines: [String] = []
        lines.append("mouseimp status")
        lines.append("updated: \(Self.timestamp())")
        lines.append("enabled: \(s.enabled)")
        lines.append("language: \(Bundle.main.preferredLocalizations.first ?? "?") of \(Array(Set(Bundle.main.localizations)).sorted().joined(separator: ","))")
        lines.append("trigger: \(s.triggerButton.title)")
        lines.append("modifiers: require=\(s.requireModifiers.label) disable=\(s.disableModifiers.label) slow=\(s.slowModifiers.label)")
        lines.append("speed: \(String(format: "%.2f", s.speed)) mode=\(s.speedMode.rawValue)"
                     + " k_v=\(String(format: "%.2f", s.velocityResponse)) k_a=\(String(format: "%.2f", s.accelerationBoost))"
                     + " v_ref=\(Int(s.velocityReference)) a_ref=\(Int(s.accelerationReference))"
                     + " ramp=\(String(format: "%.2f", s.distanceRamp)) d_ref=\(Int(s.distanceReference))"
                     + " smoothing=\(String(format: "%.2f", s.dynamicSmoothing))"
                     + " min=\(String(format: "%.2f", s.minMultiplier)) max=\(String(format: "%.2f", s.maxMultiplier))")
        lines.append("inertia: coast=\(s.coastEnabled) factor=\(String(format: "%.2f", s.coastFactor))"
                     + " start=\(Int(s.coastStartVelocity)) stop=\(Int(s.coastStopVelocity))"
                     + " window=\(String(format: "%.2f", s.coastVelocityWindow)) followsMode=\(s.coastFollowsSpeedMode)")
        lines.append("dynamics: \(String(format: "v=%.0f px/s a=%+.0f px/s2 m=%.2fx", stats.lastVelocity, stats.lastAcceleration, stats.lastMultiplier))")
        lines.append("cursor: freeze=\(s.freezeCursor) hand=\(s.showHandCursor) lineScroll=\(s.lineScroll)"
                     + " slowFactor=\(String(format: "%.2f", s.slowFactor))"
                     + " invertX=\(s.invertX) invertY=\(s.invertY) snapToAxis=\(s.snapToAxis)"
                     + " dragThreshold=\(String(format: "%.0f", s.dragThreshold))")
        lines.append("excludedApps: \(s.disabledBundles.count)")
        lines.append("trusted: \(Probes.isTrusted) canPostEvents: \(Probes.canPostEvents)")
        lines.append("tap: \(tap.status.description)")
        lines.append("watchdog: \(tap.watchdogInfo)")
        lines.append("targetCache: \(TargetCache.shared.diagnostics)")
        lines.append("events: total=\(d.events) last=\(eventName(d.lastType)) down=\(down) up=\(up) drag=\(drag) key=\(count([.keyDown])) wheel=\(count([.scrollWheel]))")
        lines.append("grabs: \(stats.grabs) scrolls: \(stats.scrolls) clicks: \(stats.clicks) suppressedClicks: \(stats.suppressedClicks)")
        lines.append("rejects: \(stats.rejects.isEmpty ? "none" : stats.rejects.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        lines.append("presses: \(Self.counters(stats.presses))")
        lines.append("passedThrough: \(Self.counters(stats.passedThrough))")
        lines.append("trace:")
        lines.append(contentsOf: EventTrace.shared.report())
        lines.append("lastGrab: \(stats.lastGrab)")
        lines.append("lastScroll: \(stats.lastScroll)")
        lines.append("posts:")
        for entry in WheelPoster.recentPosts(10) {
            lines.append("  \(entry)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// "b0=13 b3=4" style summary of a per button counter.
    private static func counters(_ dict: [Int64: Int]) -> String {
        if dict.isEmpty { return "none" }
        return dict.sorted { $0.key < $1.key }.map { "b\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        var settings = store.value
        settings.enabled.toggle()
        store.value = settings
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(store)
            let hosting = NSHostingView(rootView: AnyView(view))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "MouseImp - DirectScroll"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func restartTap() {
        ensureTapRunning()
    }

    @objc private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func testScroll() {
        // Give the user three seconds to move the pointer over something scrollable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let poster = WheelPoster()
            _ = poster.postScroll(dx: 0, dy: 200)
            _ = poster.postScroll(dx: 0, dy: -200)
        }
    }

    @objc private func traceEvents() {
        // Records every event type the system delivers (including the ones this app
        // does not handle) for 20 seconds, then writes them into the status file.
        EventTrace.shared.start(seconds: 20)
        Diagnostics.shared.writeNow()
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("menu.loginFailed.title", comment: "")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

}
