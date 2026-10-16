# Credits

## MouseImp PRO (the original Windows program)

This project is a macOS implementation of **DirectScroll**, the central feature of
MouseImp PRO — a Windows tool by:

* **Nezhelsky Oskar** — original idea, code
* **Goffmann Svetozar** — original graphics

Home page: <http://www.mouseimp.com>

MouseImp PRO's own licence allows free use, modification and redistribution of its
sources and binaries as long as the authors keep their credit and derivative
programs stay freely redistributable — which is what this notice does. Its naming
and the concept of DirectScroll (hold a mouse button, drag, the window under the
pointer scrolls) come from that project.

Nothing from the original program is included here: this is an independent
implementation of the same user visible feature with public macOS APIs
(`CGEventTap`, `CGEventCreateScrollWheelEvent`), written in Swift.

## This repository

The macOS implementation (everything outside this notice) is licensed under the
MIT licence, see [LICENSE](LICENSE).
