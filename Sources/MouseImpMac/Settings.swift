// Settings model + persistence (UserDefaults, JSON encoded).

import AppKit
import CoreGraphics
import Combine

/// Which mouse button starts DirectScroll. Mirrors MouseImp "Control type:".
///
/// Keyed by `kCGMouseEventButtonNumber`: 0 = left, 1 = right, 2 = middle, 3+ are
/// the extra buttons (a typical thumb "back" button is number 3, shown as
/// "Button 4" to match System Settings and the labels on the hardware).
struct TriggerButton: Codable, Hashable, Identifiable {
    let number: Int64

    var id: Int64 { number }

    init(number: Int64) { self.number = number }

    static let left = TriggerButton(number: 0)
    static let right = TriggerButton(number: 1)
    static let middle = TriggerButton(number: 2)
    static let button4 = TriggerButton(number: 3)
    static let button5 = TriggerButton(number: 4)
    static let button6 = TriggerButton(number: 5)
    static let button7 = TriggerButton(number: 6)

    /// The buttons offered in the settings picker.
    static let all: [TriggerButton] = [.left, .right, .middle, .button4, .button5, .button6, .button7]

    var title: String {
        switch number {
        case 0: return "Left button"
        case 1: return "Right button"
        case 2: return "Middle button"
        default: return "Button \(number + 1)"
        }
    }

    /// Index in NSEvent.buttonNumber / kCGMouseEventButtonNumber.
    var buttonNumber: Int64 { number }

    /// CGMouseButton only distinguishes left/right/center. Extra buttons are still
    /// in the "other" event family, expressed through the button-number field, so
    /// map them onto .center here; WheelPoster writes the exact number into the
    /// event.
    var cgButton: CGMouseButton {
        switch number {
        case 0: return .left
        case 1: return .right
        default: return .center
        }
    }

    var downType: CGEventType {
        switch number {
        case 0: return .leftMouseDown
        case 1: return .rightMouseDown
        default: return .otherMouseDown
        }
    }

    var draggedType: CGEventType {
        switch number {
        case 0: return .leftMouseDragged
        case 1: return .rightMouseDragged
        default: return .otherMouseDragged
        }
    }

    var upType: CGEventType {
        switch number {
        case 0: return .leftMouseUp
        case 1: return .rightMouseUp
        default: return .otherMouseUp
        }
    }
}

/// Modifier key set (the four standard modifiers).
struct ModifierMask: OptionSet, Codable, Hashable {
    let rawValue: UInt

    init(rawValue: UInt) { self.rawValue = rawValue }

    static let shift = ModifierMask(rawValue: UInt(CGEventFlags.maskShift.rawValue))
    static let control = ModifierMask(rawValue: UInt(CGEventFlags.maskControl.rawValue))
    static let option = ModifierMask(rawValue: UInt(CGEventFlags.maskAlternate.rawValue))
    static let command = ModifierMask(rawValue: UInt(CGEventFlags.maskCommand.rawValue))

    static let all: ModifierMask = [.shift, .control, .option, .command]

    var cgFlags: CGEventFlags { CGEventFlags(rawValue: UInt64(rawValue)) }

    static func current(from flags: CGEventFlags) -> ModifierMask {
        ModifierMask(rawValue: UInt(flags.rawValue) & all.rawValue)
    }

    var label: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.isEmpty ? "—" : parts.joined()
    }
}

/// How the scroll speed follows the drag.
///
/// `constant` is the plain multiplier the app always had. The other two make the
/// speed depend on how the pointer moves, which is what the "aggressiveness"
/// coefficients below tune.
enum SpeedMode: String, Codable, CaseIterable, Identifiable {
    /// One fixed multiplier for the whole gesture.
    case constant
    /// Follow the speed of the hand: faster movement scrolls further, and an
    /// accelerating hand adds a boost (the derivative term).
    case velocity
    /// Grow with the distance from the point where the drag started.
    case distance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .constant: return "Constant"
        case .velocity: return "Follow the hand"
        case .distance: return "Progressive"
        }
    }

    var explanation: String {
        switch self {
        case .constant:
            return "One multiplier, as before."
        case .velocity:
            return "Faster hand, further scroll; accelerating adds a boost."
        case .distance:
            return "The further you drag from the start, the faster it scrolls."
        }
    }
}

struct Settings: Codable, Equatable {
    // Master switch.
    var enabled: Bool = true

    // Trigger (MouseImp "Control type:").
    var triggerButton: TriggerButton = .right
    /// Grab only while these modifiers are held (empty = no requirement).
    var requireModifiers: ModifierMask = []
    /// Never grab while any of these modifiers is held (MouseImp "Disable on:").
    var disableModifiers: ModifierMask = [.command]

    // Speed (MouseImp "Scrolling speed (%)") and how it follows the drag.
    var speed: Double = 1.0
    var speedMode: SpeedMode = .constant
    /// `Follow the hand`: how much the speed follows the hand (k_v).
    var velocityResponse: Double = 1.0
    /// `Follow the hand`: extra multiplier while the hand accelerates (k_a).
    var accelerationBoost: Double = 0.5
    /// `Follow the hand`: the pointer speed treated as "normal", px/s.
    var velocityReference: Double = 800
    /// `Follow the hand`: the acceleration that earns the full boost, px/s².
    var accelerationReference: Double = 6000
    /// `Follow the hand`: curvature of the response (1 = linear).
    var velocityExponent: Double = 0.7
    /// `Progressive`: how much faster it gets on a long drag.
    var distanceRamp: Double = 1.5
    /// `Progressive`: the distance where the ramp is at full strength, px.
    var distanceReference: Double = 300
    /// `Progressive`: curvature of the ramp.
    var distanceExponent: Double = 1.0
    /// Smoothing of the dynamic multiplier, per drag step (1 = no smoothing).
    var dynamicSmoothing: Double = 0.25
    /// The dynamic multiplier is always clamped into this range.
    var minMultiplier: Double = 0.25
    var maxMultiplier: Double = 6.0

