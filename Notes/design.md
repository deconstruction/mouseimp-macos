# MouseImp for macOS — design notes, and why each decision was made

Written for review: every non obvious choice is explained together with the
alternatives that were considered and rejected, and with the reason the event tap is
built the way it is.

---

## 1. What is ported, and from where

The original MouseImp PRO is a Windows program whose core is `DirectScroll`: hold a
mouse button, move the pointer, and the window *under the pointer* scrolls. Its
implementation lives in `MImpPro/MIPro/MIPro.cpp` and `MIPro.h`:

* `CApp::MouseHookFunc()` — a global `WH_MOUSE` hook that decides, per event,
  whether to consume it (`lRes = bNeedEat`) or hand it to the application;
* `CApp::MouseBtnDown/MouseMoveAll/MouseBtnUp` — the gesture state machine
  (`ehmNone → ehmScrollPress → ehmScrollProcess`);
* `CApp::DrillChildUp()` — chooses how to scroll: drag a real scroll bar, or send
  `WM_MOUSEWHEEL` to a known window class;
* `SBScrollCalcShift()` — the movement → scroll conversion with a sub pixel
  remainder, the "slow down" key and the "scrolling speed" setting.

The macOS port keeps that structure one to one:

| MouseImp PRO | here | notes |
| --- | --- | --- |
| `WH_MOUSE` hook, consume/forward per event | `EventTapController` (`CGEventTap`, suppressing) | same consume/forward contract, `nil` = consumed |
| `ehmNone/ehmScrollPress/ehmScrollProcess` | `ScrollEngine.Phase.idle/pressed/grabbing` | drag threshold = "not drag rect" |
| `WM_MOUSEWHEEL` to the window under the pointer | `WheelPoster.postScroll` | pixel precise instead of line based |
| "Control type" (right/middle/left/side buttons) | `triggerButton` | extra buttons 4-7 supported |
| "Activate on" / "Disable on" | `requireModifiers` / `disableModifiers` | |
| "Scrolling speed (%)" | `speed` | |
| "Slow down on" + margin | `slowModifiers` + `slowFactor` | |
| "Inverted" | `invertX` / `invertY` | split per axis |
| (opposite of) "Bidirectional" | `snapToAxis` | |
| "Change cursor" | `CursorTip` overlay | |
| click replay when the press was not a drag | `mouseUp → postClick` | context menu keeps working |
| — | `freezeCursor`, `coast`, per app exclusions, `lineScroll` | extras, see §5 |

Deliberately **not** ported: AutoShrink, the invisible window finder, the
odometer, and the Windows specific "MSIE / Word / Winamp" special cases — on macOS
the synthesised wheel event reaches Qt, Electron, Catalyst and native applications
alike, so the fallback those existed for is unnecessary. The Windows side of the
repository got its own solution for that (see `MImpPro/Notes/universal-wheel.md`).

---

## 2. Why the callback must never block

An active (not listen only) tap at `kCGSessionEventTap` is asked for a decision
*before* the event continues: while the callback does not answer, the session waits.
Pointer motion is not in our mask, which is why a blocked callback shows up as "the
cursor still moves, but clicks and keys do nothing": those are exactly the events
that go through us.

The obvious way to get this wrong is a call that can take an unbounded amount of
time — an Accessibility round trip to a busy or modal application, for instance.
`AXUIElementCopyElementAtPosition` and the attribute walk behind it have a messaging
timeout measured in seconds by default, and a session tap callback that waits that
long stalls input for the whole session while it waits.

### The three rules

1. **The callback does no I/O.** No Accessibility, no `CGWindowListCopyWindowInfo`,
   no `CGEventSource.flagsState()`, no logging, no file access. It reads the event,
   does arithmetic and posts events. Everything else lives behind `TargetCache` (§6)
   or happens at startup.
2. **Every inter process call is bounded and off the tap thread.**
   `AXUIElementSetMessagingTimeout(element, 0.05)` is set on each element before it
   is queried, and the AX work happens on `mouseimp.target` (utility queue).
