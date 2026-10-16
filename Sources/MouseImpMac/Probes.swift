// Small probes around the engine: which application sits under the pointer, is
// this app allowed to tap the event stream, and is the pointer on a scroll bar.
//
// Built on AXUIElementCopyElementAtPosition and CGWindowListCopyWindowInfo.

import AppKit
import ApplicationServices
import CoreGraphics

enum Probes {

    // MARK: - Accessibility permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Posting synthetic events needs its own permission on macOS 10.15+.
    static var canPostEvents: Bool {
        if #available(macOS 10.15, *) { return CGPreflightPostEventAccess() }
        return isTrusted
    }

    static func requestPostAccess() {
        if #available(macOS 10.15, *) { _ = CGRequestPostEventAccess() }
    }

    // MARK: - Application under the pointer

    struct Target {
        var pid: pid_t
        var bundleID: String?
        var title: String?
        /// Window level; anything but 0 is system chrome (menu bar, Dock, overlays).
        var layer: Int
    }

    /// Frontmost window containing `point` (CGEvent coordinates, top-left origin).
    /// The window list is ordered front to back, so the first hit is the top one.
    static func windowUnderCursor(_ point: CGPoint) -> Target? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return nil
        }
        for info in infoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: AnyObject],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if !rect.contains(point) { continue }
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            // A window from another space can still be listed; skip those.
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0.01 { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            return Target(pid: pid,
                          bundleID: app?.bundleIdentifier,
                          title: info[kCGWindowName as String] as? String,
                          layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        }
        return nil
    }

    // MARK: - Scroll bars

    /// Rectangles (CGEvent coordinates) of the native scroll bars belonging to the
    /// window under the pointer. Empty when Accessibility access is missing.
    ///
    /// Runs inter process AX calls: never call it from the event tap (see
    /// TargetCache; an active tap stalls input while its callback runs).
    static func scrollbarRects(at point: CGPoint) -> [CGRect] {
        guard isTrusted else { return [] }
        let system = AXUIElementCreateSystemWide()
        // Bound the inter process call: without this a busy application can make
        // this hang for seconds.
        AXUIElementSetMessagingTimeout(system, 0.05)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else { return [] }
        AXUIElementSetMessagingTimeout(element, 0.05)

        // Walk up to the enclosing window, then read its scroll bar children.
        guard let window = windowElement(of: element) else { return [] }

        var rects: [CGRect] = []
        for attribute in [kAXVerticalScrollBarAttribute, kAXHorizontalScrollBarAttribute] {
            guard let bar = copyElement(of: window, attribute as CFString) else { continue }
            AXUIElementSetMessagingTimeout(bar, 0.05)
            if let rect = frame(of: bar) { rects.append(rect) }
        }
        return rects
    }

    // MARK: - AX helpers

    private static func copyElement(of element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let value = valueRef, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        copyElement(of: element, kAXParentAttribute as CFString)
    }

    private static func windowElement(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let element = current, depth < 40 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == (kAXWindowRole as String) {
                return element
            }
            current = parent(of: element)
            depth += 1
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
