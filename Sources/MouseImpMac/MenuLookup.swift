// Looking a menu item up by tag.
//
// `NSMenu.item(withTag:)` only searches the items of that one menu, but the
// diagnostics entries live in a submenu. Looking them up with the plain call
// returned nil, so their checkmark and status line stayed as they were when the
// menu was built.

import AppKit

extension NSMenu {
    /// Depth first search for the first item with `tag`, submenus included.
    func itemRecursively(withTag tag: Int) -> NSMenuItem? {
        for item in items {
            if item.tag == tag { return item }
            if let submenu = item.submenu,
               let found = submenu.itemRecursively(withTag: tag) {
                return found
            }
        }
        return nil
    }
}
