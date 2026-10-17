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
app.delegate = delegate
// Menu bar only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
