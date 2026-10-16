// Event tap plumbing: the macOS counterpart of MouseImp's global mouse hook
// (SetWindowsHookEx(WH_MOUSE)) plus its message forwarding.
//
// The tap is installed at kCGSessionEventTap with the default (suppressing)
// options on a dedicated thread with its own run loop, and re-enabled whenever the
// system switches it off because a callback took too long.
//
// WHY THE CALLBACK MUST STAY TRIVIAL: an active session tap is asked for a decision
// before an event continues, so everything on the machine (clicks, keys) waits for
// our callback to return. A blocking callback - an Accessibility call to a busy
// application, for instance - stalls input for the whole session while the pointer
// keeps moving, because pointer motion is not part of the mask. Therefore: no I/O
// here, all lookups through TargetCache, and the watchdog below as a last resort.

import CoreGraphics
import Foundation

private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.process(proxy: proxy, type: type, event: event)
}

final class EventTapController {

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
        case interrupted(String)
        /// A callback did not return in time; the watchdog took the tap down so the
        /// input stream of the whole session keeps flowing.
        case blocked(String)

        var description: String {
            switch self {
            case .stopped: return "stopped"
            case .running: return "running"
            case .failed(let reason): return "failed: \(reason)"
            case .interrupted(let reason): return "interrupted: \(reason)"
            case .blocked(let reason): return "blocked: \(reason)"
            }
        }

