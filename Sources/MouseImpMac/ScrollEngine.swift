// DirectScroll: right (or middle / left) button press starts a "grab"; moving the
// pointer while the button is held turns that movement into scroll wheel events
// for the window under the pointer - the direct macOS counterpart of MouseImp's
// DirectScroll, including its options (speed, slow-down key, inverted axes,
// bidirectional / axis locked, cursor feedback).
//
// The class runs on the event tap thread; settings are read through a lock, all
// decisions for one gesture are taken from a snapshot so the values cannot change
// half way through.

import AppKit
import CoreGraphics
import Foundation

final class ScrollEngine {

    // MARK: - Types

    private enum Phase { case idle, pressed, grabbing }

    private enum AxisLock { case none, horizontal, vertical }

    private struct Sample {
        var dx: Double = 0
        var dy: Double = 0
        var time: CFTimeInterval = 0
    }

    // MARK: - Dependencies

    let poster = WheelPoster()
    private let lock = NSLock()
    private var settings = Settings()

    /// Called on grab start / stop; always on the event tap thread.
    var onGrabChanged: ((_ active: Bool, _ at: CGPoint) -> Void)?

    // MARK: - Gesture state (tap thread only)

    private var phase: Phase = .idle
    private var trigger: TriggerButton = .right
    private var anchor: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var pressTime: CFTimeInterval = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var axisLock: AxisLock = .none
    private var accX: Double = 0
    private var accY: Double = 0
    private var travelX: Double = 0
    private var travelY: Double = 0
    private var pointerFrozen = false

    private var samples = [Sample](repeating: Sample(), count: 24)
    private var sampleIndex = 0

    private var coastTimer: DispatchSourceTimer?
    private var coastVelocity: CGPoint = .zero
    private var coastMomentumActive = false
    private let coastLock = NSLock()
    private let coastQueue = DispatchQueue(label: "mouseimp.coast")

    // MARK: - Settings access

    /// Counters for the status file (tap thread writes, main thread reads).
    struct Stats {
        var grabs: Int = 0
        var scrolls: Int = 0
        var clicks: Int = 0
        /// Clicks of extra buttons (Button 4 and up) that were consumed instead of
        /// being handed back to the application.
        var suppressedClicks: Int = 0
        /// Every mouse down this app received, by button number - proof of what
        /// actually arrives as a mouse button event.
        var presses: [Int64: Int] = [:]
        /// Mouse downs that were handed back to the application (not consumed).
        var passedThrough: [Int64: Int] = [:]
        var lastGrab: String = "-"
        var lastScroll: String = "-"
        /// Why a press did not start a grab, e.g. "notTriggerButton" or "ownApp".
        var rejects: [String: Int] = [:]
    }

    private var statsValue = Stats()
    private let statsLock = NSLock()

