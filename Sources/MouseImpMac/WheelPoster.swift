// Synthesises scroll wheel events (and the small number of mouse events the
// engine needs), the macOS counterpart of MouseImp's WM_MOUSEWHEEL emulation.
//
// The recipe, field by field:
//   * a private CGEventSource, tagged through kCGEventSourceUserData so the
//     engine can recognise - and ignore - its own events,
//   * CGEventCreateScrollWheelEvent() in *pixel* units (which is what makes the
//     target app scroll smoothly instead of in wheel notches),
//   * the precise value written into kCGScrollWheelEventFixedPtDeltaAxis1/2 as a
//     double, while kCGScrollWheelEventPointDeltaAxis1/2 keeps the integer part,
//   * CGEventPost(kCGSessionEventTap), which routes the wheel to the window under
//     the pointer - the same window a real wheel would scroll.
//
// Why the tag: our own posted events come back through our tap, so without the tag
// the replayed click would start another grab (an infinite loop) and the momentum
// events would be treated as user input.
//
// Why pixel units plus the fixed point double: pixel events make the target use
// scrollingDeltaX/Y (precise deltas) and the double field carries the fraction of a
// pixel the integer field has to drop, so slow drags still move the content.
//
// Why kCGScrollWheelEventIsContinuous: it tells AppKit the event comes from a
// trackpad-like device rather than a notched wheel, which is the smooth path.
// Scroll phase (begun/changed/ended) is intentionally *not* set: applications that
// wait for a matching "ended" can get stuck when one is missed. Momentum phase is
// set while coasting, because then it really is momentum.
//
// All details, alternatives and the reasons against them: macos/Notes/design.md.

import CoreGraphics
import Foundation

final class WheelPoster {
    /// Our events carry this tag in kCGEventSourceUserData.
    static let marker: Int64 = 0x4D49_4D50 // "MIMP"

    /// Momentum phase reported while coasting. Spelled out because the imported
    /// CGMomentumScrollPhase cases are awkward in Swift.
    enum Momentum {
        case begin, continuous, end

        var rawValue: Int64 {
            switch self {
            case .begin: return 1
            case .continuous: return 2
            case .end: return 3
            }
        }
    }

    private let source: CGEventSource?

    /// How many pixels one wheel line is worth when `lineScroll` is on.
    private let pixelsPerLine: Double = 16

    init() {
        source = CGEventSource(stateID: .privateState)
        source?.userData = Self.marker
    }

    /// Scroll the window under the pointer.
    /// - Parameters:
    ///   - dx: horizontal pixels (positive = to the right).
    ///   - dy: vertical pixels (positive = towards the top, like a wheel notch up).
    ///   - momentum: phase to report while coasting, `nil` for a normal event.
    ///   - lines: send line based deltas instead of pixel based ones.
    @discardableResult
    func postScroll(dx: Double, dy: Double,
                    momentum: Momentum? = nil,
                    lines: Bool = false) -> Bool {
        guard let source else { return false }
        if abs(dx) < 0.5, abs(dy) < 0.5, momentum == nil { return false }

        // Pixel units by default; the app then reads scrollingDeltaY/X.
        let units: CGScrollEventUnit = lines ? .line : .pixel
        let (h, v): (Int32, Int32) = lines
            ? (Int32((dx / pixelsPerLine).rounded(.towardZero)),
               Int32((dy / pixelsPerLine).rounded(.towardZero)))
            : (Int32(dx.rounded(.towardZero)), Int32(dy.rounded(.towardZero)))
        if h == 0 && v == 0 {
            // Sub-pixel remainder only (or a pure phase notification): report the
            // precise value through the fixed point fields so nothing is lost.
            guard let ev = CGEvent(scrollWheelEvent2Source: source, units: units,
                                  wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return false }
            tag(ev)
            ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            applyMomentum(ev, momentum)
            note(String(format: "scroll dx=%.2f dy=%.2f lines=%d", dx, dy, lines ? 1 : 0))
            ev.post(tap: .cgSessionEventTap)
            return true
        }

        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: units,
                              wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0) else { return false }
        tag(ev)

        if !lines {
            // Split the value: integer part in the point delta, the full
            // fractional value in the fixed point delta.
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(v))
            ev.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(h))
            ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        // Line units already carry the (correctly signed) line deltas through
        // `wheel1`/`wheel2`: the line count is "dy / 16" and nothing here is
        // negated - `kCGScrollWheelEventDeltaAxis1/2` must keep the same sign as the
        // pixel path, or line mode scrolls in the wrong direction.

        applyMomentum(ev, momentum)
        note(String(format: "scroll dx=%.2f dy=%.2f lines=%d", dx, dy, lines ? 1 : 0))
        ev.post(tap: .cgSessionEventTap)
        return true
    }

    /// Post a plain mouse click (used when a press turned out to be a click, not
    /// a scroll: the original press was swallowed by the tap).
    func postClick(button: TriggerButton, at point: CGPoint, clickState: Int64 = 1) {
        guard let source else { return }

        func make(_ type: CGEventType) -> CGEvent? {
            guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: button.cgButton) else { return nil }
            tag(ev)
            // cgButton only expresses left/right/center; the exact button number
            // (including the extra ones) lives in this field.
            ev.setIntegerValueField(.mouseEventButtonNumber, value: button.buttonNumber)
            ev.setIntegerValueField(.mouseEventClickState, value: clickState)
            return ev
        }

        make(button.downType)?.post(tap: .cgSessionEventTap)
        make(button.upType)?.post(tap: .cgSessionEventTap)
        note(String(format: "click %@ at %.0f,%.0f", button.title, point.x, point.y))
    }

    /// Move the pointer (used to pin it while `freezeCursor` is on).
    func postMouseMoved(to point: CGPoint) {
        guard let source else { return }
        guard let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        tag(ev)
        ev.post(tap: .cgSessionEventTap)
        note(String(format: "move %.0f,%.0f", point.x, point.y))
    }

    /// Change the reported momentum phase of an *incoming* event. Kept for parity
    /// with the Windows original (which rewrites the wheel delta of real events)
    /// and used by tools built on top of this poster.
    func setMomentumPhase(_ event: CGEvent, _ phase: Momentum) {
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.rawValue)
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    // MARK: - Post log (diagnostics and self test)

    private var postLogInternal: [String] = []
    private let logLock = NSLock()

    private static var sharedLog: [String] = []
    private static let sharedLogLock = NSLock()

    /// Everything this poster has sent, newest last (and cleared).
    func drainLog() -> [String] {
        logLock.lock()
        defer { logLock.unlock() }
        let log = postLogInternal
        postLogInternal.removeAll()
        return log
    }

    /// The last few events posted by any poster in this process.
    static func recentPosts(_ count: Int = 12) -> [String] {
        sharedLogLock.lock()
        defer { sharedLogLock.unlock() }
        return Array(sharedLog.suffix(count))
    }

    private func note(_ entry: String) {
        logLock.lock()
        if postLogInternal.count > 200 { postLogInternal.removeFirst(100) }
        postLogInternal.append(entry)
        logLock.unlock()

        Self.sharedLogLock.lock()
        if Self.sharedLog.count > 200 { Self.sharedLog.removeFirst(100) }
        Self.sharedLog.append(entry)
        Self.sharedLogLock.unlock()
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
    }

    private func applyMomentum(_ event: CGEvent, _ momentum: Momentum?) {
        guard let momentum else { return }
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
    }
}
