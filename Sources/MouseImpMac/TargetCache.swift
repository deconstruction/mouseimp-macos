// Everything the engine needs to know about the window under the pointer, worked
// out on a *background* queue.
//
// Never call this from the event tap: AXUIElementCopyElementAtPosition and the
// window list are inter process calls that can take milliseconds - or seconds,
// when the target application is busy - and an active session tap stalls the whole
// input stream for as long as its callback runs, so this work belongs on a
// background queue.

import AppKit
import ApplicationServices
import CoreGraphics

struct TargetSnapshot {
    var point: CGPoint
    var pid: pid_t
    var bundleID: String?
    var layer: Int
    var scrollbarRects: [CGRect]
    var timestamp: CFTimeInterval

    func matches(_ point: CGPoint, maxAge: CFTimeInterval) -> Bool {
        let age = CFAbsoluteTimeGetCurrent() - timestamp
        if age > maxAge || age < 0 { return false }
        return abs(self.point.x - point.x) <= 3 && abs(self.point.y - point.y) <= 3
    }
}

final class TargetCache {
    static let shared = TargetCache()

    private let lock = NSLock()
    private var value: TargetSnapshot?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mouseimp.target", qos: .utility)

    /// Set from the settings; when off, the (slower) AX scroll bar probe is skipped.
    private var lookForScrollbars = true
    /// How long the last refresh took, for the status file.
    private var lastRefreshCost: Double = 0
    /// When the cache was last refreshed successfully.
    private var lastRefreshTime: CFAbsoluteTime = 0

    private init() {}

    /// Cheap, lock only - safe to call from the event tap.
    var snapshot: TargetSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        let age = lastRefreshTime > 0 ? CFAbsoluteTimeGetCurrent() - lastRefreshTime : -1
        return String(format: "age=%.2fs cost=%.1fms scrollbars=%d",
                      age, lastRefreshCost * 1000,
                      value?.scrollbarRects.count ?? 0)
    }

    func setLookForScrollbars(_ on: Bool) {
        lock.lock()
        lookForScrollbars = on
        lock.unlock()
    }

    func start(interval: Double = 0.25) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Background refresh

    private func refresh() {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            lock.lock()
            lastRefreshCost = CFAbsoluteTimeGetCurrent() - started
            lastRefreshTime = CFAbsoluteTimeGetCurrent()
            lock.unlock()
        }

        // Where is the pointer right now? (cheap, local)
        guard let point = CGEvent(source: nil)?.location else { return }
        guard let target = Probes.windowUnderCursor(point) else { return }

        var rects: [CGRect] = []
        lock.lock()
        let wantScrollbars = lookForScrollbars
        lock.unlock()
        if wantScrollbars, target.layer == 0, target.pid != getpid() {
            rects = Probes.scrollbarRects(at: point)
        }

        let snapshot = TargetSnapshot(point: point,
                                      pid: target.pid,
                                      bundleID: target.bundleID,
                                      layer: target.layer,
                                      scrollbarRects: rects,
                                      timestamp: CFAbsoluteTimeGetCurrent())
        lock.lock()
        value = snapshot
        lock.unlock()
    }
}
