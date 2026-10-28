# MouseImp for macOS — DirectScroll

A native macOS port of the core feature of [MouseImp PRO](https://www.mouseimp.com/)
(**DirectScroll**): hold a mouse button, move the pointer, and the window *under the
pointer* scrolls — no need to focus it, no need to aim at a scroll bar.

The original is a Windows program built on global mouse hooks (`SetWindowsHookEx`)
and `WM_MOUSEWHEEL` forwarding. On macOS the same job is done with a `CGEventTap`
that suppresses the triggering mouse events and a stream of synthesised, pixel
precise scroll wheel events:

```
chosen button down ──► CGEventTap (kCGSessionEventTap, suppressing)
      │                      │ refused? (modifiers, excluded app, scroll bar,
      │                      │          system chrome) → event passes through
      ▼                      ▼
  press swallowed      grab started (anchor, accumulators, axis lock)
      │
      ▼  drags → deltas → speed / slow key / inversion / sub-pixel remainder
   CGEventCreateScrollWheelEvent(units: .pixel, wheel1: dy, wheel2: dx)
      │   (+ fixed point deltas as double, kCGScrollWheelEventIsContinuous)
      ▼
   CGEventPost(kCGSessionEventTap)  →  the window under the pointer scrolls
      │
      ▼  release: swallow, coast (inertia) if enabled
```

Everything the app relies on (tap location and placement, event suppression, the
wheel event fields, tagging the private event source so the tool ignores its own
events) is documented, with the reasoning and the rejected alternatives, in
[Notes/design.md](Notes/design.md).

## Download

Releases are on the [releases page](https://github.com/deconstruction/mouseimp-macos/releases): download `MouseImp-<version>.dmg`,
open it and drag **MouseImp** into *Applications*.

The builds are **ad-hoc signed, not notarised** (there is no Apple Developer
account behind this project), so on the first launch macOS will refuse to open the
app with *"Apple could not verify …"*. To allow it:

* right-click the app → **Open** → **Open** again, or
* System Settings → Privacy & Security → scroll down → **Open Anyway**, or
* clear the quarantine flag once: `xattr -dr com.apple.quarantine /Applications/MouseImp.app`.

Then grant the permissions the app asks for (see below).

## Languages

The interface follows the system language. English, Russian, Spanish, German, French
and Latvian are included; the strings live in `Resources/<language>.lproj/Localizable.strings`
and the build script copies them into the app bundle, so another language is one more
folder. The diagnostics file and the post log stay English on purpose - they are meant
to be pasted into a bug report.

## Requirements

* macOS 13 or newer (Apple silicon or Intel).
* Accessibility permission (and, on 10.15+, the event posting permission).
* For building: Command Line Tools (`xcode-select --install`) — Xcode is **not**
  required.

## Build from source

```sh
./Scripts/build-app.sh                # → dist/MouseImp.app (ad-hoc signed)
./Scripts/build-app.sh --install      # also copy it to /Applications
./Scripts/build-app.sh --sign "Name"  # sign with a certificate you own
./Scripts/make-dmg.sh                 # → dist/MouseImp-<version>.dmg
```

The bundle is assembled by the script (binary + `Info.plist` + signature); no Xcode
project is involved.

An **ad-hoc** signature is a hash of the binary, so every rebuild looks like a new
application to macOS and the Accessibility permission has to be granted again. A
self signed certificate fixes that for local development:

```sh
./Scripts/make-signing-identity.sh            # once: self signed "MouseImp Dev"
./Scripts/build-app.sh                        # picked up automatically
./Scripts/make-signing-identity.sh --remove   # undo
```

If a stale entry is stuck after a signature change,
`tccutil reset Accessibility ru.deconstruction.mouseimp` clears it and the app asks
again on the next launch.

## First run

1. Launch `MouseImp.app`. It is a menu bar app: no Dock icon, no window — look for
   the mouse symbol in the menu bar.
2. System Settings → Privacy & Security → **Accessibility**: enable MouseImp. The
   app polls for the permission and starts the event tap by itself, no restart.
3. Menu bar icon → **Settings…** → *Control type*: pick the button you want to hold
   (left, right, middle, or an extra button such as the thumb "back" button).
4. Drag with that button inside any scrollable window.

The menu also has *DirectScroll enabled*, the tap state, and diagnostics: the number
of events seen, a *Test scroll under pointer* item (posts one scroll after three
seconds, which shows whether event posting is allowed), a *Trace events for 20 s*
item that records every event type the system delivers — including the ones the app
does not handle, which is how you find out what an unusual mouse button actually
sends — and a restart item. The same numbers are written to
`~/Library/Application Support/MouseImp/status.txt` once a second.

## Options

The window has three tabs: **General** (what starts a grab), **Advanced settings**
(how the speed follows your hand, and inertia) and **Diagnostics** (live state and
the tools for awkward mice).

| Setting | MouseImp equivalent | Default |
| --- | --- | --- |
| DirectScroll enabled | Enabled | on |
| Control type (left / right / middle / Button 4-7) | Control type | right button |
| Activate on | Activate on | — |
| Disable on | Disable on | ⌘ |
| Base speed | Scrolling speed (%) | 1.00× (0.2×–10×) |
| Slow down on / factor | Slow down on | ⌥ / 0.25× |
| Inverted horizontal / vertical | Inverted | off |
| Lock to one axis while dragging | (opposite of) Bidirectional | on |
| Change cursor (open hand) | Change cursor | on |
| Do not move the pointer while dragging | — | off |
| Ignore presses on scroll bars | — | on |
| Drag threshold | (MouseImp drag rect) | 3 px |
| Send line based wheel events | (Windows line scrolling) | off |
| Keep scrolling after release (inertia) | — | off |
| Inertia friction / thresholds / window | — | 0.55 / 60 / 40 px/s / 0.12 s |
| Extra buttons swallow their own click | — | on |
| Applications without DirectScroll | — | — |

Direction: the content follows the pointer — drag down to see earlier content, the
same convention as MouseImp's DirectScroll and the hand tool of a PDF reader.
"Inverted …" flips an axis.

A press that never becomes a drag is handed back to the application as a normal
click for the left, right and middle buttons, so context menus, the middle click
and double clicks keep working. For an **extra button** (Button 4 and up) the click
is swallowed instead: those buttons usually carry a system action (back/forward,
Mission Control, a shortcut the user bound), and that action must not fire when the
same button is also the DirectScroll trigger — with an extra button selected, a
short press does nothing and only dragging scrolls.

## Speed modes (Advanced settings)

Scrolling does not have to be a fixed ratio. Three modes, all coefficients adjustable
and visible in the tab:

| Mode | What it does |
| --- | --- |
| **Constant** | One multiplier for the whole drag — the behaviour of a plain scroll tool. |
| **Follow the hand** | Faster movement scrolls further, and while the hand *accelerates* a boost is added (the derivative of the pointer speed). Response, boost, reference speed and acceleration, curve, smoothing and the min/max multiplier are all sliders. |
| **Progressive** | The further you drag from the point where you pressed, the faster it scrolls; coming back slows it down again. |

* Friction-free tuning: `Gentle` / `Balanced` / `Aggressive` presets, a `Defaults`
  button (resets the Advanced tab only) and a live readout of the pointer speed, its
  change and the multiplier that was actually used.
* Coefficients apply from the next gesture, and the multiplier is always clamped into
  the range you set, so a fast flick cannot fly off.
* **Inertia is its own setting**, independent of the mode: friction, the start and
  stop thresholds and the measurement window are all yours, and
  `Coast follows the speed mode` decides whether inertia starts from the speed you
  felt (dynamic) or from the base speed alone (default: base speed).

## Self test

```sh
./.build/debug/MouseImpMac --selftest     # or the binary inside the .app
```

Checks the whole gesture state machine (trigger buttons including the extra ones,
drag threshold, speed, inversion, axis lock, modifier rules, click pass through,
sub-pixel accumulation, Escape, freeze cursor, the three speed modes, the settings
format including upgrades from older versions, and inertia being independent of the
mode) without needing any permission: 42 checks, no tap, no Accessibility.

## Safety: this program sits in the input path of the whole machine

An active event tap at `kCGSessionEventTap` is asked for a decision *before* an
event continues, so clicks and keys wait for our callback. A callback that blocks
freezes input everywhere while the pointer keeps moving (pointer motion is not part
of the tap mask). The rules that keep it from blocking:

* the tap callback does **no I/O**: no Accessibility, no window list, no
  `CGEventSource.flagsState()`, no file or log writes, no AppKit;
* window, application and scroll bar lookups live in `TargetCache`, refreshed on a
  background queue, with `AXUIElementSetMessagingTimeout(0.05)` on everything it
  asks;
* `EventTapController` runs a watchdog: if a callback has not returned after one
  second the tap is disabled from another thread, which releases the input stream,
  and it is reinstalled two seconds later (at most twice a minute, after that it
  stays off and says so in the menu and in the status file);
* `~/Library/Application Support/MouseImp/status.txt` (rewritten once a second)
  reports permissions, tap and watchdog state, event counters, engine counters, the
  reasons a press was refused and the last posted events, so the app can be checked
  from outside without clicking anything.

Every design decision is analysed in
[Notes/design.md](Notes/design.md).

## Not ported (yet)

* AutoShrink (automatic window shrinking) and the invisible window finder: these are
  Windows specific in the original (window class patterns, `WM_SYSCOMMAND`), the
  macOS counterparts would be different features rather than a port.
* The Windows "MSIE / Word / Winamp" special cases: on macOS a synthesised wheel
  event scrolls Qt, Electron, Catalyst and native applications alike, so the
  fallback they existed for is unnecessary.
* Productivity odometer (mouse distance statistics).
* Wheel acceleration for *real* wheel devices — a different feature, not part of
  DirectScroll.

## Layout

```
├── Package.swift                 SwiftPM package (no Xcode project)
├── Notes/design.md               design notes: decisions, alternatives
├── Resources/<lang>.lproj/       Localizable.strings per language
├── Scripts/build-app.sh          builds and signs MouseImp.app
├── Scripts/make-dmg.sh           packs the release disk image
├── Scripts/make-signing-identity.sh   optional stable signing certificate
└── Sources/MouseImpMac/
    ├── main.swift          entry point (and the --selftest branch)
    ├── AppDelegate.swift   menu bar item, settings window, login item, status file
    ├── Settings.swift      settings model (speed modes, coefficients), persistence
    ├── SettingsView.swift  the three settings tabs
    ├── AppActions.swift    bridge from the settings window to the app
    ├── LoginItem.swift     launch at login
    ├── EventTap.swift      the event tap, its thread, its mask, the watchdog
    ├── ScrollEngine.swift  gesture state machine, speed, axis lock, coast
    ├── WheelPoster.swift   scroll wheel synthesis, click and pointer helpers
    ├── TargetCache.swift   background window/application/scroll bar snapshot
    ├── Probes.swift        permissions, window list, scroll bars
    ├── CursorTip.swift     "open hand" overlay while grabbing
    ├── Diagnostics.swift   status file writer
    ├── EventTrace.swift    short passive trace of all event types (diagnostics)
    └── SelfTest.swift      headless checks
```

## Credits and licence

MouseImp PRO — the Windows program this port follows — was written by
Nezhelsky Oskar (idea, code) and Goffmann Svetozar (graphics); its licence allows
free use, modification and redistribution as long as the authors keep their credit,
which is what [NOTICE.md](NOTICE.md) does. Nothing from the original program is
shipped here: this is an independent macOS implementation of the same user visible
feature, using public macOS APIs.

The macOS port itself is released under the MIT licence (see [LICENSE](LICENSE)).