    /// While held, scroll slower (MouseImp "Slow down on:").
    var slowModifiers: ModifierMask = [.option]
    var slowFactor: Double = 0.25

    // Direction.
    var invertX: Bool = false
    var invertY: Bool = false
    /// Lock to a single axis once the drag direction is clear.
    /// MouseImp calls the opposite of this "Bidirectional".
    var snapToAxis: Bool = true

    // Cursor behaviour.
    var freezeCursor: Bool = false
    var showHandCursor: Bool = true

    // Inertia after release. Independent from `speedMode`: `coastFollowsSpeedMode`
    // decides whether the flick velocity is the one the user felt (dynamic) or the
    // plain one (base speed).
    var coastEnabled: Bool = false
    var coastFactor: Double = 0.55
    /// Pointer velocity at release that starts a coast, px/s.
    var coastStartVelocity: Double = 60
    /// Coast stops once it decays below this, px/s.
    var coastStopVelocity: Double = 40
    /// How far back the release velocity is measured, seconds.
    var coastVelocityWindow: Double = 0.12
    var coastFollowsSpeedMode: Bool = false

    /// Pixels of pointer travel before a press turns into a scroll.
    var dragThreshold: Double = 3.0

    /// Send line based wheel events instead of pixel based ones.
    /// Needed for a few old toolkits that ignore precise deltas.
    var lineScroll: Bool = false

    /// Bundle identifiers where DirectScroll stays off.
    var disabledBundles: [String] = []

    /// Do not start a grab on a native scroll bar.
    var skipScrollbars: Bool = true
}

extension Settings {
    /// Decoded field by field: a settings blob written by an older build (without
    /// the newer keys) keeps what the user had chosen instead of falling back to
    /// every default. `encode(to:)` stays synthesised.
    ///
    /// The `--selftest` round trip test encodes a value in which every field differs
    /// from its default and decodes it again, so a field forgotten here shows up as
    /// a failed check rather than as a silently reset setting.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }

        enabled = get(.enabled, enabled)
        triggerButton = get(.triggerButton, triggerButton)
        // The trigger used to be an enum stored as a bare index (0 = right,
        // 1 = middle, 2 = left). Map that to the button it meant, so upgrading does
        // not silently change which button starts a scroll.
        if let legacy = try? container.decode(Int.self, forKey: .triggerButton) {
            switch legacy {
            case 0: triggerButton = .right
            case 1: triggerButton = .middle
            case 2: triggerButton = .left
            default: break
            }
        }
        requireModifiers = get(.requireModifiers, requireModifiers)
        disableModifiers = get(.disableModifiers, disableModifiers)

        speed = get(.speed, speed)
        speedMode = get(.speedMode, speedMode)
        velocityResponse = get(.velocityResponse, velocityResponse)
        accelerationBoost = get(.accelerationBoost, accelerationBoost)
        velocityReference = get(.velocityReference, velocityReference)
        accelerationReference = get(.accelerationReference, accelerationReference)
        velocityExponent = get(.velocityExponent, velocityExponent)
        distanceRamp = get(.distanceRamp, distanceRamp)
        distanceReference = get(.distanceReference, distanceReference)
        distanceExponent = get(.distanceExponent, distanceExponent)
        dynamicSmoothing = get(.dynamicSmoothing, dynamicSmoothing)
        minMultiplier = get(.minMultiplier, minMultiplier)
        maxMultiplier = get(.maxMultiplier, maxMultiplier)

        slowModifiers = get(.slowModifiers, slowModifiers)
        slowFactor = get(.slowFactor, slowFactor)

        invertX = get(.invertX, invertX)
        invertY = get(.invertY, invertY)
        snapToAxis = get(.snapToAxis, snapToAxis)

        freezeCursor = get(.freezeCursor, freezeCursor)
        showHandCursor = get(.showHandCursor, showHandCursor)

        coastEnabled = get(.coastEnabled, coastEnabled)
        coastFactor = get(.coastFactor, coastFactor)
        coastStartVelocity = get(.coastStartVelocity, coastStartVelocity)
        coastStopVelocity = get(.coastStopVelocity, coastStopVelocity)
        coastVelocityWindow = get(.coastVelocityWindow, coastVelocityWindow)
        coastFollowsSpeedMode = get(.coastFollowsSpeedMode, coastFollowsSpeedMode)

        dragThreshold = get(.dragThreshold, dragThreshold)
        lineScroll = get(.lineScroll, lineScroll)
        disabledBundles = get(.disabledBundles, disabledBundles)
        skipScrollbars = get(.skipScrollbars, skipScrollbars)
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var value: Settings {
        didSet { save() }
    }

    private static let key = "MouseImpMac.settings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            value = decoded
        } else {
            value = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func toggleBundle(_ bundleID: String, disabled: Bool) {
        var v = value
        if disabled {
            if !v.disabledBundles.contains(bundleID) { v.disabledBundles.append(bundleID) }
        } else {
            v.disabledBundles.removeAll { $0 == bundleID }
        }
        value = v
    }
}
