# Mac-sized interface, centred feed and scroll-wheel dials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The dock modules run "Optimized for Mac" (text at real size), the picture is centred below the status row with no dark band above it, and the scroll wheel steps the capture strip's dial settings on hover and in their open popup.

**Architecture:** Each app's Mac build adds device family 6, so `userInterfaceIdiom` becomes `.mac`; every idiom check in shared and app code goes through one helper, `HostDevice.current.isLargeScreen`, so the Mac keeps the iPad path. `FieldMonitorLayout` centres the desktop picture. Three pure types in `MonitorPresentation` (scroll accumulator, write coalescer, wheel dial) carry the wheel's rules with tests; a Mac Catalyst UIKit reader in `MonitorUI` feeds them hover and scroll input, and the shared capture strip (`OpenCineAppKit`) steps and commits through the readout's existing setter.

**Tech Stack:** Swift 6, SwiftUI, UIKit on Mac Catalyst (`UIHoverGestureRecognizer`, `UIPanGestureRecognizer.allowedScrollTypesMask`), Swift Testing, XcodeGen (Pocket, Insta), a hand-kept pbxproj (Z).

**Spec:** `docs/superpowers/specs/2026-11-25-desktop-mac-sized-ui-and-scroll-dials-design.md`

## Global Constraints

