// Small bridge between the settings window and the running app.
//
// The delegate fills these in at launch, so the window can trigger app level
// actions (restart the tap, run the event trace, open the status file) and read the
// live numbers without knowing anything about the delegate.

import Foundation

final class AppActions {
    static let shared = AppActions()

    var restartTap: () -> Void = {}
    var traceEvents: () -> Void = {}
    var testScroll: () -> Void = {}
    var statusFilePath: () -> String = { "" }

    /// One line with the live dynamics, for the Advanced tab.
    var speedLine: () -> String = { "no data yet" }

    /// The same text that is written to status.txt, for the Diagnostics tab.
    var statusText: () -> String = { "" }

    private init() {}
}
