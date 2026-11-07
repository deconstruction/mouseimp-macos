// MouseImp for macOS - DirectScroll port.
//
// Entry point. Uses AppKit directly (no SwiftUI scene lifecycle) so the app can be
// assembled from a SwiftPM build into a plain .app bundle by Scripts/build-app.sh.

import AppKit

// Headless self test: MouseImp.app/Contents/MacOS/MouseImp --selftest
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
// Development aid: open the settings window right away (used to check the UI
// without clicking through the menu bar).
delegate.openSettingsOnLaunch = CommandLine.arguments.contains("--show-settings")
delegate.openAboutOnLaunch = CommandLine.arguments.contains("--show-about")
// Development aid: --set-diagnostics on|off flips the status file switch through
// the settings store, exactly as the menu item does.
if let index = CommandLine.arguments.firstIndex(of: "--set-diagnostics"),
   index + 1 < CommandLine.arguments.count {
    switch CommandLine.arguments[index + 1] {
    case "on": delegate.diagnosticsOnLaunch = true
    case "off": delegate.diagnosticsOnLaunch = false
    default: break
    }
}
app.delegate = delegate
// Menu bar only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