- Branches: OpenCine `feat/opencine-desktop` (#403); apps `feat/opencine-desktop-module` (Pocket #701, Insta #175, Z #600), building against the sibling `../OpenCine`. Re-pin all three to the final OpenCine head.
- iPhone, iPad and Android are unchanged. Mac-only code sits behind `#if targetEnvironment(macCatalyst)` or an `[sdk=macosx*]` build setting.
- `.mac` takes the iPad (large-screen) path wherever layout depends on the idiom.
- Wheel: mouse is one detent per step; trackpad deltas add up, one step per fixed distance; down or right is the next value, up or left the previous; it stops at the ends of the list.
- Camera writes are coalesced: a fast spin sends the latest value; the interval is a parameter.
- Shared code names no camera brand, product or app. No em dash. Atlas API snapshots updated. New UI copy is SwiftUI `Text` with literal keys.

## Review Focus

1. A spin faster than the camera answers: every step must start from the last value sent, not the late report, or detents are lost. Test: `aSpinStepsFromItsOwnTarget` (Task 2).
2. The camera never answers a SET (the Luna drops about 2 %): the next spin must start from the reported value again, not a stale target. Test: `theReportTakesOverAfterTheHold` (Task 2).
3. Spinning back to the value already sent within one interval must not send it again. Test: `returningToTheWrittenValueSendsNothing` (Task 2).
4. Overscrolling a trackpad past the last value and then reversing must move at once, not after unwinding the overscroll. Test: `stepsClampAtTheEndsAndDropTheOverscroll` (Task 2).
5. A popup open on one setting while the pointer is over another tile: the other tile must not change. Covered by the wheel target rule in Task 3 (popup open: only its own key takes the wheel), checked on hardware.

---

### Task 0: Commit the spec and this plan

- [ ] `git add` the spec and plan; commit `docs(desktop): Mac-sized interface and scroll-wheel dials spec and plan`.

### Task 1: Centred desktop picture and the title band (MonitorPresentation, OpenCineAppKit)

**Files:**
- Modify: `Sources/MonitorPresentation/FieldMonitorLayout.swift` (`landscapeFrame`, and its two desktop calls)
- Modify: `Sources/OpenCineAppKit/MonitorScreen.swift` (paint the band above the status row)
- Test: `Tests/MonitorPresentationTests/FieldMonitorDesktopChromeTests.swift` (replace `desktopPictureStartsBelowTheStatusRow`)

**Interfaces:**
- Produces: in `.desktop`, `picture` is centred both ways in `[status.maxY, height]`; `landscapeFrame(width:height:cut:aspect:top:)` keeps its signature, `top` now offsets a centred rect instead of resting it.

- [ ] **Step 1: Write the failing test** `desktopPictureIsCentredBelowTheStatusRow`:
  - for every window and title bar in the suite: `picture.y >= status.maxY`; `abs((picture.y - status.maxY) - (height - picture.maxY)) < 1e-9`; `abs(picture.x - (width - picture.maxX)) < 1e-9`; the same for a 3:2 still; record, display, values, assists and stick stay inside `[status.maxY, height]`.
  - tall window `desktop(700, 1000, titleBar: 52)`: `picture == MonitorRect(x: 0, y: 344.125, width: 700, height: 393.75)`.
  - wide window `desktop(1600, 600, titleBar: 0)`: `picture.y == 30`, `picture.height == 570`, `abs(picture.x - 293.333...) < 1e-6`.
- [ ] **Step 2:** `swift test --filter FieldMonitorDesktopChromeTests` fails on the tall window (today `y == 82`).
- [ ] **Step 3:** In `landscapeFrame`, `y: (top ?? 0) + (height - imageH) / 2`. Update the doc comment. In `MonitorScreen`, when `layout.chrome == .desktop`, draw `MonitorTheme.background` over `0..<layout.status.y` across the viewport, behind the chrome, no hit testing.
- [ ] **Step 4:** the suite passes, `deviceLayoutIsUnchanged` included.
- [ ] **Step 5:** Commit `fix(desktop): centre the picture below the status row and give the title band the theme background`.

### Task 2: Wheel rules (MonitorPresentation)

**Files:**
- Create: `Sources/MonitorPresentation/MonitorScrollWheel.swift`
- Test: `Tests/MonitorPresentationTests/MonitorScrollWheelTests.swift`

**Interfaces (all `public`, `Sendable`, Mac only, no Kotlin twin):**
- `struct MonitorScrollAccumulator: Equatable`
  - `enum Device { case mouse, trackpad }`
  - `init(trackpadDistance: Double = 24)`; `var trackpadDistance: Double`
  - `mutating func steps(dx: Double, dy: Double, device: Device) -> Int`. `dx`, `dy` are UIKit scroll translations (content movement): the dominant axis wins and the step sign is the negated delta, so scrolling down (`dy < 0`) or right (`dx < 0`) is `+`. Mouse: `±1` per event with a non-zero delta. Trackpad: adds up; whole multiples of `trackpadDistance` come out; a reversal drops the residue first.
  - `mutating func index(from index: Int, count: Int, dx: Double, dy: Double, device: Device) -> Int?`: the new index clamped to `0..<count`, nil when unchanged; reaching an end drops the residue.
  - `mutating func reset()`
- `struct MonitorWriteCoalescer<Value: Equatable & Sendable>`
  - `init(interval: Double)` (seconds); `let interval: Double`; `private(set) var pending: Value?`
  - `enum Action: Equatable { case write(Value), wait(until: Double) }`
  - `mutating func submit(_ value: Value, at now: Double) -> Action`: writes at once when nothing was written within `interval`, else holds the latest (dropping it when it equals the last value written) and says when it is due.
  - `mutating func due(at now: Double) -> Value?`: the held value once its time has come.
- `struct MonitorWheelDial<Key: Hashable & Sendable>`
  - `init(interval: Double = 0.12, hold: Double = 1.0, trackpadDistance: Double = 24)`
  - `struct Turn: Equatable { let key: Key; let value: String; let write: Bool; let due: Double? }`
  - `mutating func turn(key: Key, options: [String], reported: Int, dx: Double, dy: Double, device: MonitorScrollAccumulator.Device, at now: Double) -> Turn?`: steps from the last value this dial chose for `key` while it is younger than `hold` and still in `options`, else from `reported`; nil when nothing changes. Moving to another key resets the accumulator; each key keeps its own coalescer.
  - `mutating func due(at now: Double) -> [(key: Key, value: String)]`; `var nextDue: Double?`

- [ ] **Step 1: Write the failing tests:**
  - `mouseDetentIsOneStep`: `steps(dx: 0, dy: -3, .mouse) == 1`; `steps(dx: 0, dy: -40, .mouse) == 1`; `steps(dx: 0, dy: 12, .mouse) == -1`; `steps(0, 0, .mouse) == 0`.
  - `trackpadDeltasAddUpToSteps`: distance 24: `-10, -10` give `0, 0`, then `-10` gives `1`; `-50` gives `2`; a reversal `+10` after residue gives `0`, then `+14` gives `-1`.
  - `scrollDownAndRightGoToTheNextValue`: `dy < 0` and `dx < 0` give `+1`; `dy > 0` and `dx > 0` give `-1`; with `dx = -1, dy = 5` the vertical axis wins (`-1`).
  - `stepsClampAtTheEndsAndDropTheOverscroll`: count 5, from 4, scrolling down returns nil; trackpad overscroll of `-100` at index 4 then `+24` returns 3 at once; from 0 scrolling up returns nil.
  - `firstWriteGoesAtOnce`: `submit("200", at: 0) == .write("200")`; again at `0.2` with interval `0.12` is `.write`.
  - `aFastSpinSendsTheLatestValue`: interval 0.12: write "200" at 0; "400" at 0.02 and "800" at 0.05 give `.wait(until: 0.12)`; `due(at: 0.1) == nil`; `due(at: 0.12) == "800"`; `due(at: 0.2) == nil`.
  - `intervalIsAParameter`: interval 0.5: "a" at 0 writes, "b" at 0.3 waits until 0.5.
  - `returningToTheWrittenValueSendsNothing`: write "200" at 0, "400" at 0.02, "200" at 0.04: `due(at: 0.12) == nil`.
  - `aSpinStepsFromItsOwnTarget`: ISO list `["100","200","400","800"]`, reported 0 throughout: mouse down at 0, 0.01, 0.02 gives values "200" (write), "400", "800" (held), and `due(at: 0.12)` gives `[("iso","800")]`.
  - `theReportTakesOverAfterTheHold`: after "200" at 0 with the report still at 0, a turn at 1.5 gives "200" again from the report (and writes it).
- [ ] **Step 2:** `swift test --filter MonitorScrollWheelTests` fails to compile (types missing).
- [ ] **Step 3:** Implement the three types in `MonitorScrollWheel.swift`.
- [ ] **Step 4:** the tests pass; `swift test --filter SharedUIRulesTests` passes.
- [ ] **Step 5:** Commit `feat(desktop): scroll wheel stepping and coalesced writes for dial settings`.

### Task 3: Scroll wheel on the capture strip (MonitorUI, OpenCineAppKit, OpenCineCameraControls)

**Files:**
- Create: `Sources/MonitorUI/MonitorPointerWheel.swift` (Catalyst reader and the `View` modifier; identity elsewhere)
- Create: `Sources/OpenCineAppKit/MonitorOperatorCaptureWheel.swift` (target, step and commit)
- Modify: `Sources/OpenCineAppKit/MonitorOperatorCaptureInputs.swift` (state fields, highlight, popup frame)
- Modify: `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorLiveSurface.swift` (attach the modifier)

**Interfaces:**
- Consumes: `MonitorWheelDial`, `MonitorScrollAccumulator.Device` (Task 2).
- Produces:
  - `public struct MonitorPointerScroll: Equatable, Sendable { dx: Double, dy: Double, device: MonitorScrollAccumulator.Device, location: CGPoint }`
  - `extension View { public func monitorPointerWheel(onHover: @escaping @MainActor (CGPoint?) -> Void, onScroll: @escaping @MainActor (MonitorPointerScroll) -> Void) -> some View }`: Mac Catalyst only (a background `UIViewRepresentable`, not interactive itself, that puts a `UIHoverGestureRecognizer` and two scroll-only `UIPanGestureRecognizer`s, `.discrete` as mouse and `.continuous` as trackpad, `allowedTouchTypes = []`, simultaneous with everything, on its window; locations in the modified view's coordinates). Elsewhere it returns `self` unchanged.
  - `MonitorOperatorCaptureState` gains `public var wheelKey: Key?` (the hovered setting) and `public var panelFrame: CGRect?` (the open popup, in the canvas space).
  - `public struct MonitorOperatorCaptureWheel<Key, Section, NativeIdentity>: ViewModifier` with `init(inputs:control:state:enabled:commandEnabled:currentSource:)`.
- Target rule: no wheel while a drag preview or readout ownership is active. With a popup open, only the popup's own key takes the wheel, over the popup or its tile. Otherwise a strip readout under the pointer whose hold drum would open (an editable field, or an enabled native quick snapshot) takes it, when `commitAdmission()` holds. Status row chips (format, colour, mode) and supplementary readouts never take it.
- Commit: a field through `control.commit(choice, from: control.captureField(key) ?? field)`, a native value through `inputs.nativeCommit(key, inputs.nativeQuick(key).identity, value)`, both read fresh when the write goes out. A held write is flushed by one main-actor task scheduled at `nextDue`.
- Highlight: the hovered readout gets a rounded `Color.white.opacity(0.08)` backing with a hairline accent border.

- [ ] **Step 1:** Implement the reader and modifier; build `MonitorUI` for Mac Catalyst and the iOS Simulator.
- [ ] **Step 2:** Implement the wheel modifier, state fields, highlight and popup frame; attach the modifier in the live surface, inside `#if targetEnvironment(macCatalyst)`.
- [ ] **Step 3:** `swift build --build-tests`, full `swift test`, both xcodebuild builds pass.
- [ ] **Step 4:** Commit `feat(desktop): scroll wheel steps ISO, shutter, WB and the other dial settings`.

### Task 4: One idiom helper and the Mac's large-screen path (shared)

**Files:**
- Modify: `Sources/OpenCineCore/HostDevice.swift` (add `isLargeScreen`)
- Move: `HostDevice.current` from `Sources/OpenCineAppKit/HostDevice.swift` to new `Sources/MonitorUI/HostDevice+Current.swift` (same body; compiles on macOS too so `PairingWizard`'s default argument keeps working)
- Test: `Tests/OpenCineAppKitTests/HostDeviceTests.swift`

**Interfaces:**
- Produces: `public var isLargeScreen: Bool` on `HostDevice` (`iPad` and `mac` true, `iPhone` false); `@MainActor public static var current: HostDevice` now in `MonitorUI`.

**Idiom audit (each `UIDevice.current.userInterfaceIdiom == .pad` becomes `HostDevice.current.isLargeScreen`):**

| Site | Decides |
|---|---|
| `Sources/MonitorUI/MonitorControls.swift:57` | readout value size |
| `Sources/MonitorUI/Media/MonitorPlaybackScreen.swift:195, 352` | playback chrome metrics, panel width |
| `Sources/MonitorUI/Media/MonitorMediaDeliveryPanel.swift:28, 121` | panel width, grid columns |
| `Sources/OpenCineCameraControls/Capture/CaptureControlSheets.swift:1639` | sheet metrics |
| `Sources/OpenCineCameraControls/LiveChrome/LiveStatusChrome.swift:328` | assist palette size |
| `Sources/OpenCineCameraControls/LiveChrome/MonitorOperatorTelemetry.swift:37` | telemetry metrics |
| `Sources/OpenCineCameraControls/Media/MonitorOperatorCatalogScreen.swift:161` | catalog metrics |
| `Sources/OpenCineAppKit/MonitorRotationHold.swift:93` | which orientation key to read |
| `Sources/OpenCineAppKit/MultiviewStageView.swift:835` | gauge size |
| `Sources/OpenCineAppKit/MonitorAssistNativeBindings.swift:33` | scope scale |

Audited and unchanged, with the reason in the commit body: `HostDevice.current` (already `.mac` on Catalyst), `OpenCineApple/UVCVideoSource.swift:73` (Catalyst branch already true), `MonitorUI/MonitorWindowGeometry.swift:185` and OpenZCine `DesignShared.swift:60` (the iPadOS 26 floating window controls, which a Mac window does not have; Z's value is also unread), test-only idiom reads in `OpenCineAppUITesting` and the apps' test targets (iOS only), `UIDevice.current.name`, battery and orientation reads (not idiom). No size-class checks exist.

- [ ] **Step 1: Failing test** `largeScreenIsAnIPadOrAMac`: `HostDevice.iPad.isLargeScreen && HostDevice.mac.isLargeScreen && !HostDevice.iPhone.isLargeScreen`.
- [ ] **Step 2:** It fails to compile. Implement, move `current`, replace the ten sites (add `import OpenCineCore` where missing).
- [ ] **Step 3:** Full `swift test`, both xcodebuild builds, `atlas api --write --build`, `atlas check`.
- [ ] **Step 4:** Commit `refactor(ui): one large-screen check so the Mac keeps the iPad layout`.

### Task 5: Module window at Mac size (OpenCineVirtualCamera)

**Files:** `Sources/OpenCineVirtualCamera/DesktopTabBar.swift`, `Sources/OpenCineVirtualCamera/DesktopModuleHost.swift`

- [ ] `DesktopTabToolbar.barHeight` 44 to 34: the height the items had on screen at the 77 % scale, so the title bar keeps a native unified height now that points are 1:1.
- [ ] Each window scene gets `sizeRestrictions.minimumSize = CGSize(width: 800, height: 600)`, so a module window never falls under the 600 pt large-screen thresholds (`FieldMonitorLayout.tablet`, the pages and Multiview) and is never laid out for a phone.
- [ ] Build for Mac Catalyst; commit `fix(desktop): toolbar and window sizes for a 1:1 Mac window`.

### Task 6: Apps: Optimize for Mac, pins, checks

**Files:** `OpenPocketCine/ios/project.yml`, `OpenInstaCine/ios/project.yml` (then `just ios-generate`), `OpenZCine/ios/Runner.xcodeproj/project.pbxproj` (the Runner target's three configurations), each `opencine-pins.txt`, each `CHANGELOG.md` [Unreleased].

- [ ] Add `"TARGETED_DEVICE_FAMILY[sdk=macosx*]": "2,6"` (Z: `"TARGETED_DEVICE_FAMILY[sdk=macosx*]" = "2,6";`). Device family 6 is "Mac Catalyst using Optimize for Mac"; the iOS value stays `"1,2"`.
- [ ] Build `just macos-build -allowProvisioningUpdates`; confirm the built `Info.plist` `UIDeviceFamily` contains 6 and the iOS Simulator build's does not; `lsregister -u` the built .app.
- [ ] Pin OpenCine to the final head; `just check`; iOS Simulator build and unit tests (CI skip list) on a private simulator.
- [ ] Commit `feat(macos): run the module optimized for Mac`, push, wait for `CI gate` on all four PRs (a Maven Central 429 gets one rerun).
- [ ] One fresh reviewer over the whole diff; fix Important findings.