3. **A watchdog takes the tap down if a callback still manages to block.**
   `EventTapController` records when a callback started; a timer on its own queue
   (0.5 s period) disables the tap from *outside* the blocked thread once a callback
   has been in flight for more than 1 s. Disabling the tap releases the session
   input stream immediately, so the machine stays usable even in the worst case.
   The tap is reinstalled two seconds later, at most twice a minute; after that it
   stays off and the menu/status file say so, so it cannot turn into a loop.

### Alternatives considered

* *Listening to the events without an active tap* (`kCGEventTapOptionListenOnly`
  plus posting a separate event) — cannot suppress the original click, so the
  context menu would open while dragging.
* *`kCGHIDEventTap`* — same blocking hazard, and it needs higher privileges.
* *Resolving the window with a short circuit breaker only* (`if the last lookup was
  slow, skip the next one`) — helps the steady state but not the first slow call,
  which is the one that hurts; a cache with a background refresher removes the class
  of problem.
* *An `IOHIDManager` callback* — event suppression at the HID level needs root, and
  it would not remove the requirement to answer quickly.

Note that the watchdog is a safety net, not a licence to block: rule 1 is what
actually keeps the app fast, and `--selftest` plus the design above are meant to
keep the callback trivial.

---

## 3. The event tap, and why exactly this shape

`EventTap.swift`:

* **Location `kCGSessionEventTap`.** The tap must be able to *suppress* events
  (`kCGEventTapOptionDefault`, i.e. raw value 0), which rules out a listen only tap.
  The session level is enough to see and stop every mouse/key event of the session
  and it does not need root, only the Accessibility permission. The HID level would
  be the same thing one step earlier with root privileges — no benefit here.
* **Placement `.headInsertEventTap`** so our decision is taken before any other tap.
* **Own thread with its own `CFRunLoop`** (`Thread` + `CFMachPortCreateRunLoopSource`
  + `CFRunLoopRun`). Consequences: the tap never depends on the main thread being
  free, and a slow main thread (SwiftUI settings, AX prompts) cannot make the tap
  time out. `start()` waits on a semaphore so the caller can report success or
  failure synchronously.
* **The mask is deliberately narrow** (`EventTapController.eventMask`): left, right
  and other mouse down/up/dragged, key down, scroll wheel.
  * No `mouseMoved`: the engine does not need it and it is the highest frequency
    event of all. Less traffic through our callback means less risk and less
    overhead.
  * Drags are needed because a held button produces `*MouseDragged`, not moves.
  * `scrollWheel` is tapped only so a real wheel interrupts coasting.
  * `keyDown` only so `Escape` can cancel a grab; everything else is passed on.
* **Re-enable on `tapDisabledByTimeout` / `tapDisabledByUserInput`.** macOS disables
  a tap whose callback is too slow or when the user asks it to stop; without this
  the utility would silently die. The status change is reported to the menu.
* **The status returns to `running`** on the next normal event after a timeout, and
  the same counters that feed the menu also feed the status file — one source of
  truth, no duplicated bookkeeping.

### Consume/forward contract

The callback returns `nil` to consume and the untouched `CGEvent` to pass through.
That mirrors `MouseHookFunc()` returning 1/0 in the original: a press that starts a
grab is consumed together with its drags and its release, so the application never
sees a click it did not ask for. If the press turns out not to be a drag, the
application gets a real click back (`WheelPoster.postClick`), which is what keeps
context menus and the middle click working — the counterpart of MouseImp replaying
the click from `cpcStopMouseNCInfo`.

The one exception is an extra button (Button 4 and up): its click is consumed
**without** being replayed. Those buttons normally carry a system action
(back/forward, Mission Control, a shortcut the user bound) which would otherwise
fire on every short press, i.e. on every scroll attempt that did not move far enough
to become a drag. With such a button acting as the trigger, only dragging scrolls;
the press and its release are swallowed and nothing is replayed (`Stats.suppressedClicks`
counts them for the diagnostics).

For an extra button the press is taken **unconditionally**: unlike the standard
buttons, the system chrome / scroll bar exceptions of §6 are skipped there, because
the whole point of the choice is that the button's own action never fires. Only the
per application exclusion list is still honoured.

---

## 4. Scroll wheel synthesis, and why these fields

