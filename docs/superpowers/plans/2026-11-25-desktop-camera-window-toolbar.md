# Camera window toolbar and status row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a dock module on the Mac, the live monitor uses a desktop chrome. The title bar is a toolbar (tabs, take state, Media, Settings), a status row sits under it, the picture starts below that, there is no UI lock, and keyboard shortcuts are added.

**Architecture:** The shared `MonitorUI` gains a desktop chrome mode (an environment value) and a `MonitorDesktopStatusRow` view. `DesktopModuleHost` gains `DesktopCommands`. The monitor registers its actions and take state there, and the host shows them as toolbar items and key commands. Apps only switch the mode on.

**Tech Stack:** Swift 6, SwiftUI, UIKit on Mac Catalyst (`NSToolbar` through `UITitlebar`, `UIKeyCommand`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-desktop-camera-window-toolbar-design.md` (mockup option A).

## Global Constraints

- Branches: OpenCine `feat/opencine-desktop` (#403); apps `feat/opencine-desktop-module` (Pocket #701, Insta #175, ZCine #600). Apps build against the sibling `../OpenCine`. Re-pin all three to the final head.
- Phone, iPad and Android layout and behaviour are unchanged. The desktop mode is on only when `DesktopModuleHost.current != nil` on Mac Catalyst.
- Look: Sora (`MonitorTheme.font`), `MonitorTheme` surface, raised and border tokens, 12 pt radius, the module's accent (`MonitorTheme.accent`), the recording colour for REC.
- Status row height 30 pt. Order: link, battery, card, format, log profile (accent), mode, then the audio meter trailing. A value that is missing is omitted.
- Toolbar order: tabs, flexible space, take state and timecode, separator, Media, Settings, and the driver notice when shown.
- Shortcuts: ⌘R record, ⌘, settings, ⌘⇧M media, ⌘1 to ⌘9 tab, ⌃⇥ and ⌃⇧⇥ next and previous tab, D overlays (only with no text field focused).
- Shared code names no camera brand, product or app. No em dash anywhere. Atlas API snapshots are updated.

## Review Focus

1. A sheet or popup (settings, exposure picker, alert) placed against the old full-height picture lands under the status row or title bar. Test: `desktopPopupsStayInsideThePictureArea` (Task 1).
2. The camera reports no battery or no card (Nikon over HDMI capture). The row must not show empty chips or dashes. Test: `missingValuesAreOmitted` (Task 2).
3. Recording starts from the camera body, not the app. The toolbar must turn to REC and run the timecode. Test: `takeStateFollowsTheMonitor` (Task 3).
4. "D" pressed while typing a network name or password must type the letter, not toggle the overlays. Test: `plainKeysAreIgnoredWhileTextHasFocus` (Task 3).
5. ⌘4 with only three tabs does nothing and does not crash. Test: `tabShortcutBeyondTheTabsDoesNothing` (Task 3).

---

### Task 1: Desktop chrome mode in the live monitor (MonitorUI)

**Files:** `Sources/MonitorUI/LiveMonitorLayout.swift` (and the monitor views that read its `lock`, top strip and gear/media rects), new `Sources/MonitorUI/MonitorDesktopChrome.swift`, plus tests next to the existing `LiveMonitorLayout` tests.

**Interfaces:**
- Produces:
  - `public enum MonitorChromeStyle: Sendable { case device, desktop }` and the environment value `\.monitorChromeStyle` (default `.device`).
  - `LiveMonitorLayout` takes the style. In `.desktop`:
    - The `lock` rect and the top strip and in-picture gear and media rects are empty (`.zero`) and not drawn.
    - `picture.minY == statusRowHeight` (30).
    - The interface lock is always off.

- [ ] **Step 1:** Write failing tests:
  - `desktopHasNoLockOrTopStrip`
  - `desktopPictureStartsBelowTheStatusRow`
  - `desktopPopupsStayInsideThePictureArea`
  - `deviceLayoutIsUnchanged`: compare the `.device` rects to today's values at one iPhone and one iPad landscape size.
- [ ] **Step 2:** Run them and see them fail. Implement. Run the full `MonitorUI` tests and see them pass. Commit `feat(desktop): desktop chrome mode for the live monitor`.

### Task 2: Status row (MonitorUI)

**Files:** new `Sources/MonitorUI/MonitorDesktopStatusRow.swift`, tests.

**Interfaces:**
- Produces:
  - `public struct MonitorDesktopStatus: Equatable, Sendable`, with `link`, `battery`, `card`, `format`, `logProfile`, `mode` (all optional display values), built by `MonitorDesktopStatus.from(...)` from the same presentation data the top strip and side readouts use today.
  - `public struct MonitorDesktopStatusRow: View` renders it with the existing audio meter view trailing.
- [ ] **Step 1:** Write failing tests:
  - `statusMapsFromThePresentation`, with exact strings such as "4K 25p" and "124 GB".
  - `missingValuesAreOmitted`.
  - `logProfileUsesTheAccent`.
- [ ] **Step 2:** Implement. The desktop mode draws the row at the top of the monitor. Run the tests and see them pass. Commit `feat(desktop): status row under the toolbar`.

### Task 3: Toolbar items, commands and shortcuts (OpenCineVirtualCamera)

**Files:** `Sources/OpenCineVirtualCamera/DesktopModuleHost.swift`, `Sources/OpenCineVirtualCamera/DesktopTabBar.swift`, new `Sources/OpenCineVirtualCamera/DesktopCommands.swift`, and a pure `DesktopKeyCommands` in `OpenCineDesktopKit` with tests.

**Interfaces:**
- Produces:
  - `@MainActor public final class DesktopCommands`, on `DesktopModuleHost.current?.commands`, with `openSettings`, `openMedia` and `toggleRecord` (`(() -> Void)?`) and `take: DesktopTake` (`.standby(timecode: String)` or `.recording(timecode: String)`). Setting `take` updates the toolbar.
  - `public enum DesktopShortcut: Equatable, Sendable { case record, settings, media, tab(Int), nextTab, previousTab, overlays }`.
  - `DesktopKeyCommands.action(input: String, modifiers: DesktopModifiers, textHasFocus: Bool, tabCount: Int) -> DesktopShortcut?`
- Toolbar: tabs (flattened style, per the spec), flexible space, take item (STBY in muted or REC in the recording colour, then the timecode), separator, Media, Settings, then the notice. Media and Settings are real toolbar items whose click target is the whole item, with the app's MonitorIcon film and gear glyphs. An item with no registered action is disabled.
- Key commands go on the module window's root. Tab shortcuts send `selectTab` through the existing channel. `overlays` calls a `toggleOverlays` closure on `DesktopCommands`.
- [ ] **Step 1:** Write failing tests:
  - `shortcutTable`: one assertion per row of Global Constraints.
  - `plainKeysAreIgnoredWhileTextHasFocus`.
  - `tabShortcutBeyondTheTabsDoesNothing`.
  - `takeStateFollowsTheMonitor`: a pure formatter from `DesktopTake` to the toolbar title and colour role.
- [ ] **Step 2:** Implement. Build for Mac Catalyst and the iOS Simulator. Commit `feat(desktop): toolbar buttons, take state and shortcuts in the module window`.

### Task 4: Wire the monitor to the commands and switch the apps on

**Files:**
- The shared live monitor root, wherever the gear and media actions and the record action are owned today, so it registers them with `DesktopModuleHost.current?.commands` and publishes the take state.
- Each app sets `.monitorChromeStyle(.desktop)` when `DesktopModuleHost.current != nil` (one line per app, Mac Catalyst only).

- [ ] **Step 1:** Implement the shared registration and the per-app switch. Run `swift test` (full suite) and the atlas checks. In each app run `just check`, an iOS Simulator build and `just macos-build -allowProvisioningUpdates`, then `lsregister -u` on each built app.
- [ ] **Step 2:** Re-pin the apps, push all four, wait for the CI gates (rerun once for a Maven Central 429). Commit `feat(macos): desktop toolbar and status row in the module` in each app.
- [ ] **Step 3:** Dispatch one fresh reviewer over the whole diff. Fix Important findings.
