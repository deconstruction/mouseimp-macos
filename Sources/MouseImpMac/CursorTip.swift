// Cursor feedback while a grab is active ("Change cursor" in MouseImp).
//
// The system cursor cannot simply be replaced: whatever the application sets on
// mouse-moved wins, and NSCursor would have to fight it. The reference
// implementation therefore draws its own overlay window next to the pointer, and
// so do we.

import AppKit

final class CursorTip {
    private var window: NSWindow?
    private var imageView: NSImageView?
    private let size = CGSize(width: 34, height: 34)

    /// Show the "open hand" badge near `point` (CGEvent screen coordinates).
    func show(at point: CGPoint) {
        let window = ensureWindow()
        let origin = NSPoint(x: point.x - size.width / 2, y: cocoaY(from: point.y) - size.height / 2)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        let image = handImage()
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = imageView

        self.window = window
        self.imageView = imageView
        return window
    }

    private func handImage() -> NSImage? {
        if let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Scrolling") {
            let configured = symbol.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
            let image = configured ?? symbol
            image.isTemplate = true
            return image
        }
        // Fallback: the system's own open hand cursor picture.
        return NSCursor.openHand.image
    }

    /// CGEvent coordinates have their origin at the top left of the main display,
    /// Cocoa windows at the bottom left.
    private func cocoaY(from cgY: CGFloat) -> CGFloat {
        guard let main = NSScreen.screens.first else { return cgY }
        // Window origins are relative to the main screen's coordinate space.
        return main.frame.maxY - cgY
    }
}