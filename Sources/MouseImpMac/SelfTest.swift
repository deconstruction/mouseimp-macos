// Headless checks for the DirectScroll state machine, run with
//   MouseImp.app/Contents/MacOS/MouseImp --selftest
//
// Synthetic events are built locally and fed straight into the engine, so this
// needs no Accessibility permission: posting is recorded in WheelPoster's log
// instead of being verified on screen.

import CoreGraphics
import Foundation

enum SelfTest {

    static func run() -> Bool {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                passed += 1
                print("  ok   \(name)")
            } else {
                failed += 1
                print("  FAIL \(name)")
            }
        }

        func makeEngine(_ configure: (inout Settings) -> Void = { _ in }) -> (ScrollEngine, WheelPoster) {
            let engine = ScrollEngine()
            var settings = Settings()
            settings.snapToAxis = false
            settings.skipScrollbars = false
            settings.dragThreshold = 3
            configure(&settings)
            engine.update(settings: settings)
            return (engine, engine.wheelPoster)
        }

        let origin = CGPoint(x: -4000, y: -4000) // far off screen: no window, no AX

        print("MouseImp self test")

        // 1. A plain right click is consumed and re-posted as a real click.
        do {
            let (engine, poster) = makeEngine()
            _ = poster.drainLog()
            let down = mouseEvent(.rightMouseDown, .right, at: origin)
            check("right press consumed", engine.handle(type: .rightMouseDown, event: down) == nil)
            let up = mouseEvent(.rightMouseUp, .right, at: origin)
            check("right release consumed", engine.handle(type: .rightMouseUp, event: up) == nil)
            check("click handed to the application", poster.drainLog().contains { $0.hasPrefix("click") })
        }

        // 2. Movement below the drag threshold does not scroll.
        do {
            let (engine, poster) = makeEngine()
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            _ = engine.handle(type: .rightMouseDragged,
                              event: mouseEvent(.rightMouseDragged, .right, at: origin.applying(.init(translationX: 1, y: 1))))
            check("tiny drag does not scroll", poster.drainLog().isEmpty)
            _ = engine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: origin))
        }

        // 3. Dragging down scrolls up (positive wheel) by the same amount: the
        //    content follows the pointer, like MouseImp's DirectScroll.
        do {
            let (engine, poster) = makeEngine()
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            let moved = origin.applying(.init(translationX: 0, y: 40))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            let log = poster.drainLog()
            check("drag posts one scroll event", log.count == 1)
            if let entry = log.first {
                check("scroll is positive for a downward drag (dy=+40): \(entry)", entry.contains("dy=40.00"))
            }
            _ = engine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: moved))
        }

        // 4. Inverted vertical flips the sign.
        do {
            let (engine, poster) = makeEngine { $0.invertY = true }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            let moved = origin.applying(.init(translationX: 0, y: 40))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            let log = poster.drainLog()
            check("inverted drag scrolls the other way", log.first?.contains("dy=-40.00") == true)
        }

        // 5. Speed multiplier.
        do {
            let (engine, poster) = makeEngine { $0.speed = 2.0 }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            let moved = origin.applying(.init(translationX: 0, y: 30))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            check("speed 2x doubles the distance", poster.drainLog().first?.contains("dy=60.00") == true)
        }

        // 6. Axis lock: a mostly horizontal drag must not scroll vertically.
        do {
            let (engine, poster) = makeEngine { $0.snapToAxis = true }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            let moved = origin.applying(.init(translationX: 80, y: 4))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            let log = poster.drainLog().joined(separator: " | ")
            check("axis lock keeps the vertical axis at zero: \(log)", log.contains("dy=0.00"))
        }

        // 7. Modifier disabled: the press stays with the application.
        do {
            let (engine, poster) = makeEngine { $0.disableModifiers = [.command] }
            _ = poster.drainLog()
            let down = mouseEvent(.rightMouseDown, .right, at: origin)
            down.flags = .maskCommand
            check("press with a disabled modifier is passed on",
                  engine.handle(type: .rightMouseDown, event: down) != nil)
        }

        // 8. Required modifier: grab only with the modifier held.
        do {
            let (engine, _) = makeEngine { $0.requireModifiers = [.option] }
            check("press without the required modifier is passed on",
                  engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin)) != nil)
            let down = mouseEvent(.rightMouseDown, .right, at: origin)
            down.flags = .maskAlternate
            check("press with the required modifier is consumed",
                  engine.handle(type: .rightMouseDown, event: down) == nil)
        }

        // 9. Middle button, left button and an extra (side) button as triggers.
        do {
            let (engineMiddle, _) = makeEngine { $0.triggerButton = .middle }
            let middle = mouseEvent(.otherMouseDown, .center, at: origin)
            middle.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            check("middle button grabs", engineMiddle.handle(type: .otherMouseDown, event: middle) == nil)
            check("right button is ignored when the middle one is chosen",
                  engineMiddle.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin)) != nil)

            let (engineLeft, _) = makeEngine { $0.triggerButton = .left }
            check("left button grabs",
                  engineLeft.handle(type: .leftMouseDown, event: mouseEvent(.leftMouseDown, .left, at: origin)) == nil)

            let (engineSide, _) = makeEngine { $0.triggerButton = .button4 }
            let side = mouseEvent(.otherMouseDown, .center, at: origin)
            side.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            check("side button (Button 4) grabs", engineSide.handle(type: .otherMouseDown, event: side) == nil)
            let middleOnSide = mouseEvent(.otherMouseDown, .center, at: origin)
            middleOnSide.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            check("middle button is ignored when Button 4 is chosen",
                  engineSide.handle(type: .otherMouseDown, event: middleOnSide) != nil)
        }

        // 9b. A click of an extra button is swallowed, a click of a standard one is
        //     handed back to the application.
        do {
            let (engineSide, posterSide) = makeEngine { $0.triggerButton = .button4 }
            _ = posterSide.drainLog()
            let down = mouseEvent(.otherMouseDown, .center, at: origin)
            down.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            let up = mouseEvent(.otherMouseUp, .center, at: origin)
            up.setIntegerValueField(.mouseEventButtonNumber, value: 3)
            _ = engineSide.handle(type: .otherMouseDown, event: down)
            _ = engineSide.handle(type: .otherMouseUp, event: up)
            let log = posterSide.drainLog()
            check("extra button click is not replayed", log.contains { $0.hasPrefix("click") } == false)
            check("extra button click counted as suppressed", engineSide.stats.suppressedClicks == 1)

            let (engineRight, posterRight) = makeEngine()
            _ = posterRight.drainLog()
            _ = engineRight.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = engineRight.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: origin))
            check("standard button click is replayed",
                  posterRight.drainLog().contains { $0.hasPrefix("click") })
        }

        // 10. Our own synthetic events never feed back into the engine.
        do {
            let (engine, _) = makeEngine()
            let down = mouseEvent(.rightMouseDown, .right, at: origin)
            down.setIntegerValueField(.eventSourceUserData, value: WheelPoster.marker)
            check("own events are ignored", engine.handle(type: .rightMouseDown, event: down) != nil)
        }

        // 11. Wheel configuration reaches the poster.
        do {
            let (engine, poster) = makeEngine { $0.lineScroll = true }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            let moved = origin.applying(.init(translationX: 0, y: 40))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            check("line mode is forwarded", poster.drainLog().first?.contains("lines=1") == true)
        }

        // 12. Freeze cursor pins the pointer back to the anchor.
        do {
            let (engine, poster) = makeEngine { $0.freezeCursor = true }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            let moved = origin.applying(.init(translationX: 0, y: 40))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            let log = poster.drainLog()
            check("pointer is pinned while dragging", log.contains { $0.hasPrefix("move") })
            check("pinned drag still scrolls", log.contains { $0.hasPrefix("scroll") })
        }

        // 13. Escape cancels a running grab.
        do {
            let (engine, poster) = makeEngine()
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            let moved = origin.applying(.init(translationX: 0, y: 40))
            _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: moved))
            check("grab is running", engine.isGrabbing)
            let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
            check("escape is consumed", engine.handle(type: .keyDown, event: escape!) == nil)
            check("grab is over", engine.isGrabbing == false)
            _ = poster.drainLog()
        }

        // 14. A sub-pixel drag accumulates instead of being dropped.
        do {
            let (engine, poster) = makeEngine { $0.speed = 0.2 }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            var point = origin
            for _ in 0..<10 {
                point = point.applying(.init(translationX: 0, y: 3)) // 0.6 px per step
                _ = engine.handle(type: .rightMouseDragged, event: mouseEvent(.rightMouseDragged, .right, at: point))
            }
            let log = poster.drainLog()
            let total = log.compactMap { entry -> Double? in
                guard let range = entry.range(of: "dy=") else { return nil }
                return Double(entry[range.upperBound...].prefix { $0 != " " })
            }.reduce(0, +)
            check(String(format: "sub-pixel drags add up to 6 px (got %.2f)", total), abs(total - 6.0) < 0.01)
        }

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0
    }

    // MARK: - Helpers

    private static func mouseEvent(_ type: CGEventType, _ button: CGMouseButton, at point: CGPoint) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        return event
    }
}

extension ScrollEngine {
    var wheelPoster: WheelPoster { poster }
}
