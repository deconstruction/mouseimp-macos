// Event trace: a short lived, passive (listen only) tap that records *every*
// event type the system delivers, including the ones this app does not handle.
//
// Why: a mouse button that does not arrive as a normal button event (some mice
// send their side buttons as HID "back"/"forward" controls, which the system turns
// into something other than a mouse button) cannot be consumed by a session level
// tap, and this is the only way to see what actually arrives. It is off by default,
// runs for a fixed number of seconds and only stores numbers in a ring - no
// formatting, no I/O, no allocation in the tap callback.

import CoreGraphics
import Foundation

struct TracedEvent {
    var type: UInt32 = 0
    var button: Int64 = -1
    var key: Int64 = -1
    var flags: UInt64 = 0
    var sourcePID: Int64 = -1
    var x: Double = 0
    var y: Double = 0
}

private func traceTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<EventTrace>.fromOpaque(refcon).takeUnretainedValue().record(type: type, event: event)
    }
    return Unmanaged.passUnretained(event) // passive: never consume
}

final class EventTrace {
    static let shared = EventTrace()

    private let lock = NSLock()
    private var entries = [TracedEvent](repeating: TracedEvent(), count: 64)
    private var writeIndex = 0
    private var stored = 0
    private var stopAt: CFAbsoluteTime = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopper: DispatchSourceTimer?

    private init() {}

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopAt > 0
    }

    var remaining: Double {
        lock.lock()
        defer { lock.unlock() }
        return max(0, stopAt - CFAbsoluteTimeGetCurrent())
    }

    /// Starts the trace and stops it automatically after `seconds`.
    func start(seconds: Double = 20) {
        stop()

        lock.lock()
        writeIndex = 0
        stored = 0
        stopAt = CFAbsoluteTimeGetCurrent() + seconds
        lock.unlock()

        // Everything except mouseMoved (by far the most frequent event, and not
        // interesting here).
        let mask = ~CGEventMask(0) & ~(CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue))

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                            place: .tailAppendEventTap,
                                            options: .listenOnly,
                                            eventsOfInterest: mask,
                                            callback: traceTapCallback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let port = created,
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                ready.signal()
                return
            }
            self.lock.lock()
            self.tap = port
            self.runLoopSource = source
            self.runLoop = CFRunLoopGetCurrent()
            self.lock.unlock()

            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "mouseimp.trace"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        _ = ready.wait(timeout: .now() + 3)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.stop() }
        stopper = timer
        timer.resume()
    }

    func stop() {
        stopper?.cancel()
        stopper = nil

        lock.lock()
        let tap = self.tap
        let source = self.runLoopSource
        let runLoop = self.runLoop
        self.tap = nil
        self.runLoopSource = nil
        self.runLoop = nil
        stopAt = 0
        lock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source, let runLoop { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Called on the trace tap thread: numbers only.
    fileprivate func record(type: CGEventType, event: CGEvent) {
        var entry = TracedEvent()
        entry.type = type.rawValue
        entry.button = event.getIntegerValueField(.mouseEventButtonNumber)
        entry.key = event.getIntegerValueField(.keyboardEventKeycode)
        entry.flags = event.flags.rawValue
        entry.sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        entry.x = event.location.x
        entry.y = event.location.y

        lock.lock()
        entries[writeIndex] = entry
        writeIndex = (writeIndex + 1) % entries.count
        stored = min(stored + 1, entries.count)
        lock.unlock()
    }

    /// Newest last, formatted for the status file (runs on the diagnostics queue).
    func report() -> [String] {
        lock.lock()
        let count = stored
        let index = writeIndex
        let copy = entries
        let running = stopAt > CFAbsoluteTimeGetCurrent()
        lock.unlock()

        guard count > 0 else { return ["  (nothing captured)"] }

        var lines: [String] = []
        if running {
            lines.append(String(format: "  (still running, %.0fs left)", remaining))
        }
        // Oldest to newest.
        let start = (index - count + copy.count) % copy.count
        for offset in 0..<count {
            let entry = copy[(start + offset) % copy.count]
            var parts: [String] = []
            parts.append("type=\(entry.type) \(Self.typeName(entry.type))")
            if entry.button >= 0 { parts.append("button=\(entry.button)") }
            if entry.key >= 0 { parts.append("key=\(entry.key)") }
            if entry.flags != 0 { parts.append(String(format: "flags=0x%llx", entry.flags)) }
            if entry.sourcePID > 0 { parts.append("source=\(entry.sourcePID)") }
            parts.append(String(format: "at=%.0f,%.0f", entry.x, entry.y))
            lines.append("  " + parts.joined(separator: " "))
        }
        return lines
    }

    static func typeName(_ raw: UInt32) -> String {
        switch raw {
        case 0: return "null"
        case 1: return "leftMouseDown"
        case 2: return "leftMouseUp"
        case 3: return "rightMouseDown"
        case 4: return "rightMouseUp"
        case 5: return "mouseMoved"
        case 6: return "leftMouseDragged"
        case 7: return "rightMouseDragged"
        case 8: return "keyDown"
        case 9: return "keyUp"
        case 10: return "flagsChanged"
        case 11: return "mouseEntered"
        case 12: return "mouseExited"
        case 13: return "kitDefined"
        case 14: return "sysDefined"
        case 15: return "appDefined"
        case 16: return "periodic"
        case 17: return "cursorUpdate"
        case 22: return "scrollWheel"
        case 23: return "tabletPointer"
        case 24: return "tabletProximity"
        case 25: return "otherMouseDown"
        case 26: return "otherMouseUp"
        case 27: return "otherMouseDragged"
        case 29: return "gesture"
        case 30: return "magnify"
        case 31: return "swipe"
        case 32: return "rotate"
        case 33: return "beginGesture"
        case 34: return "endGesture"
        default: return "unknown"
        }
    }
}