`WheelPoster.swift`. The combination below is what macOS expects for a precise,
trackpad-like scroll event: each field was confirmed by observing how applications
react when it is set and when it is left out, and every element has a reason.

* **A private `CGEventSource` with `userData = 0x4D49_4D50` ("MIMP").** Our own
  events come back through our tap; `WheelPoster.isOurs()` checks
  `kCGEventSourceUserData` and ignores them, which prevents feedback loops (the
  replayed click would otherwise start a new grab). The tag itself is arbitrary; it
  only has to be recognisable.
* **`CGEventCreateScrollWheelEvent(source, units: .pixel, wheelCount: 2, wheel1:
  dy, wheel2: dx)`.** Pixel units make the receiving application use
  `scrollingDeltaX/Y` (`hasPreciseScrollingDeltas`), which is what makes the scroll
  smooth and proportional instead of jumping a fixed number of lines. Two axes in
  one event, because a diagonal drag must move both.
  *Wheel1 is the vertical axis and wheel2 the horizontal one* — that mapping is
  easy to get wrong, so the code keeps the correspondence explicit at the call site.
* **`kCGScrollWheelEventFixedPtDeltaAxis1/2` are written as `double`.** This is the
  trick that preserves the fractional part: the integer point deltas carry whole
  pixels, the fixed point fields carry the precise value. Both are written — the
  integer into `PointDeltaAxis1/2`, the precise one into the fixed point field.
  Without it a slow drag would post a stream of
  zero delta events and appear not to work — the sub pixel remainder is kept in the
  engine instead, and this field makes sure nothing is lost when a non zero value is
  posted.
* **`kCGScrollWheelEventIsContinuous = 1`** so applications treat the event like one
  from a trackpad or a Magic Mouse, not like a notched wheel. Both directions of the
  default (content follows the pointer) work in AppKit and in custom scrollers, but
  continuous events are what the smooth path of the target expects.
* **No scroll phase, momentum phase only while coasting.** Setting
  `kCGScrollWheelEventScrollPhase` pretends to be a trackpad gesture with
  begun/changed/ended bookkeeping; applications that then wait for a matching `ended`
  can end up in a strange state if one is missed, so the plain path stays phase-less.
  Coasting is different: it *is* momentum, so the events carry
  `kCGScrollWheelEventMomentumPhase` `begin → continue → end` (raw 1/2/3, spelled out
  in `WheelPoster.Momentum` because the imported enum cases are awkward in Swift).
* **`CGEventPost(tap: .cgSessionEventTap)`.** Posting into the session makes the
  event go to the window under the pointer, the same window a real wheel would
  scroll — that is the whole point of DirectScroll. The event keeps the pointer's
  location, which is what the routing uses.
* **Rate limiting.** `|delta| >= 1000` in the engine, and 10 notches in the Windows
  counterpart: a single runaway report (display switch, pointer warp) must not fling
  the content. Halving the accumulators is a cheap way to absorb such a spike.
* **Line mode** (`lineScroll`): `kCGScrollEventUnitLine` with the notch count in
  `kCGScrollWheelEventDeltaAxis1/2`. Only for the rare toolkit that ignores precise
  deltas; pixel units are the default.
* **Click and pointer-move helpers** use the same source and the same tag, so the
  tap recognises them as ours.

---

## 5. The scroll engine, decision by decision

`ScrollEngine.swift` runs on the tap thread only; everything it reads from the rest
of the app is copied under a lock at the start of a gesture
(`snapshot()`), so a setting change cannot alter a gesture half way through.

* **`Phase.pressed` vs `grabbing`.** The press is consumed immediately (the
  application must not see the button down, or a right drag would open a context
  menu before we know whether it is a drag), then the first drag further than
  `dragThreshold` (default 3 px) starts the grab. The threshold is MouseImp's "not
  drag rect", whose size it derived from `SM_CXDRAG/SM_CYDRAG`.
* **Movement is measured from the previous event's location**, not from the anchor,
  so speed changes and direction changes during the gesture behave naturally; the
  per axis accumulators carry the fractional remainder, exactly like
  `SBScrollCalcShift()`'s `MissPnt`.