    var stats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return statsValue
    }

    private func updateStats(_ body: (inout Stats) -> Void) {
        statsLock.lock()
        body(&statsValue)
        statsLock.unlock()
    }

    private func reject(_ reason: String) {
        updateStats { stats in
            stats.rejects[reason, default: 0] += 1
        }
    }

    func update(settings: Settings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    private func snapshot() -> Settings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    // MARK: - Event entry point

    /// Returns the event to hand on, or `nil` when the event is consumed.
    func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if WheelPoster.isOurs(event) { return event }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Any press interrupts inertia, even one that is then refused.
            stopCoast(momentumEnd: true)
            return mouseDown(type: type, event: event)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return mouseDragged(type: type, event: event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return mouseUp(type: type, event: event)
        case .keyDown:
            // Escape cancels a running grab, any key stops coasting.
            stopCoast(momentumEnd: true)
            if phase == .grabbing, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                finishGrab(coast: false)
                return nil
            }
            return event
        case .scrollWheel:
            // A real wheel event while coasting: the user took over.
            if coasting { stopCoast(momentumEnd: true) }
            return event
        default:
            return event
        }
    }

    // MARK: - Mouse down

    private func mouseDown(type: CGEventType, event: CGEvent) -> CGEvent? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let decision = mouseDownDecision(type: type, event: event, button: button)
        updateStats { stats in
            stats.presses[button, default: 0] += 1
            if decision != nil { stats.passedThrough[button, default: 0] += 1 }
        }
        return decision
    }

    private func mouseDownDecision(type: CGEventType, event: CGEvent, button: Int64) -> CGEvent? {
        let s = snapshot()
        guard s.enabled else { reject("disabled"); return event }
        guard type == s.triggerButton.downType else {
            reject("button\(button)!=trigger(\(s.triggerButton.buttonNumber))")
            return event
        }
        if button != s.triggerButton.buttonNumber {
            reject("extraButton\(button)")
            return event
        }

        let flags = ModifierMask.current(from: event.flags)
        if !s.requireModifiers.isEmpty, !flags.isSuperset(of: s.requireModifiers) {
            reject("requireModifiers\(s.requireModifiers.label)")
            return event
        }
        if !s.disableModifiers.isEmpty, !flags.intersection(s.disableModifiers).isEmpty {
            reject("disabledByModifier")
            return event
        }

        let point = event.location

        // Everything below is served from a cache that a background queue fills in
        // (window, layer, owning application, scroll bars): the event tap must never
        // make an inter process call itself, or the whole input stream stalls while
        // it waits. A stale or mismatched cache means "unknown" and the grab
        // proceeds - the checks are safety nets, not gates.
        //
        // For an extra button (Button 4 and up) the press is always taken: its
        // default action is exactly what the user wants to get rid of, so a press
        // that happens to land on system chrome or on a scroll bar must still be
        // consumed. Applications the user excluded stay untouched.
        let isExtraButton = s.triggerButton.number >= 3
        if let target = TargetCache.shared.snapshot, target.matches(point, maxAge: 0.5) {
            if target.pid == getpid() { reject("ownApp"); return event }
            if let bundle = target.bundleID, s.disabledBundles.contains(bundle) {
                reject("excludedApp")
                return event
            }
            if !isExtraButton {
                if target.layer != 0 { reject("systemLayer\(target.layer)"); return event }
                if s.skipScrollbars,
                   target.scrollbarRects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
                    reject("onScrollbar")
                    return event
                }
            }
        } else {
            reject("targetUnknown")
        }

        trigger = s.triggerButton
        anchor = point
        lastPoint = point
        pressTime = CFAbsoluteTimeGetCurrent()
        axisLock = .none
        accX = 0
        accY = 0
        travelX = 0
        travelY = 0
        sampleIndex = 0
        for i in samples.indices { samples[i] = Sample() }
        phase = .pressed

        // The press is consumed; if it turns out to be a plain click we re-post it
        // on mouse up so context menus and middle click keep working.
        return nil
    }

    // MARK: - Mouse drag

    private func mouseDragged(type: CGEventType, event: CGEvent) -> CGEvent? {
        guard phase != .idle, type == trigger.draggedType else { return event }
        let s = snapshot()
        let point = event.location

        if phase == .pressed {
            let travel = hypot(point.x - anchor.x, point.y - anchor.y)
            guard travel >= s.dragThreshold else { return nil }
            beginGrab(settings: s)
        }

        applyDrag(to: point, flags: event.flags, settings: s)
        return nil
    }

    // MARK: - Mouse up

    private func mouseUp(type: CGEventType, event: CGEvent) -> CGEvent? {
        guard phase != .idle, type == trigger.upType else { return event }
        let s = snapshot()

        switch phase {
        case .pressed:
            // A press that never became a drag. For the three standard buttons the
            // click is handed back to the application, so context menus, the middle
            // click and double clicks keep working.
            //
            // For an extra button (Button 4 and up) the click is swallowed instead:
            // those buttons normally carry a system action (back/forward, Mission
            // Control, a keyboard shortcut bound by the user), and that action must
            // not fire when the same button is also the DirectScroll trigger. The
            // press and its release are consumed, nothing is replayed.
            if trigger.number <= 2 {
                poster.postClick(button: trigger, at: anchor)
                updateStats { $0.clicks += 1 }
            } else {
                updateStats { $0.suppressedClicks += 1 }
            }
            phase = .idle
        case .grabbing:
            finishGrab(coast: s.coastEnabled)
        case .idle:
            break
        }
        return nil
    }

    // MARK: - Grab lifecycle

    private func beginGrab(settings s: Settings) {
        phase = .grabbing
        accX = 0
        accY = 0
        travelX = 0
        travelY = 0
        axisLock = .none
        lastPoint = anchor
        pointerFrozen = false

        updateStats { stats in
            stats.grabs += 1
            stats.lastGrab = String(format: "%.0f,%.0f (%@)", anchor.x, anchor.y, trigger.title)
        }

        if s.freezeCursor {
            // Keep the pointer where the gesture started while still reading motion.
            pointerFrozen = true
            poster.postMouseMoved(to: anchor)
        }
        onGrabChanged?(true, anchor)
    }

    private func finishGrab(coast: Bool) {
        phase = .idle
        if pointerFrozen {
            poster.postMouseMoved(to: anchor)
            pointerFrozen = false
        }
        onGrabChanged?(false, anchor)

        if coast, let velocity = recentVelocity() {
            startCoast(velocity: velocity, settings: snapshot())
        }
    }

    // MARK: - The drag to scroll conversion

    private func applyDrag(to point: CGPoint, flags eventFlags: CGEventFlags, settings s: Settings) {
        // Pointer movement in screen coordinates (y grows downwards).
        var dxP = point.x - lastPoint.x
        var dyP = point.y - lastPoint.y

        if pointerFrozen {
            // The pointer was pinned back to the anchor, so the next hardware
            // report arrives relative to the anchor again.
            lastPoint = anchor
            poster.postMouseMoved(to: anchor)
        } else {
            lastPoint = point
        }

        // A single runaway report (screen edge, display switch) must not fling the
        // content: clamp it (a single runaway report must not fling the content).
        let limit = 1000.0
        dxP = max(-limit, min(limit, dxP))
        dyP = max(-limit, min(limit, dyP))

        // Net pointer displacement for the axis lock. Tracked explicitly (rather
        // than as anchor - lastPoint) so it also works with freezeCursor, where
        // lastPoint is pinned back to the anchor every step.
        travelX += dxP
        travelY += dyP

        // Clamp defensively: the settings offer 0.2x .. 10x, but a hand edited
        // preference or an old value must not be able to produce an absurd
        // multiplier.
        let speed = min(max(s.speed, 0.05), 10.0)
        var dx = dxP * speed
        var dy = dyP * speed
        if s.invertX { dx = -dx }
        if s.invertY { dy = -dy }

        // Modifiers come from this event's own flags: the alternative,
        // CGEventSource.flagsState(), is a call into the window server and has no
        // business happening in the event tap.
        let flags = ModifierMask.current(from: eventFlags)
        if !s.slowModifiers.isEmpty, !flags.intersection(s.slowModifiers).isEmpty {
            dx *= s.slowFactor
            dy *= s.slowFactor
        }

        updateAxisLock(settings: s)
        switch axisLock {
        case .horizontal: dy = 0
        case .vertical: dx = 0
        case .none: break
        }

        // Keep the sub-pixel remainder so slow drags still move the content.
        accX += dx
        accY += dy
        let outX = accX.rounded(.towardZero)
        let outY = accY.rounded(.towardZero)
        accX -= outX
        accY -= outY

        guard outX != 0 || outY != 0 else { return }

        // "Content follows the pointer": pointer down scrolls up (positive wheel),
        // pointer right moves the content right (negative horizontal wheel).
        let wheelX = outX == 0 ? 0 : -outX
        let wheelY = outY

        if poster.postScroll(dx: wheelX, dy: wheelY, lines: s.lineScroll) {
            lastScrollTime = CFAbsoluteTimeGetCurrent()
            record(dx: wheelX, dy: wheelY)
            let description = String(format: "dx=%.1f dy=%.1f", wheelX, wheelY)
            updateStats { stats in
                stats.scrolls += 1
                stats.lastScroll = description
            }
        }
    }

    private func updateAxisLock(settings s: Settings) {
        // Thresholds: 10 px of travel before anything is locked (below that the
        // direction is not clear yet), a 1.5x lead to claim an axis, and a 2x lead
        // of the other axis to take it over. MouseImp used the system drag rectangle
        // (SM_CXDRAG/SM_CYDRAG) for the same decisions; the rule here is the simplest
        // one that behaves the same in practice and can be reasoned about.
        guard s.snapToAxis else {
            axisLock = .none
            return
        }
        let travelX = abs(self.travelX)
        let travelY = abs(self.travelY)

        switch axisLock {
        case .none:
            if travelX > 10, travelX > travelY * 1.5 { axisLock = .horizontal }
            else if travelY > 10, travelY > travelX * 1.5 { axisLock = .vertical }
        case .horizontal:
            // Allow switching once the other axis clearly dominates.
            if travelY > travelX * 2.0 { axisLock = .vertical }
        case .vertical:
            if travelX > travelY * 2.0 { axisLock = .horizontal }
        }
    }

    // MARK: - Coasting (inertia)

    private func record(dx: Double, dy: Double) {
        samples[sampleIndex] = Sample(dx: dx, dy: dy, time: CFAbsoluteTimeGetCurrent())
        sampleIndex = (sampleIndex + 1) % samples.count
    }

    /// Average velocity (points per second) of the last few scroll steps.
    private func recentVelocity() -> CGPoint? {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScrollTime < 0.12 else { return nil }

        let recent = samples.filter { $0.time > 0 && now - $0.time < 0.12 }
        guard recent.count >= 2 else { return nil }

        let sumX = recent.reduce(0) { $0 + $1.dx }
        let sumY = recent.reduce(0) { $0 + $1.dy }
        let oldest = recent.map { $0.time }.min() ?? now
        let span = max(now - oldest, 0.016)

        let velocity = CGPoint(x: sumX / span, y: sumY / span)
        guard hypot(velocity.x, velocity.y) > 60 else { return nil }
        return velocity
    }

    private func startCoast(velocity: CGPoint, settings s: Settings) {
        // 60 Hz momentum: v *= coastFactor^(dt*60) makes the decay independent of
        // timer jitter, and the momentum phase tells the application that this is
        // inertia (so AppKit scroll views keep their own smoothing consistent).
        // Chosen over a spring/drag model because it maps to one slider ("friction")
        // and needs no calibration; stopCoast() ends the phase properly.
        stopCoast(momentumEnd: false)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)

        coastLock.lock()
        coastVelocity = velocity
        coastMomentumActive = false
        coastLock.unlock()

        var first = true
        var last = CFAbsoluteTimeGetCurrent()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let dt = min(now - last, 0.05)
            last = now

            self.coastLock.lock()
            let decay = pow(s.coastFactor, dt * 60.0)
            self.coastVelocity.x *= decay
            self.coastVelocity.y *= decay
            let velocity = self.coastVelocity
            self.coastLock.unlock()

            let dx = velocity.x * dt
            let dy = velocity.y * dt
            if abs(dx) >= 0.5 || abs(dy) >= 0.5 {
                let phase: WheelPoster.Momentum = first ? .begin : .continuous
                self.poster.postScroll(dx: dx, dy: dy, momentum: phase, lines: s.lineScroll)
                first = false
                self.coastLock.lock()
                self.coastMomentumActive = true
                self.coastLock.unlock()
            }
            if hypot(velocity.x, velocity.y) < 40 {
                self.stopCoast(momentumEnd: true)
            }
        }
        coastQueue.async {
            self.coastLock.lock()
            self.coastTimer = timer
            self.coastLock.unlock()
        }
        timer.resume()
    }

    private func stopCoast(momentumEnd: Bool) {
        coastLock.lock()
        let timer = coastTimer
        let wasActive = coastMomentumActive
        coastTimer = nil
        coastMomentumActive = false
        coastVelocity = .zero
        coastLock.unlock()

        guard let timer else { return }
        timer.setEventHandler {}
        timer.cancel()
        if momentumEnd, wasActive {
            // Tell the target application the momentum phase is over.
            poster.postScroll(dx: 0, dy: 0, momentum: .end)
        }
    }

    /// True while inertia is being posted. Reads the timer handle under the coast
    /// lock so it can be called from the tap thread without racing the writer.
    private var coasting: Bool {
        coastLock.lock()
        defer { coastLock.unlock() }
        return coastTimer != nil
    }

    // MARK: - Diagnostics

    var isGrabbing: Bool { phase == .grabbing }
}
