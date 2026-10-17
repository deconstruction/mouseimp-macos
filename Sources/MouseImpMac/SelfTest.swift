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

        // 15. Every setting survives a round trip through the stored format: a field
        //     forgotten in the custom decoder shows up here as a failed check.
        do {
            var s = Settings()
            s.enabled = false
            s.triggerButton = .button5
            s.requireModifiers = [.control, .shift]
            s.disableModifiers = [.option]
            s.speed = 3.25
            s.speedMode = .distance
            s.velocityResponse = 2.5
            s.accelerationBoost = 1.75
            s.velocityReference = 1234
            s.accelerationReference = 9876
            s.velocityExponent = 1.35
            s.distanceRamp = 4.25
            s.distanceReference = 777
            s.distanceExponent = 1.15
            s.dynamicSmoothing = 0.65
            s.minMultiplier = 0.35
            s.maxMultiplier = 9.5
            s.slowModifiers = [.command]
            s.slowFactor = 0.45
            s.invertX = true
            s.invertY = true
            s.snapToAxis = false
            s.freezeCursor = true
            s.showHandCursor = false
            s.coastEnabled = true
            s.coastFactor = 0.75
            s.coastStartVelocity = 123
            s.coastStopVelocity = 45
            s.coastVelocityWindow = 0.25
            s.coastFollowsSpeedMode = true
            s.dragThreshold = 7
            s.lineScroll = true
            s.disabledBundles = ["com.example.one", "com.example.two"]
            s.skipScrollbars = false
            let data = try? JSONEncoder().encode(s)
            let decoded = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            check("every setting survives encode + decode", decoded == s)
        }

        // 16. A settings blob written by an older build keeps what the user chose,
        //     maps the old trigger index to its button and fills the rest with
        //     defaults.
        do {
            let legacy: [String: Any] = ["enabled": false, "speed": 3.7, "triggerButton": 2,
                                         "invertY": true, "disabledBundles": ["com.example.app"]]
            let data = try? JSONSerialization.data(withJSONObject: legacy)
            let decoded = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            check("old settings keep their values",
                  decoded?.enabled == false && decoded?.speed == 3.7 && decoded?.invertY == true
                  && decoded?.disabledBundles == ["com.example.app"])
            check("old trigger index is mapped (2 = left button)", decoded?.triggerButton == .left)
            check("keys added later fall back to their defaults",
                  decoded?.speedMode == .constant && decoded?.coastStartVelocity == 60
                  && decoded?.maxMultiplier == 6)
        }

        // 17. Constant mode does not care how fast the drag was.
        do {
            let (slowEngine, slowPoster) = makeEngine()
            let slow = dragTotal(engine: slowEngine, poster: slowPoster, stepPixels: 20, intervalMs: 50)
            let (fastEngine, fastPoster) = makeEngine()
            let fast = dragTotal(engine: fastEngine, poster: fastPoster, stepPixels: 20, intervalMs: 4)
            check("constant mode ignores the hand speed", abs(slow - fast) < 0.001)
        }

        // 18. Follow the hand: the same path moved faster scrolls further.
        do {
            let (slowEngine, slowPoster) = makeEngine { $0.speedMode = .velocity }
            let slow = dragTotal(engine: slowEngine, poster: slowPoster, stepPixels: 20, intervalMs: 50)
            let (fastEngine, fastPoster) = makeEngine { $0.speedMode = .velocity }
            let fast = dragTotal(engine: fastEngine, poster: fastPoster, stepPixels: 20, intervalMs: 4)
            check(String(format: "follow the hand: fast drag goes further (%.0f vs %.0f px)", fast, slow),
                  fast > slow * 1.5)
            check("the multiplier respects the ceiling", fastEngine.stats.lastMultiplier <= 6.0001)
        }

        // 19. Zero coefficients make a dynamic mode behave exactly like constant.
        do {
            let (engine, poster) = makeEngine {
                $0.speedMode = .velocity
                $0.velocityResponse = 0
                $0.accelerationBoost = 0
            }
            let total = dragTotal(engine: engine, poster: poster, stepPixels: 20, intervalMs: 4)
            let (constantEngine, constantPoster) = makeEngine()
            let constant = dragTotal(engine: constantEngine, poster: constantPoster, stepPixels: 20, intervalMs: 50)
            check(String(format: "zero coefficients equal constant mode (%.1f vs %.1f px)", total, constant),
                  abs(total - constant) < 0.001)
        }

        // 20. The boost really comes from the derivative: with only the boost active,
        //     a drag that keeps speeding up scrolls further than a steady one over the
        //     same path.
        do {
            let (steadyEngine, steadyPoster) = makeEngine {
                $0.speedMode = .velocity
                $0.velocityResponse = 0
            }
            let steady = dragTotal(engine: steadyEngine, poster: steadyPoster, stepPixels: 20, intervalMs: 20)

            let (accelEngine, accelPoster) = makeEngine {
                $0.speedMode = .velocity
                $0.velocityResponse = 0
            }
            _ = accelEngine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = accelPoster.drainLog()
            var point = origin
            var timestamp: UInt64 = 1_000_000_000
            var interval: UInt64 = 40
            for _ in 0..<8 {
                point = point.applying(.init(translationX: 0, y: 20))
                timestamp += interval * 1_000_000
                if interval > 4 { interval -= 4 }
                let event = mouseEvent(.rightMouseDragged, .right, at: point)
                event.timestamp = timestamp
                _ = accelEngine.handle(type: .rightMouseDragged, event: event)
            }
            let accelerating = totals(accelPoster.drainLog())
            _ = accelEngine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: point))
            check(String(format: "accelerating drag goes further than a steady one (%.0f vs %.0f px)", accelerating, steady),
                  accelerating > steady)
        }

        // 21. Progressive: further from the start scrolls faster, coming back slows
        //     down again.
        do {
            let (engine, poster) = makeEngine { $0.speedMode = .distance }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            var point = origin
            var timestamp: UInt64 = 1_000_000_000
            func step(_ dy: Double) -> Double {
                point = point.applying(.init(translationX: 0, y: dy))
                timestamp += 16_000_000
                let event = mouseEvent(.rightMouseDragged, .right, at: point)
                event.timestamp = timestamp
                _ = engine.handle(type: .rightMouseDragged, event: event)
                return abs(totals(poster.drainLog()))
            }
            let outward = (0..<5).map { _ in step(20) }
            let back = (0..<5).map { _ in step(-20) }
            check(String(format: "progressive: grows with the distance (%.0f -> %.0f px)", outward[0], outward[4]),
                  outward[4] > outward[0])
            check(String(format: "progressive: returns to the base speed on the way back (%.0f -> %.0f px)", back[0], back[4]),
                  back[4] < back[0])
            _ = engine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: point))
        }

        // 22. The speed mode is fixed for the duration of a gesture.
        do {
            let (engine, poster) = makeEngine { $0.speedMode = .velocity }
            _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
            _ = poster.drainLog()
            var point = origin
            var timestamp: UInt64 = 1_000_000_000
            func drag() {
                point = point.applying(.init(translationX: 0, y: 20))
                timestamp += 4_000_000
                let event = mouseEvent(.rightMouseDragged, .right, at: point)
                event.timestamp = timestamp
                _ = engine.handle(type: .rightMouseDragged, event: event)
            }
            for _ in 0..<3 { drag() }

            // Switch to constant in the middle of the gesture.
            var switched = Settings()
            switched.snapToAxis = false
            switched.skipScrollbars = false
            switched.speedMode = .constant
            engine.update(settings: switched)
            for _ in 0..<3 { drag() }
            check("a mode change does not affect the running gesture", engine.stats.lastMultiplier > 1.05)
            _ = engine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: point))
        }

        // 23. Inertia is its own setting: with "coast follows the speed mode" off it
        //     starts from the base speed whatever mode is selected.
        do {
            func coastVelocity(mode: SpeedMode, follows: Bool) -> Double {
                let (engine, poster) = makeEngine {
                    $0.speedMode = mode
                    $0.coastEnabled = true
                    $0.coastFollowsSpeedMode = follows
                }
                _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
                _ = poster.drainLog()
                var point = origin
                var timestamp: UInt64 = 1_000_000_000
                for _ in 0..<6 {
                    point = point.applying(.init(translationX: 0, y: 20))
                    timestamp += 4_000_000
                    let event = mouseEvent(.rightMouseDragged, .right, at: point)
                    event.timestamp = timestamp
                    _ = engine.handle(type: .rightMouseDragged, event: event)
                }
                _ = engine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: point))
                let velocity = engine.stats.lastCoastVelocity
                engine.stopInertia()
                return hypot(velocity.x, velocity.y)
            }

            let constantCoast = coastVelocity(mode: .constant, follows: false)
            let velocityCoast = coastVelocity(mode: .velocity, follows: false)
            let followingCoast = coastVelocity(mode: .velocity, follows: true)
            check(String(format: "inertia ignores the speed mode by default (%.0f vs %.0f px/s)", velocityCoast, constantCoast),
                  velocityCoast > 1 && abs(velocityCoast - constantCoast) < constantCoast * 0.02)
            check(String(format: "inertia follows the mode when asked (%.0f vs %.0f px/s)", followingCoast, velocityCoast),
                  followingCoast > velocityCoast * 1.5)
        }

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0
    }

    // MARK: - Helpers

    /// Total vertical pixels in a poster log.
    private static func totals(_ log: [String]) -> Double {
        log.compactMap { entry -> Double? in
            guard let range = entry.range(of: "dy=") else { return nil }
            return Double(entry[range.upperBound...].prefix { $0 != " " })
        }.reduce(0, +)
    }

    /// Drags `steps` times, `stepPixels` each, one event every `intervalMs`, and
    /// returns the pixels of scroll it produced. The event timestamps are explicit so
    /// the same path can be replayed at a controlled speed.
    private static func dragTotal(engine: ScrollEngine, poster: WheelPoster, steps: Int = 8,
                                  stepPixels: Double, intervalMs: UInt64) -> Double {
        let origin = CGPoint(x: -4000, y: -4000)
        _ = engine.handle(type: .rightMouseDown, event: mouseEvent(.rightMouseDown, .right, at: origin))
        _ = poster.drainLog()
        var point = origin
        var timestamp: UInt64 = 1_000_000_000
        for _ in 0..<steps {
            point = point.applying(.init(translationX: 0, y: stepPixels))
            timestamp += intervalMs * 1_000_000
            let event = mouseEvent(.rightMouseDragged, .right, at: point)
            event.timestamp = timestamp
            _ = engine.handle(type: .rightMouseDragged, event: event)
        }
        let total = totals(poster.drainLog())
        _ = engine.handle(type: .rightMouseUp, event: mouseEvent(.rightMouseUp, .right, at: point))
        return total
    }

    private static func mouseEvent(_ type: CGEventType, _ button: CGMouseButton, at point: CGPoint) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        return event
    }
}

extension ScrollEngine {
    var wheelPoster: WheelPoster { poster }
}
