# Desktop single window with tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the dock's separate strip window. The selected camera module's own window carries the tabs, drags and resizes natively, and tab switches swap windows at the same frame with no gap.

**Architecture:** A pure, tested `DockWindowCoordinator` in `OpenCineDesktopKit` decides every window instruction from events (select, shown, moved, ready, stopped). The dock (now windowless except for a fallback) feeds it module events and sends its commands. `DesktopModuleHost` puts a tab bar in each module window's title bar as a Catalyst toolbar item, reports moves, and obeys show, place and hide.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftUI hosted in UIKit on Mac Catalyst (`NSUIViewToolbarItem`), AppKit for the dock.

**Spec:** `docs/superpowers/specs/2026-11-24-desktop-single-window-tabs-design.md` (builds on `2026-11-05-opencine-desktop-design.md`).

## Global Constraints

- Work in `/Volumes/OCFast/work/desktop/OpenCine` on `feat/opencine-desktop` (draft PR #403). All build output under `/Volumes/OCFast/work/desktop/build/`.
- Shared code and `Desktop/` name no camera brand, product or app (CI rule `sharedUINamesNoBrandProductOrApp`). Tab names come from module manifests.
- No em dash character anywhere (code, comments, docs, commits).
- Module-side code stays inside `#if targetEnvironment(macCatalyst)`; iOS and Android behaviour unchanged.
- The driver is not touched: `Desktop/OpenCineCamera` sources and its `CFBundleVersion` (3) stay as they are, so the installed driver is not replaced.
- Dock `CFBundleShortVersionString` becomes `0.2.0`; modules declare `"minimumDockVersion": "0.2.0"`.
- Public API changes in `OpenCineDesktopKit` and `OpenCineVirtualCamera` are recorded in the atlas API snapshots.
- Tab bar height 44 pt, leading inset clear of the window buttons, status dot colours as `Desktop/OpenCine/TabStrip.swift` today (live green, connecting yellow, failed or stopped red, idle grey).
- Switch timeout 150 ms. Frame reports from a module at most one per 100 ms while moving, plus a final one.

## Review Focus

1. The selected module crashes or is quit: its window vanishes with the tabs on it. Another running module must come forward at the same frame, or the dock's fallback window must appear. Test: `selectedModuleStoppingShowsNextRunning`, `lastModuleStoppingNeedsFallback` (Task 2).
2. The saved frame is on a display that is no longer attached: the window must open on a current screen. Test: `frameOffEveryScreenFallsBackToCentredDefault` (Task 1).
3. Fast repeated tab clicks before the first switch finishes: only the last tab is visible afterwards, no window left behind. Test: `rapidSwitchHidesEveryEarlierWindow` (Task 2).
4. A module that starts or restarts after the window moved: it opens at the current frame, hidden unless selected. Test: `lateReadyModuleUsesCurrentFrame` (Task 2).
5. A module that never confirms `shown` (busy main thread): the old window still goes after the timeout. Test: `switchTimeoutHidesOldWindow` (Task 2).

---

### Task 1: Messages, tabs and frame fitting in OpenCineDesktopKit

**Files:**

- Modify: `Sources/OpenCineDesktopKit/DockMessage.swift`
- Test: `Tests/OpenCineDesktopKitTests/DesktopKitTests.swift` (extend), `Tests/OpenCineDesktopKitTests/WindowFrameTests.swift` (new)

**Interfaces:**

- Produces:
  - `public struct DockTab: Codable, Equatable, Sendable { public var id: String; public var displayName: String; public var state: DockTab.State }` with `public enum State: Codable, Equatable, Sendable { case idle, connecting, live, failed, stopped }`.
  - `public struct DockNotice: Codable, Equatable, Sendable { public var text: String; public var opensDriverSettings: Bool }`.
  - `DockMessage` gains `case tabs([DockTab], selectedID: String?, notice: DockNotice?)` and `case place(frame: WindowFrame)`; keeps `show(frame:)`, `hide`, `quit`.
  - `ModuleMessage` gains `case selectTab(id: String)`, `case windowFrame(WindowFrame, final: Bool)`, `case shown`, `case closeRequested`.
  - `extension WindowFrame { public func fitted(onto screens: [WindowFrame], defaultWidth: Double, defaultHeight: Double) -> WindowFrame }`: keeps `self` when it overlaps some screen by at least 100 x 100; otherwise a frame of the default size (clipped to the screen) centred on `screens.first`; returns `self` when `screens` is empty.

- [ ] **Step 1: Write the failing tests**

```swift
// WindowFrameTests.swift
@Test func frameOnScreenIsKept() {
    let screen = WindowFrame(x: 0, y: 0, width: 1920, height: 1080)
    let frame = WindowFrame(x: 100, y: 100, width: 1280, height: 800)
    #expect(frame.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800) == frame)
}
@Test func frameOffEveryScreenFallsBackToCentredDefault() {
    let screen = WindowFrame(x: 0, y: 0, width: 1920, height: 1080)
    let gone = WindowFrame(x: 3000, y: 0, width: 1280, height: 800)
    #expect(gone.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800)
        == WindowFrame(x: 320, y: 140, width: 1280, height: 800))
}
@Test func barelyVisibleFrameFallsBack() {
    let screen = WindowFrame(x: 0, y: 0, width: 1920, height: 1080)
    let edge = WindowFrame(x: 1880, y: 0, width: 1280, height: 800)  // 40 pt visible
    #expect(edge.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800).x == 320)
}
@Test func defaultIsClippedToASmallScreen() {
    let screen = WindowFrame(x: 0, y: 0, width: 1024, height: 700)
    let gone = WindowFrame(x: 5000, y: 0, width: 1280, height: 800)
    #expect(gone.fitted(onto: [screen], defaultWidth: 1280, defaultHeight: 800)
        == WindowFrame(x: 0, y: 0, width: 1024, height: 700))
}
```

In `DesktopKitTests.swift`, extend `messagesRoundTripAcrossEveryFragment` (or add `newMessagesRoundTrip`) so it round-trips one of each new case, including `.tabs([DockTab(id: "a", displayName: "A", state: .live)], selectedID: "a", notice: DockNotice(text: "Turn on camera driver", opensDriverSettings: true))` and `.windowFrame(frame, final: true)`.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter OpenCineDesktopKitTests`
Expected: compile failure (`DockTab`, `fitted` not defined).

- [ ] **Step 3: Implement the types and cases in `Sources/OpenCineDesktopKit/DockMessage.swift`**

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter OpenCineDesktopKitTests`
Expected: all pass.

- [ ] **Step 5: Commit** `feat(desktop): tab and window-frame messages between the dock and modules`

### Task 2: DockWindowCoordinator

**Files:**

- Create: `Sources/OpenCineDesktopKit/DockWindowCoordinator.swift`
- Test: `Tests/OpenCineDesktopKitTests/DockWindowCoordinatorTests.swift`

**Interfaces:**

- Consumes: `WindowFrame`, `DockMessage` (Task 1).
- Produces:

```swift
public struct DockWindowCoordinator: Sendable {
    public struct Command: Equatable, Sendable { public var moduleID: String; public var message: DockMessage }
    public init(selectedID: String?, frame: WindowFrame)
    public private(set) var selectedID: String?
    public private(set) var frame: WindowFrame
    /// True when no running module can show the tabs, so the dock shows its own window.
    public var needsFallbackWindow: Bool { get }
    public mutating func moduleReady(_ id: String) -> [Command]
    public mutating func moduleStopped(_ id: String) -> [Command]
    public mutating func select(_ id: String) -> [Command]
    public mutating func moduleShown(_ id: String) -> [Command]
    public mutating func switchTimedOut(_ id: String) -> [Command]
    public mutating func windowMoved(by id: String, to frame: WindowFrame) -> [Command]
    public mutating func bringForward() -> [Command]
}
```

Rules: it tracks running modules (in ready order) and the set it believes on screen. `select` of a running module sends only `show(frame)` to it; the others are hidden when the selected module reports `shown` (or on `switchTimedOut` for the selected id); a `shown` or timeout for a module that is no longer selected does nothing. `windowMoved` from the selected module updates `frame` and sends `place(frame)` to every other running module; from any other module it is ignored. `moduleReady` sends `show(frame)` when it is the selected one (or when nothing running is selected, which selects it), else `place(frame)` then `hide`. `moduleStopped` of the selected module selects the next running module in ready order and shows it; with none left, `needsFallbackWindow` becomes true. `bringForward` re-sends `show(frame)` to the selected running module.

- [ ] **Step 1: Write the failing tests**

```swift
let f1 = WindowFrame(x: 0, y: 0, width: 1280, height: 800)
let f2 = WindowFrame(x: 200, y: 100, width: 1280, height: 800)
func running(_ ids: [String], selected: String) -> DockWindowCoordinator {
    var c = DockWindowCoordinator(selectedID: selected, frame: f1)
    for id in ids { _ = c.moduleReady(id) }
    return c
}
@Test func selectingShowsNewBeforeHidingOld() {
    var c = running(["a", "b"], selected: "a")
    #expect(c.select("b") == [.init(moduleID: "b", message: .show(frame: f1))])
    #expect(c.moduleShown("b") == [.init(moduleID: "a", message: .hide)])
}
@Test func selectingTheSelectedTabDoesNothing() {
    var c = running(["a", "b"], selected: "a")
    #expect(c.select("a").isEmpty)
}
@Test func switchTimeoutHidesOldWindow() {
    var c = running(["a", "b"], selected: "a")
    _ = c.select("b")
    #expect(c.switchTimedOut("b") == [.init(moduleID: "a", message: .hide)])
    #expect(c.moduleShown("b").isEmpty)
}
@Test func rapidSwitchHidesEveryEarlierWindow() {
    var c = running(["a", "b", "c"], selected: "a")
    _ = c.select("b")
    _ = c.select("c")
    #expect(c.moduleShown("b").isEmpty)
    #expect(Set(c.moduleShown("c")) == [.init(moduleID: "a", message: .hide), .init(moduleID: "b", message: .hide)])
}
@Test func movesFromTheVisibleModuleReachHiddenOnes() {
    var c = running(["a", "b", "c"], selected: "a")
    #expect(Set(c.windowMoved(by: "a", to: f2)) == [.init(moduleID: "b", message: .place(frame: f2)), .init(moduleID: "c", message: .place(frame: f2))])
    #expect(c.frame == f2)
}
@Test func movesFromAHiddenModuleAreIgnored() {
    var c = running(["a", "b"], selected: "a")
    #expect(c.windowMoved(by: "b", to: f2).isEmpty)
    #expect(c.frame == f1)
}
@Test func lateReadyModuleUsesCurrentFrame() {
    var c = running(["a"], selected: "a")
    _ = c.windowMoved(by: "a", to: f2)
    #expect(c.moduleReady("b") == [.init(moduleID: "b", message: .place(frame: f2)), .init(moduleID: "b", message: .hide)])
}
@Test func selectedModuleStoppingShowsNextRunning() {
    var c = running(["a", "b"], selected: "a")
    #expect(c.moduleStopped("a") == [.init(moduleID: "b", message: .show(frame: f1))])
    #expect(c.selectedID == "b")
    #expect(!c.needsFallbackWindow)
}
@Test func lastModuleStoppingNeedsFallback() {
    var c = running(["a"], selected: "a")
    #expect(c.moduleStopped("a").isEmpty)
    #expect(c.needsFallbackWindow)
    #expect(c.moduleReady("a") == [.init(moduleID: "a", message: .show(frame: f1))])
    #expect(!c.needsFallbackWindow)
}
@Test func bringForwardShowsTheSelectedModule() {
    var c = running(["a", "b"], selected: "b")
    #expect(c.bringForward() == [.init(moduleID: "b", message: .show(frame: f1))])
}
```

(`Command` needs `Hashable` for the `Set` comparisons: make `DockMessage`, `WindowFrame`, `DockTab`, `DockNotice` `Hashable` too.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter DockWindowCoordinatorTests`
Expected: compile failure.

- [ ] **Step 3: Implement `DockWindowCoordinator` per the rules above**

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter OpenCineDesktopKitTests`
Expected: all pass.

- [ ] **Step 5: Commit** `feat(desktop): window coordinator for tabs that live in module windows`

### Task 3: Tab bar and window handling in DesktopModuleHost

**Files:**

- Modify: `Sources/OpenCineVirtualCamera/DesktopModuleHost.swift`
- Create: `Sources/OpenCineVirtualCamera/DesktopTabBar.swift` (SwiftUI view plus its toolbar install, Catalyst only)

**Interfaces:**

- Consumes: Task 1 messages.
- Produces: no new public API beyond what `DesktopModuleHost` already exposes (apps keep calling `DesktopModuleHost.current?.start()`).

Behaviour:

- **Window:** every content window gets `titled | closable | miniaturizable | resizable`, is movable, has its title hidden, and does not enter full screen (collection behaviour `fullScreenNone`). Remove the old `prepare` that made it unmovable and title-bar-less.
- **Tab bar:** each `UIWindowScene` gets `titlebar.titleVisibility = .hidden`, `toolbarStyle = .unified` and an `NSToolbar` whose single leading item is an `NSUIViewToolbarItem` hosting `DesktopTabBar` (a `UIHostingController` view), followed by a flexible space. Install on scene connect and for scenes already connected at `start()`. The bar renders the latest `.tabs` message: tabs with status dot and display name, the selected tab highlighted, "Restart" on a stopped tab, and the notice at the trailing end (a button that opens `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` when `opensDriverSettings`). A tab click sends `selectTab(id:)`. Empty toolbar space drags the window natively.
- **Close button:** retarget the window's close button (`standardWindowButton:` 0) to send `closeRequested`; the module never closes its own window.
- **Frame reports:** observe the window's move and resize notifications; while this module is the shown one, send `windowFrame(frame, final: false)` at most every 100 ms and `windowFrame(frame, final: true)` 150 ms after the last change.
- **Instructions:** `show(frame)`: set the frame if different, deminiaturize if needed, order front, activate, then send `shown` once the window is visible. `place(frame)`: set the frame without ordering in. `hide`: order out. The 0.25 s hold timer now only keeps visibility as instructed (and positions a newly created window at the last instructed frame); it never re-applies a frame to a visible window, so it cannot fight a drag.

- [ ] **Step 1: Implement as above.** No unit test here: it is AppKit bridging by selector. Behaviour is covered by Task 2's tests plus the Task 5 smoke run.
- [ ] **Step 2: Verify Catalyst builds**

Run: `xcodebuild -scheme OpenCineVirtualCamera -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /Volumes/OCFast/work/desktop/build/catalyst-dd build`
Expected: BUILD SUCCEEDED with no new warnings. Also `swift build` (macOS) and an iOS Simulator build of the package still succeed.

- [ ] **Step 3: Commit** `feat(desktop): modules carry the tabs in their own title bar`

### Task 4: Windowless dock driven by the coordinator

**Files:**

- Modify: `Desktop/OpenCine/OpenCineApp.swift`, `Desktop/OpenCine/DockModel.swift`, `Desktop/OpenCine/ModuleProcess.swift`, `Desktop/OpenCine/TabStrip.swift`, `Desktop/OpenCine/Info.plist` (version 0.2.0)

**Interfaces:**

- Consumes: `DockWindowCoordinator`, `DockTab`, `DockNotice`, new messages (Tasks 1 and 2).

Behaviour:

- `ModuleProcess` reports `ready`, `selectTab`, `windowFrame`, `shown`, `closeRequested` and its exit to `DockModel` through one callback `onEvent: (ModuleProcess, ModuleMessage?) -> Void` (nil for exit). It no longer replays a last instruction on ready; the coordinator does.
- `DockModel` owns a `DockWindowCoordinator`, routes every event to it, sends the returned commands, starts a 150 ms `switchTimedOut` timer after each `select`, and logs the switch time (select to `shown`) with `os.Logger` category `tabs`. After any module status, phase, selection or driver state change, it sends `.tabs(...)` to every running module (map `ModuleProcess` phase and status to `DockTab.State`; `notice` from the driver state and `problem`, with `opensDriverSettings` for awaiting approval).
- The window frame persists in `UserDefaults` key `windowFrame` on each `final` report and is restored through `fitted(onto:defaultWidth: 1280, defaultHeight: 800)` against `NSScreen.screens` visible frames.
- `OpenCineApp` has no strip window: delete `installStripDrag`, `followStrip`, `moduleFrame` and the strip. A fallback window hosting `TabStrip` (with a short "No camera is running" line and the Restart buttons) is shown only while `needsFallbackWindow` is true or no modules are installed. Dock icon click (`applicationShouldHandleReopen`) sends `bringForward()` and activates the selected module. `closeRequested` from a module calls `NSApp.activate()` then `NSApp.terminate(nil)`, which keeps the existing live-input confirmation. Remove the hide, minimize and became-active handlers that existed only to move the strip.

- [ ] **Step 1: Implement as above.**
- [ ] **Step 2: Verify the dock builds**

Run: `DESKTOP_DERIVED_DATA_PATH=/Volumes/OCFast/work/desktop/build/desktop-dd Desktop/scripts/build.sh`
Expected: BUILD SUCCEEDED; `codesign --verify --deep --strict` on the built app passes; the embedded driver's `CFBundleVersion` is still `3`. Then unregister the built app from LaunchServices (`lsregister -u <built app>`).

- [ ] **Step 3: Repo checks**

Run: `swift test`, the atlas check and API snapshot update, and the repo's lint and hygiene checks as `AGENTS.md` lists.
Expected: all pass.

- [ ] **Step 4: Commit** `feat(desktop): the dock has no strip window; module windows carry the tabs`, then push to `feat/opencine-desktop` and wait for the PR #403 CI gate.

### Task 5: Modules, install and smoke run

**Files:**

- Modify in each app worktree under `/Volumes/OCFast/work/desktop/` (OpenPocketCine, OpenInstaCine, OpenZCine): `macos/module.json` (`"minimumDockVersion": "0.2.0"`) and `opencine-pins.txt` (new OpenCine head from Task 4).

- [ ] **Step 1: Re-pin, rebuild each module** with `just macos-build`, unregister each built app from LaunchServices, commit `chore(desktop): pin OpenCine with in-window tabs`, push to each draft PR.
- [ ] **Step 2: Install** (owner approved 2026-11-24): quit the dock (only when no input is live), replace `/Applications/OpenCine.app` with the Task 4 build, run `Desktop/scripts/install-local.sh` for each module, register `/Applications/OpenCine.app` with LaunchServices. Do not touch the driver. The 5 Nov backup stays at `/Volumes/OCFast/backup/opencine-desktop-2026-11-05/`.
- [ ] **Step 3: Smoke run.** Launch the dock. Expected:
  - exactly one on-screen OpenCine window (check with `CGWindowListCopyWindowInfo`: one on-screen window from the module processes, none from the dock);
  - the tab bar sits in that window's title bar with all three tabs;
  - `systemextensionsctl list` still shows `com.opencapture.opencine.camera (1.0/3) [activated enabled]`.

  Take a screenshot for the owner.