        var isRunning: Bool { self == .running }
    }

    private let engine: ScrollEngine
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let stateLock = NSLock()
    private var statusValue: Status = .stopped
    private var eventCount: UInt64 = 0
    private var lastEventType: CGEventType = .null
    private var counts: [CGEventType: UInt64] = [:]

    // Watchdog: a session event tap must answer quickly or the whole input stream
    // of the machine waits behind it. If a callback does not come back in
    // `watchdogLimit` seconds the tap is disabled (which releases the stream) and,
    // unless it happened twice inside a minute, reinstalled two seconds later.
    private var callbackStarted: CFAbsoluteTime = 0
    private var callbackInFlight = false
    private var callbackEpoch: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "mouseimp.watchdog", qos: .userInitiated)
    private let watchdogLimit: CFAbsoluteTime = 1.0
    private var watchdogFires: [CFAbsoluteTime] = []
    private var watchdogTrips = 0
    private var lastWatchdogAction: String = "-"

    /// Notified (on an arbitrary thread) whenever the tap state changes.
    var onStateChange: ((Status) -> Void)?

    init(engine: ScrollEngine) {
        self.engine = engine
    }

    var status: Status {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statusValue
    }

    var diagnostics: (events: UInt64, lastType: CGEventType, status: Status) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (eventCount, lastEventType, statusValue)
    }

    /// How many events of each tapped type have arrived.
    var eventCounts: [CGEventType: UInt64] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return counts
    }

    var watchdogInfo: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return "trips=\(watchdogTrips) last=\(lastWatchdogAction)"
    }

    /// Every event the engine may need: the three mouse button families, keys
    /// (Escape cancels a grab) and wheel events (they interrupt coasting).
    ///
    /// mouseMoved is deliberately absent: it is by far the most frequent event, the
    /// engine does not need it, and every event we ask for has to pass through our
    /// callback. Drags, not moves, are what a held button produces.
    static var eventMask: CGEventMask {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .keyDown, .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    // MARK: - Lifecycle

    /// Installs the tap and returns once it is live (or failed).
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let alreadyStarted = tap != nil
        stateLock.unlock()
        guard !alreadyStarted else { return true }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let mask = Self.eventMask
            let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                            place: .headInsertEventTap,
                                            options: CGEventTapOptions(rawValue: 0)!, // active filter, not listen only
                                            eventsOfInterest: mask,
                                            callback: eventTapCallback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let port = created else {
                self.setState(.failed("CGEventTapCreate returned nil (Accessibility permission?)"))
                ready.signal()
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                self.setState(.failed("could not create run loop source"))
                ready.signal()
                return
            }

            self.stateLock.lock()
            self.tap = port
            self.runLoopSource = source
            self.runLoop = CFRunLoopGetCurrent()
            self.stateLock.unlock()

            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.setState(.running)
            self.startWatchdog()
            ready.signal()

            CFRunLoopRun()
        }
        thread.name = "mouseimp.eventtap"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()

        guard ready.wait(timeout: .now() + 5) == .success else {
            setState(.failed("event tap thread did not answer"))
            return false
        }
        return status.isRunning
    }

    func stop() {
        stopWatchdog()
        stateLock.lock()
        let tap = self.tap
        let source = self.runLoopSource
        let runLoop = self.runLoop
        self.tap = nil
        self.runLoopSource = nil
        self.runLoop = nil
        stateLock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(runLoop ?? CFRunLoopGetMain(), source, .commonModes) }
        if let runLoop { CFRunLoopStop(runLoop) }
        setState(.stopped)
    }

    /// Called after the Accessibility permission was granted.
    func restart() {
        stop()
        start()
    }

    // MARK: - Callback

    fileprivate func process(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        stateLock.lock()
        eventCount &+= 1
        lastEventType = type
        counts[type, default: 0] &+= 1
        callbackStarted = CFAbsoluteTimeGetCurrent()
        callbackEpoch &+= 1
        let epoch = callbackEpoch
        let isDisabledNotification = (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput)
        if !isDisabledNotification { callbackInFlight = true }
        stateLock.unlock()

        defer {
            // Clear the flag only if this is still the newest callback: after a
            // watchdog restart the old (blocked) callback runs on a dead thread and
            // must not clear the flag of the callback on the new one.
            stateLock.lock()
            if epoch == callbackEpoch { callbackInFlight = false }
            stateLock.unlock()
        }

        switch type {
        case .tapDisabledByTimeout:
            reEnable(reason: "system disabled the tap (timeout)")
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            reEnable(reason: "tap disabled by user input")
            return Unmanaged.passUnretained(event)
        default:
            // Any normal event means the tap works again after a timeout.
            stateLock.lock()
            let current = statusValue
            stateLock.unlock()
            if case .interrupted = current { setState(.running) }
            break
        }

        if let out = engine.handle(type: type, event: event) {
            return Unmanaged.passUnretained(out)
        }
        return nil // consumed
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stateLock.lock()
        let alreadyRunning = watchdog != nil
        stateLock.unlock()
        guard !alreadyRunning else { return }

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        stateLock.lock()
        watchdog = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopWatchdog() {
        stateLock.lock()
        let timer = watchdog
        watchdog = nil
        callbackInFlight = false
        stateLock.unlock()
        timer?.cancel()
    }

    private func watchdogTick() {
        let now = CFAbsoluteTimeGetCurrent()

        stateLock.lock()
        let inFlight = callbackInFlight
        let started = callbackStarted
        stateLock.unlock()

        guard inFlight, started > 0, now - started > watchdogLimit else { return }

        // A callback is stuck: take the tap down so the session input stream is not
        // held behind it any longer.
        stateLock.lock()
        let tap = self.tap
        watchdogFires.append(now)
        watchdogFires.removeAll { now - $0 > 60 }
        let fires = watchdogFires.count
        watchdogTrips += 1
        lastWatchdogAction = String(format: "callback stuck %.1fs, tap disabled @%.0f", now - started, now)
        stateLock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        setState(.blocked(String(format: "a callback did not return for %.1fs, tap disabled to keep input alive", now - started)))

        guard fires <= 2 else {
            stateLock.lock()
            lastWatchdogAction += " - staying off, restart from the menu"
            stateLock.unlock()
            return
        }

        // Reinstall the tap from a clean thread, but never more than twice a minute.
        watchdogQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.statusValue
            self.stateLock.unlock()
            guard case .blocked = current else { return }
            self.restart()
        }
    }

    private func reEnable(reason: String) {
        stateLock.lock()
        let tap = self.tap
        stateLock.unlock()
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        setState(.interrupted(reason))
    }

    private func setState(_ new: Status) {
        stateLock.lock()
        let changed = statusValue != new
        statusValue = new
        stateLock.unlock()
        if changed { onStateChange?(new) }
    }
}
