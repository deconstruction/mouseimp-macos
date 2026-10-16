// Status file for the app: what the event tap sees, whether the engine is
// grabbing, what was posted. Written to
//   ~/Library/Application Support/MouseImp/status.txt
// once a second (and only when something changed), so the state can be checked
// from outside the app - by a script or by a person reading the file.

import Foundation

final class Diagnostics {
    static let shared = Diagnostics()

    private let queue = DispatchQueue(label: "mouseimp.diagnostics")
    private var timer: DispatchSourceTimer?
    private var provider: (() -> String)?
    private var lastWritten = ""

    private let fileURL: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MouseImp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("status.txt")
    }()

    var path: String { fileURL.path }

    /// `provider` is called on the diagnostics queue once a second.
    func start(provider: @escaping () -> String) {
        self.provider = provider
        writeNow()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let provider = self.provider else { return }
            self.write(provider())
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func writeNow() {
        guard let provider else { return }
        let text = provider()
        queue.async { [weak self] in self?.write(text) }
    }

    private func write(_ text: String) {
        guard text != lastWritten else { return }
        lastWritten = text
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("MouseImp: cannot write diagnostics: \(error)")
        }
    }
}
