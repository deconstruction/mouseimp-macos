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

struct Settings: Codable, Equatable {
    // Master switch.
    var enabled: Bool = true

    // Trigger (MouseImp "Control type:").
    var triggerButton: TriggerButton = .right
    /// Grab only while these modifiers are held (empty = no requirement).
    var requireModifiers: ModifierMask = []
    /// Never grab while any of these modifiers is held (MouseImp "Disable on:").
    var disableModifiers: ModifierMask = [.command]

    // Speed (MouseImp "Scrolling speed (%)").
    var speed: Double = 1.0
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

    // Inertia after release.
    var coastEnabled: Bool = false
    var coastFactor: Double = 0.55

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