* **The sign convention** is MouseImp's: content follows the pointer, i.e. dragging
  down shows earlier content, which is a *positive* wheel delta
  (`wheelY = +dyPointer`). Derivation from the original: in `IEScrollMoveInt()` the
  shift is computed as `from - to` (positive when the pointer moved up) and the
  message is sent with `-icActualWheelShift`, so a positive shift (pointer up)
  produces a negative (scroll down) delta — pointer down scrolls up, which is the
  same mapping used here. The horizontal axis is negated relative to the vertical
  one because `kCGScrollWheelEventPointDeltaAxis2` and `WM_MOUSEHWHEEL` use the
  opposite sign convention from their vertical counterparts; "Inverted horizontal"
  flips it if a target disagrees, and it is the one convention that should be
  confirmed on screen (see §8).
* **Speed and the "slow down" key** follow the original's arithmetic:
  `speed` multiplies the movement, `slowModifiers` (default ⌥) scales it by
  `slowFactor` (default 0.25), which corresponds to MouseImp's
  `lScrollReduction = egcDefScrollReduction` (400 %) against
  `dwScrollNormReduction` (100 %): holding the key divides the effective speed by
  four.
* **Axis lock** (`snapToAxis`, the opposite of MouseImp's "Bidirectional") uses a
  simple dominance rule — after 10 px of travel the dominant axis is locked, and it
  can be taken over once the other axis is twice as large. The original used
  `SM_CXDRAG` ranges and switched direction when the movement left that range. A
  variance based decision (comparing the spread of the last samples) was rejected as
  harder to reason about for the same user visible behaviour.
* **Modifiers are read from the event's own `flags`.** The obvious alternative,
  `CGEventSource.flagsState(.combinedSessionState)`, is a call into the window
  server and must not happen per event (rule 1 in §2).
* **Clamping** each axis to ±1000 px per event: see §4.
* **Coasting** keeps the last 24 (dx, dy, time) samples, computes the release
  velocity from the last 120 ms and then posts 60 Hz momentum events with
  `v *= coastFactor^(dt*60)`, stopping below 40 px/s. Chosen because it maps to one
  slider (`coastFactor`, "friction") and because real momentum phases are what
  applications already understand; a spring/drag model would need more parameters
  for no visible gain. `pow(factor, dt*60)` makes the decay independent of the timer
  jitter. Any new press, key or real wheel event stops it.
* **Freeze cursor** (`freezeCursor`) pins the pointer by posting a `mouseMoved` back
  to the anchor and *resetting the reference point to the anchor* as well: the next
  hardware report then arrives relative to the anchor again, so the movement we read
  is the movement that happened. An alternative is to accumulate a correction vector
  and add it back (`sAddedToX/Y`); the simpler variant here is exact as long as
  corrections and reports do not overtake each other, and the rate limit catches the
  rare overshoot. `CGAssociateMouseAndMouseCursorPosition(false)` was rejected: it
  needs careful balancing and affects the whole session.
* **Escape cancels a grab** and is consumed only while a grab is running, so the key
  keeps its meaning everywhere else.
* **Statistics** (`Stats`, `rejects`) are written under their own lock and are only
  read by the diagnostics. The reject reasons exist because they turned an unhelpful
  "does not work" into "the press was a left click, the trigger is the right button".

### Speed modes

`speedMode` decides how the multiplier of a drag step is computed. The base `speed`
is always applied on top, and the slow down key and the inversion stay independent of
the mode.

* **Constant** — multiplier `1`; the behaviour of a plain scrolling tool.
* **Follow the hand** — the pointer speed `v` and its derivative `a`, both EMA
  smoothed (0.3 and 0.2 per step), give
  `1 + k_v·(v/v_ref)^p + k_a·clamp(a/a_ref, 0, 1)`.
  Only *positive* acceleration adds anything: slowing the hand returns to the base
  speed instead of undershooting. `dt` comes from `CGEvent.timestamp` (nanoseconds,
  monotonic) rather than a wall clock, clamped to 1–50 ms so a stalled tap cannot
  produce a giant acceleration. The derivative term is clamped to its share before it
  is scaled by `k_a`, so a single spike cannot dominate.
* **Progressive** — `1 + ramp·min(d/d_ref, 4)^q` with `d` the distance from the point
  where the drag started (the same `travelX/travelY` the axis lock uses). It is a
  *position* based response, so coming back towards the start slows down again by
  design.

The raw multiplier is clamped into `minMultiplier…maxMultiplier` **before** it is
smoothed (`dynamicSmoothing`, EMA per step, 1 = no smoothing): clamping first means
noise cannot leak past the user's limits, and smoothing after means one noisy step
cannot jerk the scroll. Rejected alternatives: an unsmoothed derivative (twitchy,
especially with cheap mice), a jump-based "flick detector" (only two states, and it
reacts to noise), and applying the dynamic factor to the *coast* velocity as well
(see below).

**The settings are snapshotted per gesture** (`gestureSettings`, taken in `beginGrab`)
so a coefficient changed while dragging cannot alter the running gesture halfway
through — the UI says "applies from the next drag" and that is literally true.

**Inertia stays independent.** The coast velocity is measured over
`coastVelocityWindow` from the recorded wheel deltas; when
`coastFollowsSpeedMode` is off, each sample's dynamic factor is divided out again, so
inertia starts from the *base* speed whatever mode is active. With it on, the coast
inherits the boost the user just felt. The start and stop thresholds and the window
are settings as well, so inertia can be tuned without touching the modes.

---

## 6. Window / application / scroll bar knowledge: `TargetCache`

The engine needs to know a few things about the place the pointer is over:

* whether it is system chrome (menu bar, Dock, Control Centre) — those must keep
  their clicks, so the original checks are the same idea as MouseImp's
  `IsWndUserWork()` / window style checks;
* which application owns it — for the per application exclusion list;
* whether it is our own window;
* the rectangles of native scroll bars — "do not start a grab on a scroll bar",
  which in the original is the reason `DrillChildUp()` prefers thumb dragging.

Because of §2 none of that may happen in the callback, so `TargetCache` keeps a
snapshot, refreshed every 0.25 s on `mouseimp.target` (utility QoS), with
`AXUIElementSetMessagingTimeout(..., 0.05)` on every element before it is queried.
The engine accepts the snapshot only when the pointer has not moved more than 3 px
since it was taken and it is younger than 0.5 s. `matches()` returning false means
"unknown", and unknown means **the grab proceeds**: these checks are safety nets,
not gates. That trade off was chosen deliberately — a stale cache must not turn
into "DirectScroll silently does nothing", which is the failure mode users hate
most; the cost is that a right drag started in the same instant as the pointer
arrives over the Dock can start a grab, and the click replay still lets the intended
click through.

---

## 7. Permissions, signing, and the app shell

`AppDelegate.swift`, `Probes.swift`, `Scripts/`.

* **A menu bar app** (`NSApplication` with the `.accessory` activation policy, no
  Dock icon) — the counterpart of the tray icon; the settings window is SwiftUI
  hosted in an `NSHostingView` inside a plain `NSWindow`, which keeps the lifecycle
  explicit (no SwiftUI scene plumbing in a hand assembled bundle). The window is a
  `TabView` with three tabs: **General** (trigger, direction, cursor, excluded
  applications, launch at login), **Advanced settings** (speed mode, all
  coefficients, presets, inertia, live dynamics) and **Diagnostics** (status text and
  the tools). Each tab starts with one sentence of plain language, and every
  coefficient has a short hint under its slider — the tabs exist so the everyday
  options are not buried under the tuning ones.
* **`AXIsProcessTrustedWithOptions` with the prompt** at launch, plus a 2 s timer
  that installs the tap as soon as the permission appears. Reasons: the user may
  grant it while the app runs, and macOS does not notify about it, so polling is the
  simple correct answer: there is no notification for it, so polling is the only
  reliable way to notice.
* **Localisation**: the strings live outside the SwiftPM target, in
  `Resources/<lang>.lproj/Localizable.strings`, and `build-app.sh` copies those
  folders into `Contents/Resources` (with `CFBundleLocalizations` listing them), so
  `Bundle.main` finds them without a resource bundle and macOS picks the language the
  user has. The UI uses localised names (`TriggerButton.localizedTitle`,
  `SpeedMode.title`), while the diagnostics keep the technical ones
  (`TriggerButton.title`, event type names) and the whole status file stays English:
  it exists to be pasted into a bug report.
* **Event posting has its own permission** on 10.15+ (`CGPreflightPostEventAccess` /
  `CGRequestPostEventAccess`). The app checks it and says so in the menu; with the
  Accessibility grant posting works, but a user who only granted the event posting
  permission should still understand what is missing.
* **Ad-hoc signing is not enough for a permission that must survive rebuilds.** A
  TCC (Accessibility) decision is tied to the app's *designated requirement*; for an
  ad-hoc signature that is the code directory hash, so every rebuild is a new
  application and the permission has to be granted again. `Scripts/make-signing-identity.sh`
  creates a self signed
  `MouseImp Dev` certificate in the login keychain (LibreSSL is used for the PKCS#12
  because the keychain tools reject the OpenSSL 3 defaults; the key is imported with
  `-T /usr/bin/codesign` so nothing else can use it, and trust is set only for code
  signing in the *login* keychain, not the system trust store).
  `build-app.sh` picks it up automatically, and then the designated requirement is
  `identifier "ru.deconstruction.mouseimp" and certificate root = H"..."` — stable
  across rebuilds. `./Scripts/make-signing-identity.sh --remove` undoes it.
  `tccutil reset Accessibility ru.deconstruction.mouseimp` clears a stale entry when
  the signature changed anyway.
* **Diagnostics file** `~/Library/Application Support/MouseImp/status.txt`, rewritten
  once a second only when the content changed. It is how the state of a menu bar app
  can be checked from outside (and how the rules in §2 are verified in practice):
  permissions, tap state, watchdog, event counters, engine counters, reject reasons,
  the last posted events, target cache age. `--selftest` is the headless
  counterpart: 28 checks of the state machine, no tap, no permissions needed.

---

## 8. What is verified, and what still needs the screen

Verified without a tap:

* `--selftest`: 42/42 (trigger button variants including the extra buttons, drag
  threshold, speed, inversion, axis lock, required/disabled modifiers, click
  passthrough and the extra button swallow, sub pixel accumulation, Escape, freeze
  cursor, own event filtering, line mode, the three speed modes with their clamps and
  the derivative behaviour, inertia being independent of the mode, and the settings
  format - including a round trip in which every field differs from its default, and
  an upgrade from a blob written by an older build).
* The scroll conversion arithmetic of the Windows counterpart was run through a
  standalone harness (`12 px = 1 notch`, remainder carried, clamp, inversion).
* The tap plumbing was observed live: `tap: running`, the tap listed by the system as
  a session level *filter* with the expected mask, event counters increasing while
  the pointer and keyboard were used, per button press counters showing what arrives
  as a mouse button, and reject counters explaining refused presses.

Needs the machine, with the permission granted:

1. That a right drag actually scrolls a target application (the wheel events are
   posted, which the counters show; delivery is the part that needs eyes).
2. The **horizontal** sign convention (§5). Plan: right drag over the probe page in
   the OpenChamber browser panel, which logs `dx`/`dy` and its own scroll offsets, so
   the correct sign is read off rather than guessed; the same page confirms the
   vertical one.
3. The watchdog never trips in normal use (`watchdog: trips=0`).

---

## 9. Files

```
macos/Sources/MouseImpMac/
├── main.swift          entry point, --selftest branch, accessory app
├── AppDelegate.swift   menu bar item, settings window, login item, status file
├── Settings.swift      settings model (speed modes, coefficients), persistence
├── SettingsView.swift  the three settings tabs
├── AppActions.swift    bridge from the settings window to the app
├── LoginItem.swift     launch at login
├── EventTap.swift      the tap, its thread, its mask, the watchdog
├── ScrollEngine.swift  gesture state machine, speed, axis lock, coast, statistics
├── WheelPoster.swift   wheel event synthesis, click/pointer helpers, post log
├── TargetCache.swift   background window/application/scroll bar snapshot
├── Probes.swift        permissions, window list, AX scroll bars (bounded)
├── CursorTip.swift     "open hand" overlay while grabbing
├── Diagnostics.swift   status file writer
├── EventTrace.swift    short passive trace of every event type
└── SelfTest.swift      headless checks
```
